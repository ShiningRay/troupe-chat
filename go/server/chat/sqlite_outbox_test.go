package chat

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/ShiningRay/troupe-chat/go/protocol"
	troupe "github.com/ShiningRay/troupe-go"
)

// TestSQLiteOutboxAtomicWrite 事件与 Props 同事务原子提交：
// EmitEvent + Save 后 props 推进、PollOutbox 可取、MarkSent 后不再返回。
func TestSQLiteOutboxAtomicWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "chat.db")
	store, ownership, err := OpenSQLiteOutbox(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	stage := troupe.NewStage(troupe.WithStore(store), troupe.WithOwnership(ownership), troupe.WithName("chat-ob"))
	if err := RoomActorManifest().Register(stage); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	rid := roomActorID("lobby")
	if _, err = troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, rid, "join", struct{ Nick, Conn string }{"alice", "c"}); err != nil {
		t.Fatal(err)
	}
	if _, err = troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, rid, "post", struct{ From, Text, CID string }{"alice", "hi", "cid-1"}); err != nil {
		t.Fatal(err)
	}
	recs, err := store.PollOutbox(ctx, rid, 64)
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 2 { // joined + chat 同批落盘
		t.Fatalf("应轮询到 joined+chat 两条事件: %d", len(recs))
	}
	if recs[0].Topic != "chat:lobby" || recs[1].Topic != "chat:lobby" {
		t.Fatalf("话题应为 chat:lobby: %q, %q", recs[0].Topic, recs[1].Topic)
	}
	if !store.MarkSent(ctx, rid, recs[0].EventID) {
		t.Fatal("MarkSent 应成功")
	}
	if store.MarkSent(ctx, rid, recs[0].EventID) {
		t.Fatal("重复 MarkSent 应返回 false（幂等）")
	}
	recs2, err := store.PollOutbox(ctx, rid, 64)
	if err != nil {
		t.Fatal(err)
	}
	if len(recs2) != 1 || recs2[0].EventID != recs[1].EventID {
		t.Fatalf("MarkSent 后应只剩一条: %d", len(recs2))
	}
}

// TestSQLiteOutboxCASConflict 事件提交保持 Props CAS 语义：
// revision 冲突时整体回滚（outbox 不残留）。
func TestSQLiteOutboxCASConflict(t *testing.T) {
	path := filepath.Join(t.TempDir(), "chat.db")
	store, ownership, err := OpenSQLiteOutbox(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	ctx := context.Background()
	rid := roomActorID("lobby")

	// 真实流：激活先 Acquire 发放 epoch（fencing token）
	epoch, err := ownership.Acquire(ctx, rid)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.Create(ctx, rid, 1, `{"nextId":1}`, epoch); err != nil {
		t.Fatal(err)
	}
	// 正常写（Create 后 revision=1）推进 revision → 2
	if _, err = store.WriteWithOutbox(ctx, rid, 1, 1, `{"nextId":2}`, epoch, nil,
		[]troupe.OutboxRecord{{EventID: "e1", Topic: "chat:lobby", Payload: json.RawMessage(`{"ok":1}`)}}); err != nil {
		t.Fatal(err)
	}
	// 旧 revision 再写：CAS 失败，outbox 不得落盘
	if _, err = store.WriteWithOutbox(ctx, rid, 1, 1, `{"nextId":3}`, epoch, nil,
		[]troupe.OutboxRecord{{EventID: "e2", Topic: "chat:lobby", Payload: json.RawMessage(`{"ok":2}`)}}); err == nil {
		t.Fatal("旧 revision 写应 CAS 冲突")
	}
	recs, err := store.PollOutbox(ctx, rid, 64)
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 1 || recs[0].EventID != "e1" {
		t.Fatalf("CAS 失败回滚后应只有 e1: %+v", recs)
	}
}
