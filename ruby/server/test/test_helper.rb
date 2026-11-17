# frozen_string_literal: true

# 测试公用设施：Troupe Rehearsal 式内存 Troupe + 网关起服 + 极简 WS 测试客户端。

require "minitest/autorun"
require "json"
require "socket"
require "digest/sha1"
require "securerandom"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../../protocol/lib", __dir__))

require "troupe"
require "chat/room_actor"
require "chat/sqlite_outbox_store"
require "chat/gateway"

# 起一个内存存储、无传输的 Troupe + Gateway，返回 [gateway, troupe, port]
def new_gateway(store: nil, troupe: nil)
  troupe ||= Troupe.form(actors: [Chat::RoomActor], prop_store: store || :memory,
                         transport: false, cue_store: false)
  gateway = Chat::Gateway.new(troupe)
  port = gateway.listen("127.0.0.1", 0)
  [gateway, troupe, port]
end

# 极简 RFC 6455 测试客户端：握手、掩码发送文本帧、后台线程收帧入队。
class TestClient
  attr_reader :messages

  def initialize(port)
    @socket = TCPSocket.new("127.0.0.1", port)
    key = [SecureRandom.random_bytes(16)].pack("m0")
    @socket.write(
      "GET / HTTP/1.1\r\n" \
      "Host: 127.0.0.1:#{port}\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\n" \
      "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    status = @socket.gets.to_s
    raise "握手失败：#{status}" unless status.include?("101")

    loop do
      line = @socket.gets
      break if line.nil? || line == "\r\n"
    end

    @messages = Queue.new
    @closed = false
    @reader = Thread.new { read_loop }
  end

  def send_text(text)
    write_frame(0x1, text)
  end

  def send_raw(text)
    send_text(text)
  end

  def join(room, nick)
    send_text(JSON.generate({ "type" => "join", "room" => room, "nick" => nick }))
  end

  def say(text, cid)
    send_text(JSON.generate({ "type" => "say", "text" => text, "cid" => cid }))
  end

  # 等待第一条 type 匹配的消息（跳过其它消息，与 Crystal 版 spec_helper 同语义），超时抛错。
  def expect(type, timeout: 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "等待 #{type} 超时" if remaining <= 0

      msg = next_message(timeout: remaining)
      next unless msg
      return msg if msg["type"] == type
    end
  end

  def next_message(timeout: 0.3)
    @messages.pop(timeout: timeout)
  rescue ThreadError
    nil
  end

  def drain(seconds = 0.3)
    msgs = []
    while (m = next_message(timeout: seconds))
      msgs << m
      seconds = 0.05
    end
    msgs
  end

  def close
    write_frame(0x8, [1000].pack("n")) rescue nil
    @socket.close rescue nil
    @reader&.join(1)
    @closed = true
  end

  def closed?
    @closed
  end

  private

  def read_loop
    loop do
      opcode, payload = read_frame
      if opcode.nil?
        @messages.push({ "type" => "__closed__" })
        return
      end
      case opcode
      when 0x1
        @messages.push(JSON.parse(payload.force_encoding(Encoding::UTF_8)))
      when 0x8
        @messages.push({ "type" => "__closed__" })
        return
      when 0x9
        write_frame(0xA, payload) # 回 pong
      end
    end
  rescue IOError, Errno::ECONNRESET, Errno::EPIPE, EOFError
    @messages.push({ "type" => "__closed__" })
  end

  def read_frame
    head = @socket.read(2)
    return [nil, nil] unless head && head.bytesize == 2

    b0, b1 = head.unpack("C2")
    opcode = b0 & 0x0F
    len = b1 & 0x7F
    len = @socket.read(2)&.unpack1("n") if len == 126
    len = @socket.read(8)&.unpack1("Q>") if len == 127
    return [nil, nil] if len.nil?

    payload = len.positive? ? @socket.read(len) : "".b
    return [nil, nil] unless payload && payload.bytesize == len

    [opcode, payload] # 服务端帧不掩码
  rescue IOError, EOFError, Errno::ECONNRESET, Errno::EPIPE
    [nil, nil]
  end

  def write_frame(opcode, payload)
    payload = payload.to_s.b
    len = payload.bytesize
    head = [0x80 | opcode].pack("C")
    head += if len < 126
              [0x80 | len].pack("C")
            elsif len < 65_536
              [0x80 | 126, len].pack("Cn")
            else
              [0x80 | 127].pack("C") + [len].pack("Q>")
            end
    mask = SecureRandom.random_bytes(4)
    bytes = payload.unpack("C*")
    key = mask.unpack("C*")
    bytes.each_index { |i| bytes[i] ^= key[i % 4] }
    @socket.write(head + mask + bytes.pack("C*"))
  end
end
