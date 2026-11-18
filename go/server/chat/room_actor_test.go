package chat

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/ShiningRay/troupe-chat/go/protocol"
	troupe "github.com/ShiningRay/troupe-go"
)

// newMemoryRoomStage 内存 Stage + RoomActor（与 crystal/ruby/js 测试同构）。
func newMemoryRoomStage(t *testing.T) (*troupe.Stage, func()) {
	t.Helper()
	ownership := troupe.NewMemoryOwnershipStore()
	store := troupe.NewMemoryOutboxStore(ownership)
	stage := troupe.NewStage(troupe.WithStore(store), troupe.WithOwnership(ownership), troupe.WithName("chat-test"))
	if err := RoomActorManifest().Register(stage); err != nil {
		t.Fatalf("注册 RoomActor 失败: %v", err)
	}
	return stage, stage.Close
}

func TestJoinReturnsWelcome(t *testing.T) {
	stage, done := newMemoryRoomStage(t)
	defer done()
	w, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		context.Background(), stage, roomActorID("lobby"), "join",
		struct{ Nick, Conn string }{"alice", "conn-a"})
	if err != nil {
		t.Fatal(err)
	}
	if w.Type != "welcome" || w.You != "alice" || w.Room != "lobby" {
		t.Fatalf("welcome 头部不符: %+v", w)
	}
	if len(w.Members) != 1 || w.Members[0] != "alice" || len(w.History) != 0 || w.LastID != 0 {
		t.Fatalf("welcome 快照不符: %+v", w)
	}
}

func TestJoinDuplicateNickRejected(t *testing.T) {
	stage, done := newMemoryRoomStage(t)
	defer done()
	ctx := context.Background()
	in := struct{ Nick, Conn string }{"alice", "conn-a"}
	if _, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, roomActorID("lobby"), "join", in); err != nil {
		t.Fatal(err)
	}
	_, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, roomActorID("lobby"), "join", struct{ Nick, Conn string }{"alice", "conn-a2"})
	if !errors.Is(err, ErrNickTaken) {
		t.Fatalf("期望 nick_taken，得到 %v", err)
	}
	snap, err := troupe.Invoke[struct{}, protocol.WelcomeMsg](ctx, stage, roomActorID("lobby"), "snapshot", struct{}{})
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Members) != 1 || snap.Members[0] != "alice" {
		t.Fatalf("重名拒绝后成员表应不受污染: %+v", snap.Members)
	}
}

func TestPostAssignsIncrementingIDs(t *testing.T) {
	stage, done := newMemoryRoomStage(t)
	defer done()
	ctx := context.Background()
	if _, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, roomActorID("lobby"), "join", struct{ Nick, Conn string }{"alice", "c"}); err != nil {
		t.Fatal(err)
	}
	m1, err := troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, roomActorID("lobby"), "post", struct{ From, Text, CID string }{"alice", "第一条", "cid-1"})
	if err != nil {
		t.Fatal(err)
	}
	m2, err := troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, roomActorID("lobby"), "post", struct{ From, Text, CID string }{"alice", "第二条", "cid-2"})
	if err != nil {
		t.Fatal(err)
	}
	if m1.ID != 1 || m2.ID != 2 {
		t.Fatalf("id 应递增 1,2：得到 %d,%d", m1.ID, m2.ID)
	}
	snap, _ := troupe.Invoke[struct{}, protocol.WelcomeMsg](ctx, stage, roomActorID("lobby"), "snapshot", struct{}{})
	if len(snap.History) != 2 || snap.History[0].Text != "第一条" || snap.LastID != 2 {
		t.Fatalf("快照历史不符: %+v", snap)
	}
}

func TestPostIdempotentReplay(t *testing.T) {
	stage, done := newMemoryRoomStage(t)
	defer done()
	ctx := context.Background()
	// 对齐 crystal spec（共享 Stage，前序用例已 post cid-1/cid-2）：先发两条再重放
	_, _ = troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, roomActorID("lobby"), "post", struct{ From, Text, CID string }{"alice", "第一条", "cid-1"})
	m2, err := troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, roomActorID("lobby"), "post", struct{ From, Text, CID string }{"alice", "第二条", "cid-2"})
	if err != nil {
		t.Fatal(err)
	}
	again, err := troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, roomActorID("lobby"), "post", struct{ From, Text, CID string }{"alice", "第二条", "cid-2"})
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != m2.ID || again.ID != 2 {
		t.Fatalf("同 cid 重放应返回首次结果 id=2：得到 %d", again.ID)
	}
	var conflict *troupe.IdempotencyConflictError
	_, err = troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage, roomActorID("lobby"), "post", struct{ From, Text, CID string }{"alice", "被篡改的内容", "cid-2"})
	if !errors.As(err, &conflict) {
		t.Fatalf("同 cid 不同参数应拒绝：得到 %v", err)
	}
	snap, _ := troupe.Invoke[struct{}, protocol.WelcomeMsg](ctx, stage, roomActorID("lobby"), "snapshot", struct{}{})
	if len(snap.History) != 2 {
		t.Fatalf("历史应仍为 2 条: %d", len(snap.History))
	}
}

