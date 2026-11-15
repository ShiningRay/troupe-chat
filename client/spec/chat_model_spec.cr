require "./spec_helper"
require "protocol"

private def j(raw : String) : JSON::Any
  JSON.parse(raw)
end

# ChatModel：纯状态机（无 UI/网络），覆盖协议 → 状态转移的核心路径。
describe ChatModel do
  it "welcome 进入 joined 并装载成员/历史" do
    m = ChatModel.new
    m.ingest(j(%({"type":"welcome","room":"lobby","you":"alice","members":["alice","bob"],
      "last_id":2,"history":[{"id":1,"from":"bob","text":"hi","ts":1700000000000}]})))
    m.state.should eq(:joined)
    m.room.should eq("lobby")
    m.you.should eq("alice")
    m.members.should eq(["alice", "bob"])
    m.messages.size.should eq(1)
    m.messages[0].from.should eq("bob")
  end

  it "chat 按消息 id 去重（welcome 与广播合并不重复）" do
    m = ChatModel.new
    m.ingest(j(%({"type":"chat","room":"lobby","id":5,"from":"bob","text":"hi","ts":1})))
    m.ingest(j(%({"type":"chat","room":"lobby","id":5,"from":"bob","text":"hi","ts":1})))
    m.messages.size.should eq(1)
  end

  it "joined/left 生成系统行并刷新成员" do
    m = ChatModel.new
    m.ingest(j(%({"type":"welcome","room":"lobby","you":"alice","members":["alice"],
      "last_id":0,"history":[]})))
    m.ingest(j(%({"type":"joined","room":"lobby","nick":"bob","members":["alice","bob"]})))
    m.members.should eq(["alice", "bob"])
    m.messages.last.from.should eq("")
    m.messages.last.text.should contain("bob")
    m.ingest(j(%({"type":"left","room":"lobby","nick":"bob","members":["alice"]})))
    m.members.should eq(["alice"])
    m.messages.last.text.should contain("离开")
  end

  it "error 未入房时回退 idle 并填 login_error" do
    m = ChatModel.new
    m.mark_connecting
    m.ingest(j(%({"type":"error","code":"nick_taken","message":"昵称已被占用：alice"})))
    m.state.should eq(:idle)
    m.login_error.should contain("昵称已被占用")
  end

  it "disconnected/connect_failed 回退 idle" do
    m = ChatModel.new
    m.ingest(j(%({"type":"welcome","room":"lobby","you":"a","members":["a"],"last_id":0,"history":[]})))
    m.ingest(j(%({"type":"disconnected","reason":"closed"})))
    m.state.should eq(:idle)
    m.ingest(j(%({"type":"connect_failed","reason":"refused"})))
    m.state.should eq(:idle)
    m.login_error.should contain("refused")
  end

  it "ingest 返回是否有变化，consume_dirty 拉取计数" do
    m = ChatModel.new
    m.ingest(j(%({"type":"ping"}))).should be_false
    m.ingest(j(%({"type":"pong"}))).should be_true
    m.consume_dirty.should be > 0
    m.consume_dirty.should eq(0)
  end
end
