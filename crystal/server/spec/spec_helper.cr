require "spec"
require "http"
require "../src/chat/gateway"

# Crystal 1.22 的 Channel 没有非阻塞 try_send：用 select + timeout 实现等价语义。
def try_send_nb(channel : Channel(T), value : T, wait = 250.milliseconds) forall T
  sent = false
  select
  when channel.send(value)
    sent = true
  when timeout wait
    sent = false
  end
  sent
rescue Channel::ClosedError
  false
end

# 起一个内存 Stage + 网关，返回 {gateway, stage, port}。
def new_gateway
  stage = Troupe::Stage.new
  stage.register(Chat::RoomActor.troupe_manifest)
  gateway = Chat::Gateway.new(stage, stage.store)
  port = gateway.listen("127.0.0.1", 0)
  {gateway, stage, port}
end

# 测试用 WebSocket 客户端：入站消息进 Channel，支持带超时的类型断言。
class TestClient
  getter inbox = Channel(JSON::Any).new(128)
  @ws : HTTP::WebSocket
  @sendq = Channel(String).new(64)

  def initialize(url : String)
    @ws = HTTP::WebSocket.new(URI.parse(url))
    @ws.on_message do |raw|
      STDERR.puts "[dbg] client got: #{raw[0, 60]}" if ENV["CHAT_DEBUG"]?
      @inbox.send(JSON.parse(raw))
    rescue
      nil
    end
    spawn(name: "test-writer") do
      while raw = @sendq.receive?
        @ws.send(raw)
      end
    rescue
      nil
    end
    spawn(name: "test-reader") do
      @ws.run
      try_send_nb(@inbox, JSON.parse(%({"type":"disconnected"})))
    rescue
      nil
    end
  end

  def send(raw : String) : Bool
    try_send_nb(@sendq, raw)
  end

  def join(room : String, nick : String) : Bool
    send(Chat::Protocol.join(room, nick))
  end

  def say(text : String, cid : String) : Bool
    send(Chat::Protocol.say(text, cid))
  end

  def close : Nil
    @ws.close rescue nil
    @sendq.close
  end

  def next_message(timeout = 3.seconds) : JSON::Any?
    msg = nil
    select
    when m = @inbox.receive
      msg = m
    when timeout timeout
      return nil
    end
    msg
  end

  # 等待第一条 type == kind 的消息（跳过其它消息），超时抛错。
  def expect(kind : String, timeout = 3.seconds) : JSON::Any
    deadline = Time.instant + timeout
    loop do
      remaining = deadline - Time.instant
      raise "等待 #{kind} 超时" if remaining <= 0.seconds
      msg = next_message(remaining)
      next unless msg
      return msg if msg["type"]?.try(&.as_s?) == kind
    end
  end
end
