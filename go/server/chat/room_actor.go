// Package chat 实现 TroupeChat 服务端业务：RoomActor（房间 Virtual Actor）与
// WebSocket 网关的应用协议路由（传输管理由 troupe-gateway-go 承担，ADR-0007 L3）。
//
// 与 crystal/ruby/js 版逐条对齐（协议权威见 ../../docs/protocol.md）：
//   - 每房间一个 RoomActor（role=room, name=房间名）：成员/最近消息为 Props，
//     随 Save/幂等提交原子落盘（SQLite WAL，重启即回放）；
//   - 发言以客户端 cid 作幂等键；广播经 EmitEvent 写 Outbox（与 Props 同原子提交），
//     troupe-gateway-go 逐 actor 轮询派发 —— 广播顺序与 Turn 提交顺序严格一致；
//   - 网关断线兜底补 leave（actor 内 conn 为空串时按昵称剔除）。
package chat

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/ShiningRay/troupe-chat/go/protocol"
	troupe "github.com/ShiningRay/troupe-go"
)

// MaxHistory 欢迎快照携带的历史上限（对齐 crystal MAX_HISTORY）。
const MaxHistory = 200

// RoomTopicPrefix 房间 Outbox 话题前缀（对齐 crystal/js 的 chat:<room>）。
const RoomTopicPrefix = "chat:"

// ErrNickTaken 昵称被占用：业务哨兵错误，Turn 内抛出后原样送达调用方
// （网关按 errors.Is 映射为 nick_taken）。
var ErrNickTaken = fmt.Errorf("昵称已被占用")

// RoomProps 房间状态（Props，随提交原子持久化）。
type RoomProps struct {
	NextID   int64                  `json:"nextId"`
	Members  []RoomMember           `json:"members"`
	Messages []protocol.ChatMessage `json:"messages"`
}

// RoomMember 在场成员：昵称 + 网关连接 id。
type RoomMember struct {
	Nick string `json:"nick"`
	Conn string `json:"conn"`
}

// RoomActor 房间 Virtual Actor。
type RoomActor struct {
	*troupe.Actor[RoomProps]
}

// RoomActorManifest 定义 RoomActor 的四个 Turn（join/post/leave/snapshot）。
func RoomActorManifest() *troupe.Manifest[RoomProps, *RoomActor] {
	m := troupe.Define("room", func(id troupe.ActorID, props RoomProps, actx *troupe.ActivationContext) *RoomActor {
		return &RoomActor{Actor: troupe.NewActor(id, props, actx)}
	})
	m.SchemaVersion(1)
	m.Initial(func() RoomProps {
		return RoomProps{NextID: 1, Members: []RoomMember{}, Messages: []protocol.ChatMessage{}}
	})
	m.Turn(troupe.Turn("join", func(a *RoomActor, ctx *troupe.CallContext, args struct {
		Nick string `json:"Nick"`
		Conn string `json:"Conn"`
	}) (protocol.WelcomeMsg, error) {
		return a.join(args.Nick, args.Conn)
	}))
	m.Turn(troupe.Turn("post", func(a *RoomActor, ctx *troupe.CallContext, args struct {
		From string `json:"From"`
		Text string `json:"Text"`
		CID  string `json:"CID"`
	}) (protocol.ChatMsg, error) {
		return a.post(args.From, args.Text, args.CID)
	}))
	m.Turn(troupe.Turn("leave", func(a *RoomActor, ctx *troupe.CallContext, args struct {
		Nick string `json:"Nick"`
		Conn string `json:"Conn"`
	}) (protocol.PresenceMsg, error) {
		return a.leave(args.Nick, args.Conn)
	}))
	m.Turn(troupe.Turn("snapshot", func(a *RoomActor, ctx *troupe.CallContext, structArgs struct{}) (protocol.WelcomeMsg, error) {
		return a.snapshot(), nil
	}))
	return m
}

// ---- Turn 实现 ----

// join 加入房间：重名拒绝；成功后 EmitEvent(joined) 并返回 welcome 快照。
func (a *RoomActor) join(nick, conn string) (protocol.WelcomeMsg, error) {
	p := a.Props()
	if a.member(nick) {
		return protocol.WelcomeMsg{}, fmt.Errorf("%w：%s", ErrNickTaken, nick)
	}
	p.Members = append(p.Members, RoomMember{Nick: nick, Conn: conn})
	if err := a.EmitPresence("joined", nick); err != nil { // 先记 Outbox，Save 与之同原子提交
		return protocol.WelcomeMsg{}, err
	}
	if err := a.Save(); err != nil {
		return protocol.WelcomeMsg{}, err
	}
	return a.welcome(nick), nil
}

