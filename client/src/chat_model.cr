# 聊天客户端状态模型：纯逻辑，无 UI/网络依赖（可独立 spec）。
#
# 服务端消息经 ingest 统一进入；UI 每帧从 WsClient 的 inbox 泵入 ingest。
# 服务端投递按房间有序（troupe Outbox 顺序），客户端按消息 id 对 chat 去重
# ——welcome 历史与在线广播合并时不会出现重复行。

require "protocol"

class ChatModel
  getter messages = [] of Chat::Protocol::ChatMessage
  getter members = [] of String
  property state : Symbol = :idle # :idle :connecting :joined
  property you : String = ""
  property room : String = ""
  property status : String = "未连接"
  property login_error : String = ""

  # 供 UI 订阅的新事件计数（UI 拉取后清零）。
  getter dirty : Int32 = 0

  @seen_ids = Set(Int64).new

  def consume_dirty : Int32
    d = @dirty
    @dirty = 0
    d
  end

  def reset_login_error : Nil
    @login_error = ""
  end

  # 处理一条服务端消息；返回是否改变了状态。
  def ingest(msg : JSON::Any) : Bool
    before = snapshot_digest
    case msg["type"]?.try(&.as_s)
    when "welcome"
      @room = msg["room"]?.try(&.as_s) || ""
      @you = msg["you"]?.try(&.as_s) || ""
      @members = read_strings(msg["members"])
      msg["history"]?.try(&.as_a).try do |items|
        items.each do |item|
          m = Chat::Protocol::ChatMessage.from_json(item.to_json)
          add_message(m)
        end
      end
      @state = :joined
      @status = "已连接 #{@room}"
      @login_error = ""
    when "chat"
      m = Chat::Protocol::ChatMessage.from_json(msg.to_json)
      add_message(m)
    when "joined"
      nick = msg["nick"]?.try(&.as_s) || "?"
      @members = read_strings(msg["members"])
      add_message(Chat::Protocol::ChatMessage.new(0_i64, "", "#{nick} 加入了房间", now_ms))
    when "left"
      nick = msg["nick"]?.try(&.as_s) || "?"
      @members = read_strings(msg["members"])
      add_message(Chat::Protocol::ChatMessage.new(0_i64, "", "#{nick} 离开了房间", now_ms))
    when "ack"
      id = msg["id"]?.try(&.as_i64) || 0
      @status = "消息 ##{id} 已送达"
    when "error"
      code = msg["code"]?.try(&.as_s) || "error"
      text = msg["message"]?.try(&.as_s) || "未知错误"
      if @state != :joined
        @login_error = text
        @state = :idle
      end
      @status = "错误（#{code}）：#{text}"
    when "pong"
      @status = "心跳正常"
    when "disconnected"
      @state = :idle
      @members = [] of String
      @status = "连接断开"
      @login_error = "连接断开，请重试"
    when "connect_failed"
      @state = :idle
      @status = "未连接"
      @login_error = "无法连接：#{msg["reason"]?.try(&.as_s) || "未知原因"}"
    end
    changed = snapshot_digest != before
    @dirty += 1 if changed
    changed
  end

  # 本地预测：发起连接（欢迎到达前显示状态）。
  def mark_connecting : Nil
    @state = :connecting
    @status = "连接中…"
    @login_error = ""
    @dirty += 1
  end

  private def add_message(m : Chat::Protocol::ChatMessage) : Nil
    return if m.id > 0 && @seen_ids.includes?(m.id)
    @seen_ids.add(m.id) if m.id > 0
    @messages << m
    @dirty += 1
  end

  private def read_strings(node : JSON::Any?) : Array(String)
    return [] of String unless node
    node.as_a.map(&.as_s)
  rescue
    [] of String
  end

  private def now_ms : Int64
    Time.utc.to_unix_ms
  end

  private def snapshot_digest : String
    "#{@state}|#{@you}|#{@room}|#{@members.size}|#{@messages.size}|#{@status}|#{@login_error}"
  end
end
