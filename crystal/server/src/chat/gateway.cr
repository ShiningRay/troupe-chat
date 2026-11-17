# Chat 网关：troupe-gateway（ADR-0007 L3 传输桥）之上的**应用协议路由**。
#
# 传输管理（会话生命周期、有界 mailbox、溢出策略、Outbox 派发循环、事件去重）
# 全部由 troupe-gateway 承担；本层只剩 chat 业务语义：
# - 上行路由：join/say/leave/ping → RoomActor typed Agent 调用；
# - 房间成员表（conn 集合）与 presence 自回声抑制；
# - 断线兜底补 leave；慢消费者惰性清理（deliver 失败即移出房间集合）。
#
# 时序要点：先把连接挂进房间集合再调用 join turn，保证 turn 提交后产生的
# 事件不会因注册晚于投递而丢失；客户端按消息 id 对 chat 去重，welcome 历史与之合并。

require "http"
require "json"
require "protocol"
require "troupe-gateway"
require "./room_actor"

module Chat
  class Gateway
    @room_conns = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
    @rooms = {} of String => Troupe::ActorId
    @mutex = Mutex.new
    @agent : RoomActor::Agent
    @gw : Troupe::Gateway::WebSocket
    @stopped = false

    def initialize(@stage : Troupe::Stage, @store : Troupe::PropStore)
      @agent = RoomActor::Agent.new(@stage)
      @gw = Troupe::Gateway::WebSocket.new(@store)
      @gw.on_message = ->(session : Troupe::Gateway::Session, raw : String) { handle_raw(session, raw) }
      @gw.on_disconnect = ->(session : Troupe::Gateway::Session) { cleanup(session) }
      @gw.on_outbox = ->(record : Troupe::OutboxRecord) { deliver_event(record) }
    end

    def room_id(name : String) : Troupe::ActorId
      id = @mutex.synchronize { @rooms[name] ||= Troupe::ActorId.new("chat", "room", name) }
      @gw.track(id) # 重复 track 幂等；保证新房间进入派发轮询
      id
    end

    def listen(host : String, port : Int32) : Int32
      @gw.listen(host, port)
    end

    def stop : Nil
      @stopped = true
      @gw.stop
    end

    # ---- 上行路由（chat 业务语义） ----

    private def handle_raw(session : Troupe::Gateway::Session, raw : String) : Nil
      parsed = Protocol.parse_client(JSON.parse(raw))
      case parsed
      when Protocol::JoinMsg
        handle_join(session, parsed)
      when Protocol::SayMsg
        handle_say(session, parsed)
      when :leave
        handle_leave(session)
      when :ping
        @gw.deliver(session, Protocol.pong)
      end
    rescue ex : Protocol::ParseError | JSON::ParseException
      @gw.deliver(session, Protocol.error("bad_request", ex.message || "bad request"))
    rescue ex
      @gw.deliver(session, Protocol.error("internal", ex.message || "internal error"))
    end

    private def handle_join(session : Troupe::Gateway::Session, join : Protocol::JoinMsg) : Nil
      # 先挂房间集合，再走 turn：事件不会在注册前投递丢失。
      @mutex.synchronize { @room_conns[join.room].add(session.id) }
      id = room_id(join.room)
      begin
        welcome = @agent.join(id, join.nick, session.id)
      rescue ex : NickTakenError
        @mutex.synchronize { @room_conns[join.room]?.try(&.delete(session.id)) }
        @gw.deliver(session, Protocol.error("nick_taken", ex.message || "nick taken"))
        return
      rescue ex
        @mutex.synchronize { @room_conns[join.room]?.try(&.delete(session.id)) }
        @gw.deliver(session, Protocol.error("join_failed", ex.message || "join failed"))
        return
      end
      session.meta["nick"] = join.nick
      session.meta["room"] = join.room
      @gw.deliver(session, welcome)
    end

    private def handle_say(session : Troupe::Gateway::Session, say : Protocol::SayMsg) : Nil
      room = session.meta["room"]?
      if room.nil? || room.empty?
        @gw.deliver(session, Protocol.error("no_room", "尚未加入房间"))
        return
      end
      begin
        result = @agent.post(room_id(room), session.meta["nick"], say.text, say.cid)
      rescue ex : Troupe::IdempotencyConflictError
        @gw.deliver(session, Protocol.error("id_conflict", ex.message || "cid 冲突"))
        return
      rescue ex
        @gw.deliver(session, Protocol.error("say_failed", ex.message || "say failed"))
        return
      end
      raw_id = result["id"]?
      @gw.deliver(session, Protocol.ack(say.cid, raw_id ? raw_id.as_i64 : 0_i64))
    end

    private def handle_leave(session : Troupe::Gateway::Session) : Nil
      room = session.meta["room"]?
      if room.nil? || room.empty?
        @gw.deliver(session, Protocol.left("", session.meta["nick"], [] of String))
        return
      end
      begin
        @agent.leave(room_id(room), session.meta["nick"], session.id)
      rescue ex
        @gw.deliver(session, Protocol.error("leave_failed", ex.message || "leave failed"))
        return
      end
      @mutex.synchronize { @room_conns[room]?.try(&.delete(session.id)) }
      session.meta["room"] = ""
    end

    # 断线清理：actor 侧补 leave（空 conn 兜底），房间集合移除。
    private def cleanup(session : Troupe::Gateway::Session) : Nil
      room = session.meta["room"]?
      nick = session.meta["nick"]?
      return if room.nil? || room.empty? || nick.nil? || nick.empty?
      @mutex.synchronize { @room_conns[room]?.try(&.delete(session.id)) }
      begin
        @agent.leave(room_id(room), nick, session.id)
      rescue ex
        STDERR.puts "[gateway] 断线 leave 失败 room=#{room} nick=#{nick}: #{ex.message}"
      end
    end

    # ---- Outbox 事件路由（chat 业务语义） ----

    private def deliver_event(record : Troupe::OutboxRecord) : Nil
      room = record.actor_id.key
      payload = record.payload
      kind = payload["type"]?.try(&.as_s)
      presence_nick = (kind == "joined" || kind == "left") ? payload["nick"]?.try(&.as_s) : nil
      conns = @mutex.synchronize do
        set = @room_conns[room]?
        set ? set.to_a : ([] of String)
      end
      conns.each do |conn|
        # presence 自回声抑制：自己的 joined/left 不回发（welcome/退出已覆盖）。
        nick = @gw.session(conn).try(&.meta["nick"]?)
        next if presence_nick && nick == presence_nick
        # 慢消费者/死会话惰性清理：deliver 失败即移出房间集合。
        @mutex.synchronize { @room_conns[room]?.try(&.delete(conn)) } unless @gw.deliver_id(conn, payload)
      end
    end
  end
end
