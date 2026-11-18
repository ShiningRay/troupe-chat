package chat

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/ShiningRay/troupe-chat/go/protocol"
	"github.com/ShiningRay/troupe-gateway-go"
	troupe "github.com/ShiningRay/troupe-go"
)

// Gateway Chat 网关：troupe-gateway（ADR-0007 L3 传输桥）之上的**应用协议路由**。
// 传输管理（会话生命周期、有界 mailbox + 限时投递、溢出策略、Outbox 逐 actor
// 轮询派发、event_id 去重）全部由 troupe-gateway-go 承担；本层只剩 chat 业务语义：
// - 上行路由：join/say/leave/ping → RoomActor Turn（troupe.Invoke）；
// - 房间成员表（conn 集合）与 presence 自回声抑制；
// - 断线兜底补 leave；慢消费者/死会话惰性清理（Deliver 失败即移出房间集合）。
//
// 时序要点：先把连接挂进房间集合、Track 房间 actor，再调用 join turn，保证
// turn 提交后产生的事件不会因注册晚于轮询而丢失。
type Gateway struct {
	troupe    *troupe.Stage
	gw        *gateway.WebSocketGateway
	roomConns map[string]map[string]time.Time // room → conn id → 加入时刻
	mu        sync.Mutex
}

// NewGateway 构造网关（store 需为 OutboxStore；见 SQLiteOutboxStore / MemoryOutboxStore）。
func NewGateway(stage *troupe.Stage, store troupe.OutboxStore) *Gateway {
	g := &Gateway{
		troupe:    stage,
		roomConns: map[string]map[string]time.Time{},
	}
	g.gw = gateway.NewWebSocketGateway(store, gateway.DefaultConfig())
	g.gw.OnMessage = g.handleRaw
	g.gw.OnDisconnect = g.cleanup
	g.gw.OnOutbox = g.deliverEvent
	return g
}

// Listen 监听并返回实际端口（port=0 系统分配）。
func (g *Gateway) Listen(host string, port int) (int, error) { return g.gw.Listen(host, port) }

// Stop 停止网关。
func (g *Gateway) Stop() { g.gw.Stop() }

// SessionsCount 在场连接数（应用层指标）。
func (g *Gateway) SessionsCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, set := range g.roomConns {
		n += len(set)
	}
	return n
}

// ---- 上行路由（chat 业务语义） ----

func (g *Gateway) handleRaw(session *gateway.Session, raw string) {
	msg, err := protocol.ParseClient([]byte(raw))
	if err != nil {
		var pe *protocol.ParseError
		if errors.As(err, &pe) {
			g.deliver(session, protocol.NewError("bad_request", err.Error()))
			return
		}
		g.deliver(session, protocol.NewError("bad_request", err.Error()))
		return
	}
	ctx := context.Background()
	switch msg.Kind {
	case protocol.KindJoin:
		g.handleJoin(ctx, session, msg.Join)
	case protocol.KindSay:
		g.handleSay(ctx, session, msg.Say)
	case protocol.KindLeave:
		g.handleLeave(ctx, session)
	case protocol.KindPing:
		g.deliver(session, protocol.NewPong())
	}
}

func (g *Gateway) handleJoin(ctx context.Context, session *gateway.Session, join protocol.JoinMsg) {
	// 先挂房间集合、Track 房间 actor，再走 turn：事件不会在注册前派发丢失。
	g.mu.Lock()
	set, ok := g.roomConns[join.Room]
	if !ok {
		set = map[string]time.Time{}
		g.roomConns[join.Room] = set
	}
	set[session.ID] = time.Now() // 加入时刻：晚于此的事件才投递（迟到的旧 presence/chat 不补发）
	g.mu.Unlock()
	g.gw.Track(roomActorID(join.Room))

	// 对齐 crystal 版：先写 session 元数据再走 turn——Outbox 派发线程投递 joined
	// 时能立刻读到 nick（presence 自回声抑制生效）。
	session.Meta["nick"] = join.Nick
	session.Meta["room"] = join.Room

	welcome, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.WelcomeMsg](
		ctx, g.troupe, roomActorID(join.Room), "join", struct{ Nick, Conn string }{join.Nick, session.ID})
	if err != nil {
		g.mu.Lock()
		delete(g.roomConns[join.Room], session.ID)
		g.mu.Unlock()
		session.Meta["nick"] = ""
		session.Meta["room"] = ""
		if errors.Is(err, ErrNickTaken) {
			g.deliver(session, protocol.NewError("nick_taken", err.Error()))
		} else {
			g.deliver(session, protocol.NewError("join_failed", err.Error()))
		}
		return
	}
	g.deliver(session, &welcome)
}

