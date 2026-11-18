package chat

// 网关端到端：真实 WebSocket 连接（自写最小 RFC 6455 测试客户端），
// 场景对照 crystal/ruby/js 三版 spec：join→welcome、say→ack→广播、
// 重名拒绝、晚加入历史、no_room/bad_request、断线兜底 left、say 幂等、
// ping→pong、ack 先于本人回声、主动 leave 无回包。

import (
	"bufio"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ShiningRay/troupe-chat/go/protocol"
	troupe "github.com/ShiningRay/troupe-go"
)

// ---- 最小 RFC 6455 测试客户端 ----

type wsClient struct {
	t      *testing.T
	conn   net.Conn
	br     *bufio.Reader
	mu     sync.Mutex
	queue  [][]byte
	closed bool
}

func dialWS(t *testing.T, port int) *wsClient {
	t.Helper()
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		t.Fatalf("连接失败: %v", err)
	}
	key := make([]byte, 16)
	_, _ = rand.Read(key)
	req := "GET / HTTP/1.1\r\nHost: " + addr + "\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + base64Key(key) + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatalf("握手写入失败: %v", err)
	}
	br := bufio.NewReader(conn)
	status, err := br.ReadString('\n')
	if err != nil || !strings.Contains(status, "101") {
		conn.Close()
		t.Fatalf("握手失败: %s %v", strings.TrimSpace(status), err)
	}
	for {
		line, rerr := br.ReadString('\n')
		if rerr != nil || line == "\r\n" {
			break
		}
	}
	c := &wsClient{t: t, conn: conn, br: br}
	go c.readLoop()
	return c
}

func base64Key(b []byte) string {
	const tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var out strings.Builder
	for i := 0; i < len(b); i += 3 {
		var v uint32
		n := len(b) - i
		if n > 3 {
			n = 3
		}
		for j := 0; j < n; j++ {
			v |= uint32(b[i+j]) << (8 * (2 - j))
		}
		out.WriteByte(tbl[(v>>18)&0x3f])
		out.WriteByte(tbl[(v>>12)&0x3f])
		if n >= 2 {
			out.WriteByte(tbl[(v>>6)&0x3f])
		} else {
			out.WriteByte('=')
		}
		if n >= 3 {
			out.WriteByte(tbl[v&0x3f])
		} else {
			out.WriteByte('=')
		}
	}
	return out.String()
}

func (c *wsClient) sendRaw(raw string) {
	c.writeMasked(opTextTest, []byte(raw))
}

func (c *wsClient) send(msg any) {
	if raw, ok := msg.([]byte); ok {
		c.sendRaw(string(raw)) // []byte 直接发送（json.Marshal 会误编码成 base64）
		return
	}
	b, err := json.Marshal(msg)
	if err != nil {
		c.t.Fatalf("消息序列化失败: %v", err)
	}
	c.sendRaw(string(b))
}

func (c *wsClient) closeConn() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.mu.Unlock()
	c.writeMasked(opCloseTest, []byte{0x03, 0xe8})
	_ = c.conn.Close()
}

func (c *wsClient) hardClose() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.mu.Unlock()
	_ = c.conn.Close() // 不握手直接断（触发服务端断线兜底）
}

// expectType 等待第一条 type 匹配的消息（不匹配的按到达顺序丢弃）。
func (c *wsClient) expectType(typ string, timeout time.Duration) map[string]any {
	c.t.Helper()
	return c.expect(timeout, func(m map[string]any) bool { return m["type"] == typ })
}

// nextAny 下一条任意消息（断言到达顺序用）。
func (c *wsClient) nextAny(timeout time.Duration) map[string]any {
	c.t.Helper()
	return c.expect(timeout, func(map[string]any) bool { return true })
}

// assertSilence 短暂等待断言无消息。
func (c *wsClient) assertSilence(timeout time.Duration) {
	c.t.Helper()
	if raw, ok := c.next(timeout); ok {
		c.t.Fatalf("不应收到消息，却收到: %s", raw)
	}
}

func (c *wsClient) expect(timeout time.Duration, pred func(map[string]any) bool) map[string]any {
	c.t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			c.t.Fatal("等待消息超时")
		}
		raw, ok := c.next(remaining)
		if !ok {
			c.t.Fatal("等待消息超时")
		}
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			c.t.Fatalf("JSON 解析失败: %v (%s)", err, raw)
		}
		if pred(m) {
			return m
		}
	}
}

