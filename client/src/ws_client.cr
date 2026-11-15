# WebSocket 客户端封装。
#
# 线程模型（Crystal 纤程）：
# - connect 在独立纤程完成握手（阻塞 DNS/TCP 不冻结 UI）；
# - 读纤程：ws.run → on_message → JSON 解析后进 inbox Channel（UI 每帧泵取）；
# - 写纤程：sendq Channel 串行 send —— stdlib HTTP::WebSocket#send 没有锁，
#   跨纤程并发写会交错帧，必须自行串行化；
# - 断线/失败以 disconnected / connect_failed 消息进 inbox（UI 状态机据此回退）。

require "http"
require "json"
require "protocol"

class WsClient
  getter inbox = Channel(JSON::Any).new(512)

  @sendq = Channel(String).new(64)
  @ws : HTTP::WebSocket?
  @closed = false

  def connected? : Bool
    !@ws.nil? && !@closed
  end

  # 异步连接并发送 join；结果一律经 inbox 通知。
  def connect(url : String, room : String, nick : String) : Nil
    raise "已有连接" if @ws
    spawn(name: "ws-connect") do
      begin
        ws = HTTP::WebSocket.new(URI.parse(url))
      rescue ex
        notify(Chat::Protocol.error("connect_failed", ex.message || "连接失败"))
        @closed = true
        next
      end
      @ws = ws
      ws.on_message do |raw|
        begin
          @inbox.send(JSON.parse(raw))
        rescue Channel::ClosedError
          nil
        end
      end
      spawn(name: "ws-writer") do
        while raw = @sendq.receive?
          ws.send(raw)
        end
      rescue
        nil
      end
      send_raw(Chat::Protocol.join(room, nick))
      begin
        ws.run
      rescue ex
        STDERR.puts "[ws] run 异常：#{ex.message}"
      end
      @closed = true
      try_notify(Chat::Protocol.disconnected("closed"))
    end
  end

  # 发送上行消息（Chat::Protocol.join/say/leave/ping 已是 JSON 文本）。
  # 返回 false 表示队列满（连接异常时的软信号）。
  def send(raw : String) : Bool
    send_raw(raw)
  end

  def close : Nil
    return if @closed
    @closed = true
    @ws.try(&.close)
    @sendq.close
  end

  private def send_raw(raw : String) : Bool
    sent = false
    select
    when @sendq.send(raw)
      sent = true
    when timeout 500.milliseconds
      sent = false
    end
    sent
  rescue Channel::ClosedError
    false
  end

  private def notify(payload : JSON::Any) : Nil
    @inbox.send(payload)
  rescue Channel::ClosedError
    nil
  end

  private def try_notify(payload : JSON::Any) : Nil
    sent = false
    select
    when @inbox.send(payload)
      sent = true
    when timeout 250.milliseconds
      sent = false
    end
    nil
  rescue Channel::ClosedError
    nil
  end
end
