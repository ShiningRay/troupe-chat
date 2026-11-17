require "./spec_helper"

# RoomActor 语义：Fiber 模式 Stage + Memory Provider（与 troupe 自身 typed-agent
# spec 相同的驱动方式；Manual/Rehearsal 模式下 typed agent 的 await 会阻塞）。
module Chat
  describe RoomActor do
    stage = Troupe::Stage.new
    stage.register(RoomActor.troupe_manifest)
    agent = RoomActor::Agent.new(stage)
    room = Troupe::ActorId.new("spec", "room", "lobby")

    it "join 返回 welcome 快照" do
      welcome = agent.join(room, "alice", "conn-a")
      welcome["type"].as_s.should eq("welcome")
      welcome["you"].as_s.should eq("alice")
      welcome["members"].as_a.map(&.as_s).should eq(["alice"])
      welcome["history"].as_a.size.should eq(0)
    end

    it "重名 join 被拒绝且不污染成员表" do
      expect_raises(NickTakenError) do
        agent.join(room, "alice", "conn-a2")
      end
      snap = agent.snapshot(room)
      snap["members"].as_a.map(&.as_s).should eq(["alice"])
    end

    it "post 分配递增 id" do
      m1 = agent.post(room, "alice", "第一条", "cid-1")
      m2 = agent.post(room, "alice", "第二条", "cid-2")
      m1["id"].as_i64.should eq(1)
      m2["id"].as_i64.should eq(2)
      snap = agent.snapshot(room)
      history = snap["history"].as_a
      history.size.should eq(2)
      history[0]["text"].as_s.should eq("第一条")
    end

    it "post 幂等重放：同 cid 不重复入史，同 cid 不同参数拒绝" do
      again = agent.post(room, "alice", "第二条", "cid-2")
      again["id"].as_i64.should eq(2)
      expect_raises(Troupe::IdempotencyConflictError) do
        agent.post(room, "alice", "被篡改的内容", "cid-2")
      end
      snap = agent.snapshot(room)
      snap["history"].as_a.size.should eq(2)
    end

    it "leave 移除成员；重复 leave 幂等" do
      left = agent.leave(room, "alice", "conn-a")
      left["members"].as_a.size.should eq(0)
      again = agent.leave(room, "alice", "conn-a")
      again["type"].as_s.should eq("left")
      again["members"].as_a.size.should eq(0)
    end

    it "空 conn 的 leave 按昵称兜底剔除" do
      agent.join(room, "bob", "conn-b")
      agent.join(room, "carol", "conn-c")
      left = agent.leave(room, "bob", "")
      left["members"].as_a.map(&.as_s).should eq(["carol"])
    end

    it "历史截断到 MAX_HISTORY" do
      hot = Troupe::ActorId.new("spec", "room", "hot")
      1.upto(MAX_HISTORY + 10) do |i|
        agent.post(hot, "spammer", "m#{i}", "hot-#{i}")
      end
      snap = agent.snapshot(hot)
      history = snap["history"].as_a
      history.size.should eq(MAX_HISTORY)
      history.last["text"].as_s.should eq("m#{MAX_HISTORY + 10}")
      history[0]["text"].as_s.should eq("m11")
    end

    it "SQLite 持久化：重开 Stage 后成员与历史恢复" do
      path = File.tempname("troupe-chat-spec", ".db")
      begin
        store = Troupe::SQLitePropStore.open(path)
        stage = Troupe::Stage.new(store: store, ownership: store.ownership)
        stage.register(RoomActor.troupe_manifest)
        a = RoomActor::Agent.new(stage)
        rid = Troupe::ActorId.new("chat", "room", "persist")
        a.join(rid, "dave", "conn-d")
        a.post(rid, "dave", "跨重启仍在", "cid-p")
        stage.shutdown
        store.close # Windows：不关池连接会占住文件句柄

        store2 = Troupe::SQLitePropStore.open(path)
        stage2 = Troupe::Stage.new(store: store2, ownership: store2.ownership)
        stage2.register(RoomActor.troupe_manifest)
        b = RoomActor::Agent.new(stage2)
        welcome = b.join(rid, "erin", "conn-e")
        welcome["you"].as_s.should eq("erin")
        welcome["members"].as_a.map(&.as_s).should eq(["dave", "erin"])
        welcome["history"].as_a.last["text"].as_s.should eq("跨重启仍在")
        stage2.shutdown
        store2.close
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end
