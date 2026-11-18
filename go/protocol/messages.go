// Package chatprotocol 实现 TroupeChat WebSocket 协议 v1 的编解码
// （与 crystal/ruby/js 版逐条对齐；协议权威见 ../docs/protocol.md）。
//
// 全部消息都是单条 JSON 文本帧。零第三方依赖。
package protocol

import (
	"encoding/json"
	"fmt"
)

// ChatMessage 一条聊天消息（历史/广播/welcome 复用同一形状）。
type ChatMessage struct {
	ID   int64  `json:"id"`
	From string `json:"from"`
	Text string `json:"text"`
	TS   int64  `json:"ts"` // UTC 毫秒
}

// ---- 客户端 → 服务端 ----

// JoinMsg join 消息（room/nick 非空）。
type JoinMsg struct {
	Room string `json:"room"`
	Nick string `json:"nick"`
}

// SayMsg say 消息（cid 为客户端幂等键，可空串）。
type SayMsg struct {
	Text string `json:"text"`
	CID  string `json:"cid"`
}

// ClientKind 上行消息类别：join/say/leave/ping。
type ClientKind int

const (
	KindJoin ClientKind = iota
	KindSay
	KindLeave
	KindPing
)

// ClientMsg 解析后的上行消息；Kind 为 KindLeave/KindPing 时其余字段无意义。
type ClientMsg struct {
	Kind ClientKind
	Join JoinMsg
	Say  SayMsg
}

// ParseError 非法上行结构（缺字段/空串字段/未知类型/非对象）。
type ParseError struct{ msg string }

func (e *ParseError) Error() string { return e.msg }

func parseErr(format string, args ...any) error {
	return &ParseError{msg: fmt.Sprintf(format, args...)}
}

// ParseClient 解析客户端上行消息。非法结构返回 *ParseError（网关映射为 bad_request）。
func ParseClient(raw []byte) (*ClientMsg, error) {
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, parseErr("%s", err.Error())
	}
	typ, _ := obj["type"].(string)
	if typ == "" {
		return nil, parseErr("缺少 type 字段")
	}
	switch typ {
	case "join":
		room, err := requireString(obj, "room")
		if err != nil {
			return nil, err
		}
		nick, err := requireString(obj, "nick")
		if err != nil {
			return nil, err
		}
		return &ClientMsg{Kind: KindJoin, Join: JoinMsg{Room: room, Nick: nick}}, nil
	case "say":
		text, err := requireString(obj, "text")
		if err != nil {
			return nil, err
		}
		cid, _ := obj["cid"].(string)
		return &ClientMsg{Kind: KindSay, Say: SayMsg{Text: text, CID: cid}}, nil
	case "leave":
		return &ClientMsg{Kind: KindLeave}, nil
	case "ping":
		return &ClientMsg{Kind: KindPing}, nil
	default:
		return nil, parseErr("未知消息类型：%s", typ)
	}
}

func requireString(obj map[string]any, key string) (string, error) {
	v, _ := obj[key].(string)
	if v == "" {
		return "", parseErr("缺少字段 %s", key)
	}
	return v, nil
}

// JoinFrame 构造上行 join 帧（客户端侧）。
func JoinFrame(room, nick string) []byte {
	b, _ := json.Marshal(map[string]string{"type": "join", "room": room, "nick": nick})
	return b
}

// SayFrame 构造上行 say 帧（客户端侧）。
func SayFrame(text, cid string) []byte {
	b, _ := json.Marshal(map[string]string{"type": "say", "text": text, "cid": cid})
	return b
}

// ---- 服务端 → 客户端 ----

// WelcomeMsg join 成功后的房间快照（历史 ≤ MAX_HISTORY，见 RoomActor）。
type WelcomeMsg struct {
	Type    string        `json:"type"` // "welcome"
	Room    string        `json:"room"`
	You     string        `json:"you"`
	Members []string      `json:"members"`
	LastID  int64         `json:"last_id"`
	History []ChatMessage `json:"history"`
}

// ChatMsg 房间广播（有序，含本人发言回声；客户端按 id 去重）。
type ChatMsg struct {
	Type string `json:"type"` // "chat"
	Room string `json:"room"`
	ID   int64  `json:"id"`
	From string `json:"from"`
	Text string `json:"text"`
	TS   int64  `json:"ts"`
}

// AckMsg say 已提交；ID 为服务端消息号。
type AckMsg struct {
	Type string `json:"type"` // "ack"
	CID  string `json:"cid"`
	ID   int64  `json:"id"`
}

// PresenceMsg joined/left 成员广播（不回发本人）。
type PresenceMsg struct {
	Type    string   `json:"type"` // "joined" | "left"
	Room    string   `json:"room"`
	Nick    string   `json:"nick"`
	Members []string `json:"members"`
}

// ErrorMsg 错误；Code ∈ nick_taken / no_room / bad_request / id_conflict /
// say_failed / join_failed / leave_failed / internal / connect_failed。
type ErrorMsg struct {
	Type    string `json:"type"` // "error"
	Code    string `json:"code"`
	Message string `json:"message"`
}

// PongMsg 心跳应答。
type PongMsg struct {
	Type string `json:"type"` // "pong"
}

// NewWelcome 构造 welcome。
func NewWelcome(room, you string, members []string, history []ChatMessage, lastID int64) *WelcomeMsg {
	if members == nil {
		members = []string{}
	}
	if history == nil {
		history = []ChatMessage{}
	}
	return &WelcomeMsg{Type: "welcome", Room: room, You: you, Members: members, LastID: lastID, History: history}
}

// NewChat 构造 chat 广播。
func NewChat(room string, id int64, from, text string, ts int64) *ChatMsg {
	return &ChatMsg{Type: "chat", Room: room, ID: id, From: from, Text: text, TS: ts}
}

// NewAck 构造 ack。
func NewAck(cid string, id int64) *AckMsg { return &AckMsg{Type: "ack", CID: cid, ID: id} }

// NewJoined 构造 joined 广播。
func NewJoined(room, nick string, members []string) *PresenceMsg {
	if members == nil {
		members = []string{}
	}
	return &PresenceMsg{Type: "joined", Room: room, Nick: nick, Members: members}
}

// NewLeft 构造 left 广播。
func NewLeft(room, nick string, members []string) *PresenceMsg {
	if members == nil {
		members = []string{}
	}
	return &PresenceMsg{Type: "left", Room: room, Nick: nick, Members: members}
}

// NewError 构造 error。
func NewError(code, message string) *ErrorMsg {
	return &ErrorMsg{Type: "error", Code: code, Message: message}
}

// NewPong 构造 pong。
func NewPong() *PongMsg { return &PongMsg{Type: "pong"} }