func (c *wsClient) next(timeout time.Duration) ([]byte, bool) {
	deadline := time.Now().Add(timeout)
	for {
		c.mu.Lock()
		if len(c.queue) > 0 {
			raw := c.queue[0]
			c.queue = c.queue[1:]
			c.mu.Unlock()
			return raw, true
		}
		c.mu.Unlock()
		if time.Now().After(deadline) {
			return nil, false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (c *wsClient) readLoop() {
	for {
		fin, op, payload, err := c.readFrame()
		if err != nil || op == opCloseTest {
			c.mu.Lock()
			c.closed = true
			c.mu.Unlock()
			return
		}
		if op == opTextTest && fin {
			c.mu.Lock()
			c.queue = append(c.queue, payload)
			c.mu.Unlock()
		}
	}
}

func (c *wsClient) readFrame() (bool, byte, []byte, error) {
	var head [2]byte
	if _, err := readFullTest(c.br, head[:]); err != nil {
		return false, 0, nil, err
	}
	fin := head[0]&0x80 != 0
	op := head[0] & 0x0f
	length := uint64(head[1] & 0x7f)
	if length == 126 {
		var ext [2]byte
		if _, err := readFullTest(c.br, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	} else if length == 127 {
		var ext [8]byte
		if _, err := readFullTest(c.br, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	payload := make([]byte, length)
	if length > 0 {
		if _, err := readFullTest(c.br, payload); err != nil {
			return false, 0, nil, err
		}
	}
	return fin, op, payload, nil
}

func readFullTest(br *bufio.Reader, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := br.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

func (c *wsClient) writeMasked(op byte, payload []byte) {
	mask := make([]byte, 4)
	_, _ = rand.Read(mask)
	masked := make([]byte, len(payload))
	for i, b := range payload {
		masked[i] = b ^ mask[i%4]
	}
	length := len(masked)
	var head []byte
	if length < 126 {
		head = []byte{0x80 | op, 0x80 | byte(length)}
	} else if length < 65536 {
		head = []byte{0x80 | op, 0x80 | 126, 0, 0}
		binary.BigEndian.PutUint16(head[2:], uint16(length))
	} else {
		head = []byte{0x80 | op, 0x80 | 127, 0, 0, 0, 0, 0, 0, 0, 0}
		binary.BigEndian.PutUint64(head[2:], uint64(length))
	}
	frame := append(append(head, mask...), masked...)
	if _, err := c.conn.Write(frame); err != nil && !c.closed {
		c.t.Fatalf("写帧失败: %v", err)
	}
}

const (
	opTextTest  byte = 0x1
	opCloseTest byte = 0x8
)

// ---- 网关起服（内存库） ----

func newTestGateway(t *testing.T) (port int, stop func()) {
	t.Helper()
	ownership := troupe.NewMemoryOwnershipStore()
	store := troupe.NewMemoryOutboxStore(ownership)
	stage := troupe.NewStage(troupe.WithStore(store), troupe.WithOwnership(ownership), troupe.WithName("chat-e2e"))
	if err := RoomActorManifest().Register(stage); err != nil {
		t.Fatalf("注册失败: %v", err)
	}
	g := NewGateway(stage, store)
	p, err := g.Listen("127.0.0.1", 0)
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	return p, func() { g.Stop(); stage.Close() }
}

// ---- 场景 ----

func TestE2EJoinSayAckBroadcast(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	a := dialWS(t, port)
	defer a.closeConn()
	b := dialWS(t, port)
	defer b.closeConn()

	a.send(protocol.JoinFrame("lobby", "alice"))
	w := a.expectType("welcome", 3*time.Second)
	if w["you"] != "alice" {
		t.Fatalf("welcome.you 不符: %v", w["you"])
	}

	b.send(protocol.JoinFrame("lobby", "bob"))
	_ = b.expectType("welcome", 3*time.Second)
	joined := a.expectType("joined", 3*time.Second)
	if joined["nick"] != "bob" {
		t.Fatalf("joined.nick 不符: %v", joined)
	}
	members := joined["members"].([]any)
	if len(members) != 2 || members[0] != "alice" || members[1] != "bob" {
		t.Fatalf("joined.members 不符: %v", members)
	}

	a.send(protocol.SayFrame("大家好", "c-1"))
	ack := a.expectType("ack", 3*time.Second)
	if ack["cid"] != "c-1" {
		t.Fatalf("ack.cid 不符: %v", ack)
	}
	id := ack["id"].(float64)

	chatA := a.expectType("chat", 3*time.Second)
	if chatA["id"] != id || chatA["from"] != "alice" || chatA["text"] != "大家好" {
		t.Fatalf("chat 回声不符: %v", chatA)
	}
	chatB := b.expectType("chat", 3*time.Second)
	if chatB["id"] != id {
		t.Fatalf("广播 id 不符: %v", chatB)
	}
}

func TestE2ELateJoinerHistory(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	a := dialWS(t, port)
	defer a.closeConn()
	b := dialWS(t, port)
	defer b.closeConn()

	a.send(protocol.JoinFrame("hist", "alice"))
	_ = a.expectType("welcome", 3*time.Second)
	a.send(protocol.SayFrame("第一条历史", "h1"))
	_ = a.expectType("ack", 3*time.Second)
	_ = a.expectType("chat", 3*time.Second)

	b.send(protocol.JoinFrame("hist", "bob"))
	w := b.expectType("welcome", 3*time.Second)
	history := w["history"].([]any)
	if len(history) != 1 {
		t.Fatalf("晚加入者应携带 1 条历史: %d", len(history))
	}
	first := history[0].(map[string]any)
	if first["text"] != "第一条历史" || first["from"] != "alice" {
		t.Fatalf("历史内容不符: %v", first)
	}
	if w["last_id"] != float64(1) {
		t.Fatalf("last_id 应为 1: %v", w["last_id"])
	}
}

func TestE2ENickTakenNoRoomBadRequest(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	a := dialWS(t, port)
	defer a.closeConn()
	b := dialWS(t, port)
	defer b.closeConn()
	c := dialWS(t, port)
	defer c.closeConn()

	a.send(protocol.JoinFrame("dup", "alice"))
	_ = a.expectType("welcome", 3*time.Second)
	b.send(protocol.JoinFrame("dup", "alice"))
	err := b.expectType("error", 3*time.Second)
	if err["code"] != "nick_taken" {
		t.Fatalf("应得 nick_taken: %v", err["code"])
	}

	c.send(protocol.SayFrame("hello", "c-0"))
	err2 := c.expectType("error", 3*time.Second)
	if err2["code"] != "no_room" {
		t.Fatalf("应得 no_room: %v", err2["code"])
	}

	c.sendRaw(`{"type":"broken`)
	err3 := c.expectType("error", 3*time.Second)
	if err3["code"] != "bad_request" {
		t.Fatalf("应得 bad_request: %v", err3["code"])
	}
}

func TestE2EDisconnectBackfillLeft(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	a := dialWS(t, port)
	defer a.closeConn()
	b := dialWS(t, port)

	a.send(protocol.JoinFrame("drop", "alice"))
	_ = a.expectType("welcome", 3*time.Second)
	b.send(protocol.JoinFrame("drop", "bob"))
	_ = a.expectType("joined", 3*time.Second)

	b.hardClose() // 不握手直接断
	left := a.expectType("left", 5*time.Second)
	if left["nick"] != "bob" {
		t.Fatalf("断线兜底 left.nick 不符: %v", left["nick"])
	}
}

func TestE2ESayIdempotent(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	a := dialWS(t, port)
	defer a.closeConn()
	b := dialWS(t, port)
	defer b.closeConn()

	a.send(protocol.JoinFrame("idem", "alice"))
	_ = a.expectType("welcome", 3*time.Second)
	b.send(protocol.JoinFrame("idem", "bob"))
	_ = b.expectType("welcome", 3*time.Second)
	_ = a.expectType("joined", 3*time.Second)

	a.send(protocol.SayFrame("只算一次", "same-cid"))
	_ = a.expectType("ack", 3*time.Second)
	_ = a.expectType("chat", 3*time.Second)
	chatB := b.expectType("chat", 3*time.Second)
	if chatB["id"] != float64(1) {
		t.Fatalf("广播 id 应为 1: %v", chatB["id"])
	}

	a.send(protocol.SayFrame("只算一次", "same-cid"))
	ack2 := a.expectType("ack", 3*time.Second)
	if ack2["id"] != float64(1) {
		t.Fatalf("重放 ack.id 应为 1: %v", ack2["id"])
	}
	b.assertSilence(400 * time.Millisecond) // 幂等：无第二条广播
}

func TestE2EPingPong(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	c := dialWS(t, port)
	defer c.closeConn()
	c.send(map[string]string{"type": "ping"})
	msg := c.nextAny(3 * time.Second)
	if msg["type"] != "pong" {
		t.Fatalf("应得 pong: %v", msg)
	}
}

func TestE2EActiveLeave(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	a := dialWS(t, port)
	defer a.closeConn()
	b := dialWS(t, port)
	defer b.closeConn()

	a.send(protocol.JoinFrame("quit", "alice"))
	_ = a.expectType("welcome", 3*time.Second)
	b.send(protocol.JoinFrame("quit", "bob"))
	_ = b.expectType("welcome", 3*time.Second)
	_ = a.expectType("joined", 3*time.Second)

	b.send(map[string]string{"type": "leave"})
	b.assertSilence(300 * time.Millisecond) // 主动 leave 无回包
	left := a.expectType("left", 3*time.Second)
	if left["nick"] != "bob" {
		t.Fatalf("left.nick 不符: %v", left["nick"])
	}
	members := left["members"].([]any)
	if len(members) != 1 || members[0] != "alice" {
		t.Fatalf("left.members 不符: %v", members)
	}

	b.send(protocol.SayFrame("还在吗", "after-leave"))
	err := b.expectType("error", 3*time.Second)
	if err["code"] != "no_room" {
		t.Fatalf("leave 后 say 应 no_room: %v", err["code"])
	}
}

func TestE2EAckBeforeOwnEcho(t *testing.T) {
	port, stop := newTestGateway(t)
	defer stop()
	c := dialWS(t, port)
	defer c.closeConn()

	c.send(protocol.JoinFrame("order", "solo"))
	_ = c.expectType("welcome", 3*time.Second)
	c.send(protocol.SayFrame("时序", "ord-1"))
	first := c.nextAny(3 * time.Second)
	second := c.nextAny(3 * time.Second)
	if first["type"] != "ack" || second["type"] != "chat" {
		t.Fatalf("顺序应为 ack→chat: %v, %v", first["type"], second["type"])
	}
	if first["id"] != second["id"] {
		t.Fatalf("ack.id 与 chat.id 应一致: %v vs %v", first["id"], second["id"])
	}
}
