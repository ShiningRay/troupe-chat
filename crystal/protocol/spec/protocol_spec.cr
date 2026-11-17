require "./spec_helper"

module Chat
  module Protocol
    describe Protocol do
      it "编解码 join" do
        raw = Protocol.join("lobby", "alice")
        msg = Protocol.parse_client(JSON.parse(raw))
        msg.should eq(Protocol::JoinMsg.new("lobby", "alice"))
      end

      it "编解码 say（含中文与引号转义）" do
        raw = Protocol.say(%(你好 "world" \n), "c-1")
        msg = Protocol.parse_client(JSON.parse(raw))
        msg.should eq(Protocol::SayMsg.new(%(你好 "world" \n), "c-1"))
      end

      it "编解码 leave/ping" do
        Protocol.parse_client(JSON.parse(Protocol.leave)).should eq(:leave)
        Protocol.parse_client(JSON.parse(Protocol.ping)).should eq(:ping)
      end

      it "拒绝非法上行" do
        expect_raises(Protocol::ParseError) do
          Protocol.parse_client(JSON.parse(%({"type":"join","room":"lobby"})))
        end
        expect_raises(Protocol::ParseError) do
          Protocol.parse_client(JSON.parse(%({"type":"nuke"})))
        end
        expect_raises(Protocol::ParseError) do
          Protocol.parse_client(JSON.parse(%({"room":"lobby"})))
        end
      end

      it "welcome 往返保留历史与成员" do
        history = [
          ChatMessage.new(1_i64, "bob", "hi", 1_700_000_000_000_i64),
          ChatMessage.new(2_i64, "alice", %(中文"测试"), 1_700_000_001_000_i64),
        ]
        payload = Protocol.welcome("lobby", "alice", ["alice", "bob"], history, 2_i64)
        payload["type"].as_s.should eq("welcome")
        payload["you"].as_s.should eq("alice")
        payload["members"].as_a.map(&.as_s).should eq(["alice", "bob"])
        payload["last_id"].as_i64.should eq(2)
        got = payload["history"].as_a
        got.size.should eq(2)
        got[0]["from"].as_s.should eq("bob")
        got[1]["text"].as_s.should eq(%(中文"测试"))
        got[1]["id"].as_i64.should eq(2)
      end

      it "chat 广播与 ack 形状" do
        chat = Protocol.chat_msg("lobby", 7_i64, "alice", "hello", 42_i64)
        chat["type"].as_s.should eq("chat")
        chat["id"].as_i64.should eq(7)
        ack = Protocol.ack("c-9", 7_i64)
        ack["cid"].as_s.should eq("c-9")
        ack["id"].as_i64.should eq(7)
      end

      it "joined/left/error/pong 形状" do
        Protocol.joined("lobby", "bob", ["alice", "bob"])["nick"].as_s.should eq("bob")
        Protocol.left("lobby", "bob", ["alice"])["members"].as_a.size.should eq(1)
        Protocol.error("nick_taken", "昵称已被占用")["code"].as_s.should eq("nick_taken")
        Protocol.pong["type"].as_s.should eq("pong")
        Protocol.disconnected("closed")["type"].as_s.should eq("disconnected")
      end
    end
  end
end