// post 发言：cid 作幂等键。首次执行：分配消息 id → 追加（截断到 MaxHistory）→
// EmitEvent(chat) → Idempotent 与 Props/journal/outbox 一次原子提交；
// 重放：直接返回首次结果，不重复落库也不重复广播。
func (a *RoomActor) post(from, text, cid string) (protocol.ChatMsg, error) {
	fingerprint := "post|" + from + "|" + text
	raw, err := a.Idempotent(cid, fingerprint, func() (any, error) {
		msg := a.appendMessage(from, text)
		a.emitChat(msg)
		return msg, nil
	})
	if err != nil {
		return protocol.ChatMsg{}, err
	}
	var msg protocol.ChatMessage
	if err := jsonUnmarshal(raw, &msg); err != nil {
		return protocol.ChatMsg{}, err
	}
	return *protocol.NewChat(a.roomName(), msg.ID, msg.From, msg.Text, msg.TS), nil
}

// leave 离开：conn 空串时按昵称剔除（网关断线兜底路径）。
// 重复 leave（本就不是成员）幂等：无变化则不广播不落盘。
func (a *RoomActor) leave(nick, conn string) (protocol.PresenceMsg, error) {
	p := a.Props()
	kept := p.Members[:0]
	removed := false
	for _, m := range p.Members {
		hit := m.Nick == nick && (conn == "" || m.Conn == conn)
		if hit {
			removed = true
			continue
		}
		kept = append(kept, m)
	}
	p.Members = kept
	if removed {
		if err := a.EmitPresence("left", nick); err != nil { // 先记 Outbox，Save 与之同原子提交
			return protocol.PresenceMsg{}, err
		}
		if err := a.Save(); err != nil {
			return protocol.PresenceMsg{}, err
		}
	}
	return *protocol.NewLeft(a.roomName(), nick, a.nickList()), nil
}

// snapshot 只读快照（welcome 形状，you 为空串）。
func (a *RoomActor) snapshot() protocol.WelcomeMsg {
	return a.welcome("")
}

// ---- 内部 ----

func (a *RoomActor) welcome(you string) protocol.WelcomeMsg {
	return *protocol.NewWelcome(a.roomName(), you, a.nickList(), a.Props().Messages, a.lastID())
}

func (a *RoomActor) roomName() string { return a.ID().Key }

func (a *RoomActor) member(nick string) bool {
	for _, m := range a.Props().Members {
		if m.Nick == nick {
			return true
		}
	}
	return false
}

func (a *RoomActor) nickList() []string {
	out := make([]string, 0, len(a.Props().Members))
	for _, m := range a.Props().Members {
		out = append(out, m.Nick)
	}
	return out
}

func (a *RoomActor) lastID() int64 {
	p := a.Props()
	if n := len(p.Messages); n > 0 {
		return p.Messages[n-1].ID
	}
	return p.NextID - 1
}

// appendMessage 分配递增 id 并追加（截断到 MaxHistory）；仅改内存，由提交方落盘。
func (a *RoomActor) appendMessage(from, text string) protocol.ChatMessage {
	p := a.Props()
	msg := protocol.ChatMessage{ID: p.NextID, From: from, Text: text, TS: time.Now().UTC().UnixMilli()}
	p.NextID++
	p.Messages = append(p.Messages, msg)
	if len(p.Messages) > MaxHistory {
		p.Messages = p.Messages[len(p.Messages)-MaxHistory:]
	}
	return msg
}

// emitChat 记入 Outbox（随下次提交原子落盘，gateway 派发至少一次）。
func (a *RoomActor) emitChat(msg protocol.ChatMessage) {
	_, _ = a.EmitEvent(RoomTopicPrefix+a.roomName(), protocol.NewChat(a.roomName(), msg.ID, msg.From, msg.Text, msg.TS))
}

// EmitPresence joined/left 事件（join/leave 调用方在 Save 前调用）。
func (a *RoomActor) EmitPresence(kind, nick string) error {
	room := a.roomName()
	var payload any
	if kind == "joined" {
		payload = protocol.NewJoined(room, nick, a.nickList())
	} else {
		payload = protocol.NewLeft(room, nick, a.nickList())
	}
	_, err := a.EmitEvent(RoomTopicPrefix+room, payload)
	return err
}

// jsonUnmarshal 小工具（避免各处直接引 encoding/json）。
func jsonUnmarshal(raw json.RawMessage, v any) error {
	return json.Unmarshal(raw, v)
}
