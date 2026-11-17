# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/chat/protocol"

# 对应 troupe-chat/protocol/spec/protocol_spec.cr
module Chat
  module Protocol
    class ProtocolTest < Minitest::Test
      def test_编解码_join
        msg = Protocol.parse_client(JSON.parse(JSON.generate(Protocol.join("lobby", "alice"))))
        assert_equal JoinMsg.new("lobby", "alice"), msg
      end

      def test_编解码_say_含中文与引号转义
        text = %(你好 "world" \n)
        msg = Protocol.parse_client(JSON.parse(JSON.generate(Protocol.say(text, "c-1"))))
        assert_equal SayMsg.new(text, "c-1"), msg
      end

      def test_编解码_leave_ping
        assert_equal :leave, Protocol.parse_client(JSON.parse(JSON.generate(Protocol.leave)))
        assert_equal :ping, Protocol.parse_client(JSON.parse(JSON.generate(Protocol.ping)))
      end

      def test_拒绝非法上行
        assert_raises(ParseError) { Protocol.parse_client(JSON.parse(%({"type":"join","room":"lobby"}))) }
        assert_raises(ParseError) { Protocol.parse_client(JSON.parse(%({"type":"nuke"}))) }
        assert_raises(ParseError) { Protocol.parse_client(JSON.parse(%({"room":"lobby"}))) }
        assert_raises(ParseError) { Protocol.parse_client(JSON.parse(%([1,2]))) }
      end

      def test_say_cid_缺省为空串
        msg = Protocol.parse_client(JSON.parse(%({"type":"say","text":"hi"})))
        assert_equal SayMsg.new("hi", ""), msg
      end

      def test_welcome_往返保留历史与成员
        history = [
          ChatMessage.new(id: 1, from: "bob", text: "hi", ts: 1_700_000_000_000),
          ChatMessage.new(id: 2, from: "alice", text: %(中文"测试"), ts: 1_700_000_001_000),
        ]
        payload = Protocol.welcome("lobby", "alice", %w[alice bob], history, 2)
        assert_equal "welcome", payload["type"]
        assert_equal "alice", payload["you"]
        assert_equal %w[alice bob], payload["members"]
        assert_equal 2, payload["last_id"]
        got = payload["history"]
        assert_equal 2, got.size
        assert_equal "bob", got[0]["from"]
        assert_equal %(中文"测试"), got[1]["text"]
        assert_equal 2, got[1]["id"]
        # JSON 往返不变形（编码边界一致）
        assert_equal payload, JSON.parse(JSON.generate(payload))
      end

      def test_chat_广播与_ack_形状
        chat = Protocol.chat_msg("lobby", 7, "alice", "hello", 42)
        assert_equal "chat", chat["type"]
        assert_equal 7, chat["id"]
        ack = Protocol.ack("c-9", 7)
        assert_equal "c-9", ack["cid"]
        assert_equal 7, ack["id"]
      end

      def test_joined_left_error_pong_形状
        assert_equal "bob", Protocol.joined("lobby", "bob", %w[alice bob])["nick"]
        assert_equal 1, Protocol.left("lobby", "bob", %w[alice])["members"].size
        assert_equal "nick_taken", Protocol.error("nick_taken", "昵称已被占用")["code"]
        assert_equal "pong", Protocol.pong["type"]
        assert_equal "disconnected", Protocol.disconnected("closed")["type"]
      end
    end
  end
end
