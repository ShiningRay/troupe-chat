# 房间 Virtual Actor：每个房间一个 RoomActor（role=room, key=房间名）。
#
# 职责与边界：
# - 房间成员与最近消息是 Actor 的 Props，随 `save`/幂等提交原子落盘（SQLite WAL）；
# - 广播事件不直发 WebSocket，而是 `emit_event` 进 troupe Outbox（与 Props 同原子提交），
#   由 OutboxDispatcher 轮询投递给网关 —— 每房间广播顺序与 Turn 提交顺序严格一致；
# - 发言以客户端 cid 作幂等键：网络重发不会产生重复消息/重复广播；
# - 网关断线兜底补发 leave（actor 内 conn 为空时按昵称剔除）。

require "troupe"
require "protocol"

module Chat
  MAX_HISTORY = 200

  # 昵称被占用：业务异常，Turn 内抛出后原样送达调用方（troupe 错误分类）。
  class NickTakenError < ::Exception; end

  record Member, nick : String, conn : String do
    include JSON::Serializable

    def initialize(@nick : String, @conn : String)
    end
  end

  class RoomProps
    include JSON::Serializable
    property role : String = "room"
    property next_id : Int64 = 1
    property members : Array(Member) = [] of Member
    property messages : Array(Chat::Protocol::ChatMessage) = [] of Chat::Protocol::ChatMessage

    def initialize
    end
  end

  class RoomActor < Troupe::Actor(RoomProps)
    troupe_manifest "room", schema_version: 1 do
      turn join, {nick: String, conn: String}, returns: JSON::Any
      turn post, {from: String, text: String, cid: String}, returns: JSON::Any
      turn leave, {nick: String, conn: String}, returns: JSON::Any
      turn snapshot, {} of String => String, returns: JSON::Any
    end

    # 加入房间：重名拒绝；成功后经 Outbox 广播 joined，返回 welcome 快照。
    def join(nick : String, conn : String) : JSON::Any
      raise NickTakenError.new("昵称已被占用：#{nick}") if member?(nick)
      props.members << Member.new(nick, conn)
      emit_event("joined", Protocol.joined(room, nick, nick_list))
      save
      Protocol.welcome(room, nick, nick_list, props.messages, last_id)
    end

    # 发言：cid 作幂等键。首次执行：分配消息 id → 追加（截断到 MAX_HISTORY）→
    # emit_event(chat) → 幂等 helper 与 Props 一次原子提交；重放：直接返回首次结果，
    # 不重复落库也不重复广播。
    def post(from : String, text : String, cid : String) : JSON::Any
      idempotent(cid, "post|#{from}|#{text}") do
        msg = append_message(from, text)
        Protocol.chat_msg(room, msg.id, msg.from, msg.text, msg.ts)
      end
    end

    # 离开：conn 空串时按昵称剔除（网关断线兜底路径）。
    # 重复 leave（本就不是成员）幂等：无变化则不广播不落盘。
    def leave(nick : String, conn : String) : JSON::Any
      removed = false
      props.members.reject! do |m|
        hit = m.nick == nick && (conn.empty? || m.conn == conn)
        removed = true if hit
        hit
      end
      if removed
        emit_event("left", Protocol.left(room, nick, nick_list))
        save
      end
      Protocol.left(room, nick, nick_list)
    end

    def snapshot : JSON::Any
      Protocol.welcome(room, "", nick_list, props.messages, last_id)
    end

    private def room : String
      actor_id.key
    end

    private def member?(nick : String) : Bool
      props.members.any? { |m| m.nick == nick }
    end

    private def nick_list : Array(String)
      props.members.map(&.nick)
    end

    private def last_id : Int64
      props.messages.last?.try(&.id) || (props.next_id - 1)
    end

    private def append_message(from : String, text : String) : Protocol::ChatMessage
      msg = Protocol::ChatMessage.new(props.next_id, from, text, Time.utc.to_unix_ms)
      props.next_id += 1
      props.messages << msg
      props.messages = props.messages.last(MAX_HISTORY) if props.messages.size > MAX_HISTORY
      emit_event("chat", Protocol.chat_msg(room, msg.id, msg.from, msg.text, msg.ts))
      msg
    end
  end
end