func TestLeaveIdempotentAndConnFallback(t *testing.T) {
	stage, done := newMemoryRoomStage(t)
	defer done()
	ctx := context.Background()
	_, _ = troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, roomActorID("lobby"), "join", struct{ Nick, Conn string }{"alice", "conn-a"})
	first, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.PresenceMsg](
		ctx, stage, roomActorID("lobby"), "leave", struct{ Nick, Conn string }{"alice", "conn-a"})
	if err != nil {
		t.Fatal(err)
	}
	if first.Type != "left" || len(first.Members) != 0 {
		t.Fatalf("leave 结果不符: %+v", first)
	}
	again, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.PresenceMsg](
		ctx, stage, roomActorID("lobby"), "leave", struct{ Nick, Conn string }{"alice", "conn-a"})
	if err != nil || again.Type != "left" || len(again.Members) != 0 {
		t.Fatalf("重复 leave 应幂等: %+v err=%v", again, err)
	}
	// 空 conn 按昵称兜底剔除
	_, _ = troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, roomActorID("lobby"), "join", struct{ Nick, Conn string }{"bob", "conn-b"})
	_, _ = troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage, roomActorID("lobby"), "join", struct{ Nick, Conn string }{"carol", "conn-c"})
	left, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.PresenceMsg](
		ctx, stage, roomActorID("lobby"), "leave", struct{ Nick, Conn string }{"bob", ""})
	if err != nil {
		t.Fatal(err)
	}
	if len(left.Members) != 1 || left.Members[0] != "carol" {
		t.Fatalf("空 conn 兜底剔除不符: %+v", left.Members)
	}
}

func TestHistoryTruncatedToMaxHistory(t *testing.T) {
	stage, done := newMemoryRoomStage(t)
	defer done()
	ctx := context.Background()
	id := roomActorID("hot")
	for i := 1; i <= MaxHistory+10; i++ {
		if _, err := troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
			ctx, stage, id, "post", struct{ From, Text, CID string }{"spammer", "m" + itoa(i), "hot-" + itoa(i)}); err != nil {
			t.Fatal(err)
		}
	}
	snap, err := troupe.Invoke[struct{}, protocol.WelcomeMsg](ctx, stage, id, "snapshot", struct{}{})
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.History) != MaxHistory {
		t.Fatalf("历史应截断到 %d: %d", MaxHistory, len(snap.History))
	}
	if snap.History[len(snap.History)-1].Text != "m"+itoa(MaxHistory+10) {
		t.Fatalf("末条应为 m%d", MaxHistory+10)
	}
	if snap.History[0].Text != "m11" {
		t.Fatalf("首条应为 m11: %s", snap.History[0].Text)
	}
}

func TestSQLiteRestartRecovery(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "chat.db")
	rid := roomActorID("persist")

	// 第一阶段：join + post，落盘后关闭（store 需 Outbox 合同：join/post 会 EmitEvent）
	store1, ownership1, err := OpenSQLiteOutbox(path)
	if err != nil {
		t.Fatal(err)
	}
	stage1 := troupe.NewStage(troupe.WithStore(store1), troupe.WithOwnership(ownership1), troupe.WithName("chat-p1"))
	if err := RoomActorManifest().Register(stage1); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err = troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage1, rid, "join", struct{ Nick, Conn string }{"dave", "conn-d"}); err != nil {
		t.Fatal(err)
	}
	if _, err = troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, stage1, rid, "post", struct{ From, Text, CID string }{"dave", "跨重启仍在", "cid-p"}); err != nil {
		t.Fatal(err)
	}
	stage1.Close()
	if err := store1.Close(); err != nil { // Windows：不关句柄会占住文件
		t.Fatal(err)
	}

	// 第二阶段：重开恢复成员与历史
	store2, ownership2, err := OpenSQLiteOutbox(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store2.Close() }()
	stage2 := troupe.NewStage(troupe.WithStore(store2), troupe.WithOwnership(ownership2), troupe.WithName("chat-p2"))
	if err := RoomActorManifest().Register(stage2); err != nil {
		t.Fatal(err)
	}
	w, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, stage2, rid, "join", struct{ Nick, Conn string }{"erin", "conn-e"})
	if err != nil {
		t.Fatal(err)
	}
	if w.You != "erin" {
		t.Fatalf("welcome.you 不符: %s", w.You)
	}
	if len(w.Members) != 2 || w.Members[0] != "dave" || w.Members[1] != "erin" {
		t.Fatalf("重启后成员应恢复: %+v", w.Members)
	}
	if n := len(w.History); n != 1 || w.History[n-1].Text != "跨重启仍在" {
		t.Fatalf("重启后历史应恢复: %+v", w.History)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