func (g *Gateway) handleSay(ctx context.Context, session *gateway.Session, say protocol.SayMsg) {
	room := session.Meta["room"]
	if room == "" {
		g.deliver(session, protocol.NewError("no_room", "尚未加入房间"))
		return
	}
	res, err := troupe.Invoke[struct{ From, Text, CID string }, protocol.ChatMsg](
		ctx, g.troupe, roomActorID(room), "post",
		struct{ From, Text, CID string }{session.Meta["nick"], say.Text, say.CID})
	if err != nil {
		var conflict *troupe.IdempotencyConflictError
		if errors.As(err, &conflict) {
			g.deliver(session, protocol.NewError("id_conflict", err.Error()))
		} else {
			g.deliver(session, protocol.NewError("say_failed", err.Error()))
		}
		return
	}
	g.deliver(session, protocol.NewAck(say.CID, res.ID))
}

func (g *Gateway) handleLeave(ctx context.Context, session *gateway.Session) {
	room := session.Meta["room"]
	nick := session.Meta["nick"]
	if room == "" {
		// 对齐 Crystal：未加入房间的 leave 回发空房间 left 帧
		g.deliver(session, protocol.NewLeft("", nick, nil))
		return
	}
	if _, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.PresenceMsg](
		ctx, g.troupe, roomActorID(room), "leave",
		struct{ Nick, Conn string }{nick, session.ID}); err != nil {
		g.deliver(session, protocol.NewError("leave_failed", err.Error()))
		return
	}
	g.mu.Lock()
	delete(g.roomConns[room], session.ID)
	g.mu.Unlock()
	session.Meta["room"] = ""
}

// 断线清理：actor 侧补 leave（同 conn 兜底），房间集合移除。
func (g *Gateway) cleanup(session *gateway.Session) {
	room := session.Meta["room"]
	nick := session.Meta["nick"]
	if room == "" || nick == "" {
		return
	}
	g.mu.Lock()
	delete(g.roomConns[room], session.ID)
	g.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := troupe.Invoke[struct{ Nick, Conn string }, protocol.PresenceMsg](
		ctx, g.troupe, roomActorID(room), "leave",
		struct{ Nick, Conn string }{nick, session.ID}); err != nil {
		log.Printf("[gateway] 断线 leave 失败 room=%s nick=%s: %v", room, nick, err)
	}
}

// ---- 出站投递 ----

func (g *Gateway) deliver(session *gateway.Session, payload any) bool {
	return g.gw.Deliver(session, payload)
}

// ---- Outbox 事件路由（chat 业务语义） ----

// deliverEvent 网关派发循环回调（event_id 去重已完成）：按 actor 解析房间并分发。
// 返回 error 则下轮重投（至少一次）；本层恒 nil（会话级失败不影响事件完成）。
func (g *Gateway) deliverEvent(rec troupe.OutboxRecord) error {
	id, err := troupe.ParseActorID(rec.ActorID)
	if err != nil {
		log.Printf("[gateway] outbox 记录 actor 非法 %q: %v", rec.ActorID, err)
		return nil
	}
	room := id.Key
	var event any
	if err := json.Unmarshal(rec.Payload, &event); err != nil {
		log.Printf("[gateway] outbox 载荷解析失败: %v", err)
		return nil
	}
	// wire 对象反序列化为 map；presence 字段按协议读取
	obj, _ := event.(map[string]any)
	kind, _ := obj["type"].(string)
	presenceNick := ""
	if kind == "joined" || kind == "left" {
		presenceNick, _ = obj["nick"].(string)
	}
	g.mu.Lock()
	type target struct {
		conn     string
		joinedAt time.Time
	}
	targets := make([]target, 0, len(g.roomConns[room]))
	for conn, joinedAt := range g.roomConns[room] {
		targets = append(targets, target{conn, joinedAt})
	}
	g.mu.Unlock()
	for _, tg := range targets {
		// 迟到过滤：事件早于会话加入时刻则不补发（晚加入者从 welcome 拿历史/成员表）。
		if rec.CreatedAt.Before(tg.joinedAt) {
			continue
		}
		session := g.gw.Session(tg.conn)
		if session == nil {
			// 死会话惰性清理
			g.mu.Lock()
			delete(g.roomConns[room], tg.conn)
			g.mu.Unlock()
			continue
		}
		// presence 自回声抑制：自己的 joined/left 不回发（welcome/退出已覆盖）。
		if presenceNick != "" && session.Meta["nick"] == presenceNick {
			continue
		}
		// 慢消费者/死会话惰性清理：Deliver 失败（溢出/已关）即移出房间集合。
		if !g.gw.DeliverID(tg.conn, rec.Payload) {
			g.mu.Lock()
			delete(g.roomConns[room], tg.conn)
			g.mu.Unlock()
		}
	}
	return nil
}

func roomActorID(room string) troupe.ActorID {
	return troupe.MustActorID("chat", "room", room)
}
