# frozen_string_literal: true

# 网关端到端：真实 TCP/WebSocket 连接，覆盖 join/say/ack/广播/断线补 leave。
# 对应 troupe-chat/server/spec/gateway_spec.cr 的全部用例。

require_relative "test_helper"

module Chat
  class GatewayTest < Minitest::Test
    def setup
      @gateway, @troupe, @port = new_gateway
    end

    def teardown
      @gateway.stop
      @troupe.shutdown!
    rescue StandardError
      nil
    end

    def test_join_welcome_say_ack_双方都收到广播
      a = TestClient.new(@port)
      b = TestClient.new(@port)

      a.join("lobby", "alice")
      welcome = a.expect("welcome")
      assert_equal "alice", welcome["you"]

      b.join("lobby", "bob")
      b.expect("welcome")
      joined = a.expect("joined")
      assert_equal "bob", joined["nick"]
      assert_equal %w[alice bob], joined["members"]

      a.say("大家好", "c-1")
      ack = a.expect("ack")
      assert_equal "c-1", ack["cid"]
      id = ack["id"]

      chat_a = a.expect("chat")
      assert_equal id, chat_a["id"]
      assert_equal "alice", chat_a["from"]
      assert_equal "大家好", chat_a["text"]

      chat_b = b.expect("chat")
      assert_equal id, chat_b["id"]

      a.close
      b.close
    end

    def test_后加入者的_welcome_携带已有历史
      a = TestClient.new(@port)
      a.join("lobby", "alice")
      a.expect("welcome")
      a.say("第一条历史", "h1")
      a.expect("ack")
      a.expect("chat")

      b = TestClient.new(@port)
      b.join("lobby", "bob")
      welcome = b.expect("welcome")
      history = welcome["history"]
      assert_equal 1, history.size
      assert_equal "第一条历史", history[0]["text"]
      assert_equal "alice", history[0]["from"]
      assert_equal 1, welcome["last_id"]

      a.close
      b.close
    end

    def test_重名_join_得到_nick_taken_错误
      a = TestClient.new(@port)
      b = TestClient.new(@port)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "alice")
      err = b.expect("error")
      assert_equal "nick_taken", err["code"]

      a.close
      b.close
    end

    def test_未加入房间就_say_得到_no_room_非法_JSON_得到_bad_request
      c = TestClient.new(@port)

      c.say("hello", "c-0")
      err = c.expect("error")
      assert_equal "no_room", err["code"]

      c.send_raw(%({"type":"broken"))
      err2 = c.expect("error")
      assert_equal "bad_request", err2["code"]

      c.close
    end

    def test_断线后其他成员收到_left
      a = TestClient.new(@port)
      b = TestClient.new(@port)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "bob")
      a.expect("joined")

      b.close
      left = a.expect("left", timeout: 5.0)
      assert_equal "bob", left["nick"]
      assert_equal %w[alice], left["members"]

      a.close
    end

    def test_say_幂等_同_cid_重发只产生一条广播
      a = TestClient.new(@port)
      b = TestClient.new(@port)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "bob")
      a.expect("joined")

      a.say("只算一次", "same-cid")
      a.expect("ack")
      a.expect("chat")
      b_chat = b.expect("chat")
      assert_equal 1, b_chat["id"]

      a.say("只算一次", "same-cid")
      ack2 = a.expect("ack")
      assert_equal "same-cid", ack2["cid"]
      assert_equal 1, ack2["id"]

      # 等待可能的第二条广播——若幂等生效则不会有新 chat
      extra = b.drain(0.3)
      refute(extra.any? { |m| m["type"] == "chat" }, "同 cid 重发产生了第二条广播：#{extra.inspect}")

      a.close
      b.close
    end

    def test_ping_回_pong
      c = TestClient.new(@port)
      c.send_raw(JSON.generate({ "type" => "ping" }))
      assert_equal "pong", c.expect("pong")["type"]
      c.close
    end

    def test_leave_后不再接收广播且可重新加入
      a = TestClient.new(@port)
      b = TestClient.new(@port)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "bob")
      a.expect("joined")

      b.send_raw(JSON.generate({ "type" => "leave" }))
      left = a.expect("left")
      assert_equal "bob", left["nick"]

      # 离开后重进：重新收到 welcome（成员含 alice 与 bob）
      b.join("lobby", "bob")
      welcome = b.expect("welcome")
      assert_equal %w[alice bob], welcome["members"]

      a.close
      b.close
    end
  end
end
