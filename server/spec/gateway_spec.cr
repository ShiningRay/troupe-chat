require "./spec_helper"

# 网关端到端：真实 HTTP::WebSocket 连接，覆盖 join/say/ack/广播/断线补 leave。
module Chat
  describe Gateway do
    it "join→welcome，say→ack，双方都收到广播" do
      gateway, stage, port = new_gateway
      url = "ws://127.0.0.1:#{port}/"
      a = TestClient.new(url)
      b = TestClient.new(url)

      a.join("lobby", "alice")
      welcome = a.expect("welcome")
      welcome["you"].as_s.should eq("alice")

      b.join("lobby", "bob")
      b.expect("welcome")
      joined = a.expect("joined")
      joined["nick"].as_s.should eq("bob")
      joined["members"].as_a.map(&.as_s).should eq(["alice", "bob"])

      a.say("大家好", "c-1")
      ack = a.expect("ack")
      ack["cid"].as_s.should eq("c-1")
      id = ack["id"].as_i64

      chat_a = a.expect("chat")
      chat_a["id"].as_i64.should eq(id)
      chat_a["from"].as_s.should eq("alice")
      chat_a["text"].as_s.should eq("大家好")

      chat_b = b.expect("chat")
      chat_b["id"].as_i64.should eq(id)

      gateway.stop
      a.close
      b.close
    end

    it "后加入者的 welcome 携带已有历史（Outbox 事件不回灌历史）" do
      gateway, stage, port = new_gateway
      url = "ws://127.0.0.1:#{port}/"
      a = TestClient.new(url)
      b = TestClient.new(url)

      a.join("lobby", "alice")
      a.expect("welcome")
      a.say("第一条历史", "h1")
      a.expect("ack")
      a.expect("chat")

      b.join("lobby", "bob")
      welcome = b.expect("welcome")
      history = welcome["history"].as_a
      history.size.should eq(1)
      history[0]["text"].as_s.should eq("第一条历史")
      history[0]["from"].as_s.should eq("alice")
      welcome["last_id"].as_i64.should eq(1)

      gateway.stop
      a.close
      b.close
    end

    it "重名 join 得到 nick_taken 错误" do
      gateway, stage, port = new_gateway
      url = "ws://127.0.0.1:#{port}/"
      a = TestClient.new(url)
      b = TestClient.new(url)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "alice")
      err = b.expect("error")
      err["code"].as_s.should eq("nick_taken")

      gateway.stop
      a.close
      b.close
    end

    it "未加入房间就 say 得到 no_room；非法 JSON 得到 bad_request" do
      gateway, stage, port = new_gateway
      url = "ws://127.0.0.1:#{port}/"
      c = TestClient.new(url)

      c.say("hello", "c-0")
      err = c.expect("error")
      err["code"].as_s.should eq("no_room")

      c.send(%({"type":"broken"))
      err2 = c.expect("error")
      err2["code"].as_s.should eq("bad_request")

      gateway.stop
      c.close
    end

    it "断线后其他成员收到 left（actor 侧兜底剔除）" do
      gateway, stage, port = new_gateway
      url = "ws://127.0.0.1:#{port}/"
      a = TestClient.new(url)
      b = TestClient.new(url)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "bob")
      a.expect("joined")

      b.close
      left = a.expect("left", timeout: 5.seconds)
      left["nick"].as_s.should eq("bob")

      gateway.stop
      a.close
    end

    it "say 幂等：同 cid 重发只产生一条广播" do
      gateway, stage, port = new_gateway
      url = "ws://127.0.0.1:#{port}/"
      a = TestClient.new(url)
      b = TestClient.new(url)

      a.join("lobby", "alice")
      a.expect("welcome")
      b.join("lobby", "bob")
      a.expect("joined")

      a.say("只算一次", "same-cid")
      a.expect("ack")
      a.expect("chat")
      b_chat = b.expect("chat")
      b_chat["id"].as_i64.should eq(1)

      a.say("只算一次", "same-cid")
      ack2 = a.expect("ack")
      ack2["cid"].as_s.should eq("same-cid")
      ack2["id"].as_i64.should eq(1)

      # 等待可能的第二条广播——若幂等生效则不会有新 chat
      sleep 300.milliseconds
      extra = b.next_message(300.milliseconds)
      raise "同 cid 重发产生了第二条广播" if extra && extra["type"].as_s == "chat"

      gateway.stop
      a.close
      b.close
    end
  end
end
