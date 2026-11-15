# WebSocket 网关：外部客户端 ⇄ RoomActor 的桥。
#
# 会话模型：
# - 每条连接一个 Session；出站消息经有界 Channel（满则丢弃——在线尽力，与 troupe
#   realtime 语义一致），由独立 writer 纤程串行 send，避免并发写帧交错。
# - 房间事件回放走 troupe Outbox：与 Props 同原子提交，OutboxDispatcher 轮询投递
#   （至少一次），网关按 event_id 去重、按房间转发到各 Session。
#
# 时序要点：先把连接挂进房间集合再调用 join turn，保证 turn 提交后产生的事件
# 不会因注册晚于投递而丢失；客户端按消息 id 对 chat 去重，welcome 历史与之合并。

require "http"
require "json"
require "protocol"
require "./room_actor"

module Chat
  # 非 WebSocket 请求的兜底应答。
  class FallbackHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context) : Nil
      context.response.status = :not_found
      context.response.headers["Content-Type"] = "application/json"
      context.response.print(%({"service":"troupe-chat","ws":"/"}))
    end
  end

  class Session
    getter id : String
    getter mailbox : Channel(String)
    property nick : String = ""
    property room : String = ""

    def initialize(@id : String)
      @mailbox = Channel(String).new(256)
    end

    # 清理只允许执行一次（reader 纤程内 on_close 与 run 返回两个路径）。
    @cleaned : Bool = false

    def cleaned? : Bool
      @cleaned
    end

    def mark_cleaned : Nil
      @cleaned = true
    end
  end

  class Gateway
    DISPATCH_INTERVAL = 50.milliseconds
    MAX_EVENT_CACHE   = 4096
    PUSH_WAIT         = 200.milliseconds

    @sessions = {} of String => Session
    @room_conns = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
    @rooms = {} of String => Troupe::ActorId
    @seen_events = Set(String).new
    @mutex = Mutex.new
    @agent : RoomActor::Agent
    @dispatcher : Troupe::OutboxDispatcher
    @http : HTTP::Server?
    @stopped = false

    def initialize(@stage : Troupe::Stage, @store : Troupe::PropStore)
      @agent = RoomActor::Agent.new(@stage)
      @dispatcher = Troupe::OutboxDispatcher.new(@store, ->(record : Troupe::OutboxRecord) { deliver(record) })
    end

    def room_id(name : String) : Troupe::ActorId
      @mutex.synchronize { @rooms[name] ||= Troupe::ActorId.new("chat", "room", name) }
    end

    # 启动 HTTP/WS 服务与 outbox 投递循环；立即返回实际端口（0 → 系统分配）。
    def listen(host : String, port : Int32) : Int32
      spawn(name: "outbox-dispatch") { dispatch_loop }
      ws_handler = HTTP::WebSocketHandler.new do |ws|
        run_session(ws)
      end
      server = HTTP::Server.new([ws_handler, FallbackHandler.new])
      address = server.bind_tcp(host, port)
      @http = server
      spawn(name: "http-listen") { server.listen }
      address.port
    end

    def stop : Nil
      @stopped = true
      @http.try(&.close)
    end

    # ---- 连接生命周期 ----

    private def run_session(ws : HTTP::WebSocket) : Nil
      conn = Random::Secure.hex(8)
      session = Session.new(conn)
      @mutex.synchronize { @sessions[conn] = session }

      writer = spawn(name: "ws-writer-#{conn}") do
        while raw = session.mailbox.receive?
          STDERR.puts "[dbg] writer send #{raw.size}b" if ENV["CHAT_DEBUG"]?
          ws.send(raw)
          STDERR.puts "[dbg] writer sent" if ENV["CHAT_DEBUG"]?
        end
      rescue
        nil
      end

      ws.on_message { |raw| handle_raw(session, raw) }
      ws.run
      cleanup(session)
      session.mailbox.close
    end

    # ---- 上行处理（会话纤程内串行执行） ----

    private def handle_raw(session : Session, raw : String) : Nil
      parsed = Protocol.parse_client(JSON.parse(raw))
      STDERR.puts "[dbg] handle_raw type=#{parsed.class}" if ENV["CHAT_DEBUG"]?
      case parsed
      when Protocol::JoinMsg
        handle_join(session, parsed)
      when Protocol::SayMsg
        handle_say(session, parsed)
      when :leave
        handle_leave(session)
      when :ping
        push(session, Protocol.pong)
      end
    rescue ex : Protocol::ParseError | JSON::ParseException
      push(session, Protocol.error("bad_request", ex.message || "bad request"))
    rescue ex
      STDERR.puts "[dbg] handle_raw err: #{ex.class}: #{ex.message}" if ENV["CHAT_DEBUG"]?
      push(session, Protocol.error("internal", ex.message || "internal error"))
    end

    private def handle_join(session : Session, join : Protocol::JoinMsg) : Nil
      # 先挂房间集合，再走 turn：事件不会在注册前投递丢失。
      @mutex.synchronize { @room_conns[join.room].add(session.id) }
      id = room_id(join.room)
      begin
        welcome = @agent.join(id, join.nick, session.id)
        STDERR.puts "[dbg] join ok members=#{welcome["members"]?}" if ENV["CHAT_DEBUG"]?
      rescue ex : NickTakenError
        @mutex.synchronize { @room_conns[join.room]?.try(&.delete(session.id)) }
        push(session, Protocol.error("nick_taken", ex.message || "nick taken"))
        return
      rescue ex
        @mutex.synchronize { @room_conns[join.room]?.try(&.delete(session.id)) }
        push(session, Protocol.error("join_failed", ex.message || "join failed"))
        return
      end
      session.nick = join.nick
      session.room = join.room
      push(session, welcome)
    end

    private def handle_say(session : Session, say : Protocol::SayMsg) : Nil
      if session.room.empty?
        push(session, Protocol.error("no_room", "尚未加入房间"))
        return
      end
      id = room_id(session.room)
      begin
        result = @agent.post(id, session.nick, say.text, say.cid)
      rescue ex : Troupe::IdempotencyConflictError
        push(session, Protocol.error("id_conflict", ex.message || "cid 冲突"))
        return
      rescue ex
        push(session, Protocol.error("say_failed", ex.message || "say failed"))
        return
      end
      raw_id = result["id"]?
      msg_id = raw_id ? raw_id.as_i64 : 0_i64
      push(session, Protocol.ack(say.cid, msg_id))
    end

    private def handle_leave(session : Session) : Nil
      room = session.room
      if room.empty?
        push(session, Protocol.left("", session.nick, [] of String))
        return
      end
      begin
        @agent.leave(room_id(room), session.nick, session.id)
      rescue ex
        push(session, Protocol.error("leave_failed", ex.message || "leave failed"))
        return
      end
      @mutex.synchronize { @room_conns[room]?.try(&.delete(session.id)) }
      session.room = ""
    end

    # 断线清理：actor 侧补 leave（空 conn 兜底），房间集合移除。
    private def cleanup(session : Session) : Nil
      return if session.cleaned?
      session.mark_cleaned
      @mutex.synchronize { @sessions.delete(session.id) }
      room = session.room
      nick = session.nick
      return if room.empty? || nick.empty?
      @mutex.synchronize { @room_conns[room]?.try(&.delete(session.id)) }
      begin
        @agent.leave(room_id(room), nick, session.id)
      rescue ex
        STDERR.puts "[gateway] 断线 leave 失败 room=#{room} nick=#{nick}: #{ex.message}"
      end
    end

    # ---- 下行 ----

    # 投递一条消息：有界 mailbox + 限时等待。超时视为慢/死消费者，直接剔除该
    # 会话（背压隔离：不影响其他订阅者）。Crystal 1.22 的 Channel 没有非阻塞
    # try_send，这里用 select + timeout 实现同样的"满则放弃"语义。
    private def push(session : Session, payload : JSON::Any) : Nil
      delivered = false
      select
      when session.mailbox.send(payload.to_json)
        delivered = true
      when timeout PUSH_WAIT
        delivered = false
      end
      drop(session) unless delivered
    rescue Channel::ClosedError
      nil
    end

    private def drop(session : Session) : Nil
      @mutex.synchronize do
        @sessions.delete(session.id)
        @room_conns[session.room]?.try(&.delete(session.id))
      end
      session.mailbox.close
    end

    # ---- Outbox 投递 ----

    private def dispatch_loop : Nil
      until @stopped
        ids = @mutex.synchronize { @rooms.values }
        ids.each { |id| @dispatcher.poll_once(id) }
        sleep DISPATCH_INTERVAL
      end
    end

    private def deliver(record : Troupe::OutboxRecord) : Nil
      return if duplicate?(record.event_id)
      broadcast(record.actor_id.key, record.payload)
    end

    # 至少一次投递的去重缓冲（溢出整表清空，仅防崩溃重放的极端重复）。
    private def duplicate?(event_id : String) : Bool
      @mutex.synchronize do
        return true if @seen_events.includes?(event_id)
        @seen_events.add(event_id)
        @seen_events.clear if @seen_events.size > MAX_EVENT_CACHE
        false
      end
    end

    private def broadcast(room : String, payload : JSON::Any) : Nil
      conns = @mutex.synchronize do
        set = @room_conns[room]?
        set ? set.to_a : ([] of String)
      end
      kind = payload["type"]?.try(&.as_s)
      presence_nick = (kind == "joined" || kind == "left") ? payload["nick"]?.try(&.as_s) : nil
      conns.each do |conn|
        session = @mutex.synchronize { @sessions[conn]? }
        next unless session
        # presence 自回声抑制：自己的 joined/left 不回发（welcome/退出已覆盖）。
        next if presence_nick && session.nick == presence_nick
        push(session, payload)
      end
    end
  end
end
