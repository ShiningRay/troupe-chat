# frozen_string_literal: true

# RoomActor 语义：内存 Troupe + cast 直调（对应 troupe-chat/server/spec/room_actor_spec.cr）。

require_relative "test_helper"

module Chat
  class RoomActorTest < Minitest::Test
    def setup
      @troupe = Troupe.form(actors: [RoomActor], prop_store: :memory, transport: false, cue_store: false)
    end

    def teardown
      @troupe.shutdown!
    rescue StandardError
      nil
    end

    def test_join_返回_welcome_快照
      welcome = cast("lobby").join("alice", "conn-a")
      assert_equal "welcome", welcome["type"]
      assert_equal "alice", welcome["you"]
      assert_equal ["alice"], welcome["members"]
      assert_equal [], welcome["history"]
    end

    def test_重名_join_被拒绝且不污染成员表
      room = cast("lobby")
      room.join("alice", "conn-a")
      assert_raises(NickTakenError) { room.join("alice", "conn-a2") }
      snap = cast("lobby").snapshot
      assert_equal ["alice"], snap["members"]
    end

    def test_post_分配递增_id
      room = cast("lobby")
      room.join("alice", "conn-a")
      m1 = room.post("alice", "第一条", "cid-1")
      m2 = room.post("alice", "第二条", "cid-2")
      assert_equal 1, m1["id"]
      assert_equal 2, m2["id"]
      history = cast("lobby").snapshot["history"]
      assert_equal 2, history.size
      assert_equal "第一条", history[0]["text"]
    end

    def test_post_幂等重放_同_cid_不重复入史_同_cid_不同参数拒绝
      room = cast("lobby")
      room.join("alice", "conn-a")
      first = room.post("alice", "第二条", "cid-2")
      again = room.post("alice", "第二条", "cid-2")
      assert_equal first["id"], again["id"] # 重放首次结果
      assert_raises(Troupe::IdempotencyConflictError) { room.post("alice", "被篡改的内容", "cid-2") }
      assert_equal 1, cast("lobby").snapshot["history"].size # 不重复入史
    end

    def test_leave_移除成员_重复_leave_幂等
      room = cast("lobby")
      room.join("alice", "conn-a")
      left = room.leave("alice", "conn-a")
      assert_equal 0, left["members"].size
      again = room.leave("alice", "conn-a")
      assert_equal "left", again["type"]
      assert_equal 0, again["members"].size
    end

    def test_空_conn_的_leave_按昵称兜底剔除
      room = cast("spec-room")
      room.join("bob", "conn-b")
      room.join("carol", "conn-c")
      left = room.leave("bob", "")
      assert_equal ["carol"], left["members"]
    end

    def test_历史截断到_MAX_HISTORY
      hot = cast("hot")
      1.upto(MAX_HISTORY + 10) { |i| hot.post("spammer", "m#{i}", "hot-#{i}") }
      history = cast("hot").snapshot["history"]
      assert_equal MAX_HISTORY, history.size
      assert_equal "m#{MAX_HISTORY + 10}", history.last["text"]
      assert_equal "m11", history[0]["text"] # 前 10 条被截断
    end

    def test_outbox_事件随_save_原子落库_顺序与提交一致
      room = cast("lobby")
      room.join("alice", "conn-a")
      room.post("alice", "消息 A", "cid-a")
      room.post("alice", "消息 B", "cid-b")
      # Memory store 按提交序追加（per-actor 数组），顺序即 Turn 提交顺序
      records = @troupe.prop_store.outbox_records.select { |r| r.stage_name == "lobby" }
      kinds = records.map(&:topic)
      assert_equal %w[joined chat chat], kinds
      assert_equal "消息 A", records[1].payload["text"]
      assert_equal "消息 B", records[2].payload["text"]
    end

    def test_sqlite_outbox_store_持久化_重开后成员与历史恢复
      path = File.join(Dir.tmpdir, "troupe-chat-ruby-spec-#{SecureRandom.uuid}.db")
      begin
        store = SqliteOutboxStore.new(path)
        t1 = Troupe.form(actors: [RoomActor], prop_store: store, transport: false, cue_store: false)
        room = t1.cast(RoomActor, "persist")
        room.join("dave", "conn-d")
        room.post("dave", "跨重启仍在", "cid-p")
        outbox_pending = store.outbox_counts["pending"].to_i
        assert outbox_pending >= 2 # joined + chat
        t1.shutdown!
        store.close

        store2 = SqliteOutboxStore.new(path)
        t2 = Troupe.form(actors: [RoomActor], prop_store: store2, transport: false, cue_store: false)
        welcome = t2.cast(RoomActor, "persist").join("erin", "conn-e")
        assert_equal "erin", welcome["you"]
        assert_equal %w[dave erin], welcome["members"]
        assert_equal "跨重启仍在", welcome["history"].last["text"]
        # 恢复后消息 id 续接，不回退
        assert_equal 2, t2.cast(RoomActor, "persist").post("erin", "新消息", "cid-q")["id"]
        t2.shutdown!
        store2.close
      ensure
        File.delete(path) if File.exist?(path)
      end
    end

    private

    def cast(name)
      @troupe.cast(RoomActor, name)
    end
  end
end
