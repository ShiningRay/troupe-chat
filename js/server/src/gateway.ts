/**
 * Chat 网关：troupe-gateway（ADR-0007 L3 传输桥）之上的**应用协议路由**。
 *
 * 传输管理（会话生命周期、有界 mailbox + 限时入队、溢出策略、Outbox 派发循环、
 * event_id 去重）全部由 troupe-gateway 承担（与 crystal 版 troupe-gateway shard 分层
 * 一致）；本层只剩 chat 业务语义：
 * - 上行路由：join/say/leave/ping → RoomActor typed Agent 调用；
 * - 房间成员表（conn 集合）与 presence 自回声抑制；
 * - 断线兜底补 leave；慢消费者/死会话惰性清理（deliver 失败即移出房间集合）；
 * - Show 事件 → Outbox 源（ShowOutboxSource 桥：append 时刻快照投递目标）→ 网关派发循环。
 *
 * 时序要点：先把连接挂进房间集合、订阅话题，再调用 join turn，保证 turn 提交后
 * 产生的第一波事件不会因注册晚于投递而丢失；事件经 Outbox 派发循环（默认 50ms
 * claim，InMemory 源 FIFO + 单 worker 顺序回调）投递——ack 先于本人 chat 回声、
 * 每房间保序，与 crystal 版 Outbox 轮询同构。
 */
import { IdempotencyConflictError, type Troupe } from "troupe";
import { WebSocketGateway, type OutboxRecord, type Session } from "troupe-gateway";
import {
  ChatParseError,
  ack,
  error,
  left,
  parseClient,
  pong,
  type WireMsg,
} from "../../protocol/src/messages.js";
import { NickTakenError, RoomActor } from "./room-actor.js";
import { ShowOutboxSource } from "./show-outbox.js";

const ROOM_TOPIC_PREFIX = "chat:";

export class ChatGateway {
  private readonly roomConns = new Map<string, Set<string>>();
  private readonly outbox: ShowOutboxSource;
  private readonly ws: WebSocketGateway;

  constructor(private readonly troupe: Troupe) {
    this.outbox = new ShowOutboxSource(troupe, (room) => [...(this.roomConns.get(room) ?? [])]);
    this.ws = new WebSocketGateway(this.outbox);
    this.ws.onMessage = (session, raw) => void this.handleRaw(session, raw);
    this.ws.onDisconnect = (session) => this.cleanup(session);
    this.ws.onOutbox = (record) => void this.routeEvent(record);
  }

  /** 监听并返回实际端口（port=0 时随机分配，测试用） */
  async listen(host: string, port: number): Promise<number> {
    this.ws.track("chat"); // 启动 Outbox 派发循环（claim 型源：tracked 非空即轮询）
    return this.ws.listen(host, port);
  }

  async stop(): Promise<void> {
    this.ws.stop();
  }

  // ---- 连接生命周期 ----

  /** 断线清理：actor 侧补 leave（真实 conn），房间集合移除。 */
  private cleanup(session: Session): void {
    const room = session.meta.get("room");
    const nick = session.meta.get("nick");
    if (!room || !nick) return;
    this.roomConns.get(room)?.delete(session.id);
    const agent = this.troupe.cast(RoomActor, room);
    agent.leave(nick, session.id).catch((e: unknown) => {
      console.error(`[gateway] 断线 leave 失败 room=${room} nick=${nick}: ${errorMessage(e)}`);
    });
  }

  // ---- 上行路由（chat 业务语义） ----

  private async handleRaw(session: Session, raw: string): Promise<void> {
    try {
      const parsed = parseClient(JSON.parse(raw));
      if (parsed === "ping") {
        await this.deliver(session, pong());
        return;
      }
      if (parsed === "leave") {
        return await this.handleLeave(session);
      }
      switch (parsed.kind) {
        case "join":
          return await this.handleJoin(session, parsed.room, parsed.nick);
        case "say":
          return await this.handleSay(session, parsed.text, parsed.cid);
      }
    } catch (e) {
      // 坏 JSON / 协议结构非法 → bad_request（对齐 Crystal ParseError | JSON::ParseException）
      if (e instanceof ChatParseError || e instanceof SyntaxError) {
        await this.deliver(session, error("bad_request", errorMessage(e) || "bad request"));
        return;
      }
      await this.deliver(session, error("internal", errorMessage(e) || "internal error"));
    }
  }

  private async handleJoin(session: Session, room: string, nick: string): Promise<void> {
    // 先挂房间集合、订阅话题，再走 turn：事件不会在注册前投递丢失。
    let conns = this.roomConns.get(room);
    if (!conns) {
      conns = new Set();
      this.roomConns.set(room, conns);
    }
    conns.add(session.id);
    try {
      this.ensureSubscribed(room);
      const agent = this.troupe.cast(RoomActor, room);
      const welcomeMsg = await agent.join(nick, session.id);
      session.meta.set("nick", nick);
      session.meta.set("room", room);
      await this.deliver(session, welcomeMsg);
    } catch (e) {
      conns.delete(session.id);
      if (isName(e, NickTakenError)) {
        await this.deliver(session, error("nick_taken", errorMessage(e) || "nick taken"));
      } else {
        await this.deliver(session, error("join_failed", errorMessage(e) || "join failed"));
      }
    }
  }

  private async handleSay(session: Session, text: string, cid: string): Promise<void> {
    const room = session.meta.get("room");
    if (!room) {
      await this.deliver(session, error("no_room", "尚未加入房间"));
      return;
    }
    const agent = this.troupe.cast(RoomActor, room);
    try {
      const msg = await agent.post(session.meta.get("nick") ?? "", text, cid);
      await this.deliver(session, ack(cid, msg.id));
    } catch (e) {
      if (isName(e, IdempotencyConflictError)) {
        await this.deliver(session, error("id_conflict", errorMessage(e) || "cid 冲突"));
      } else {
        await this.deliver(session, error("say_failed", errorMessage(e) || "say failed"));
      }
    }
  }

  private async handleLeave(session: Session): Promise<void> {
    const room = session.meta.get("room");
    const nick = session.meta.get("nick") ?? "";
    if (!room) {
      // 对齐 Crystal：未加入房间的 leave 回发空房间 left 帧
      await this.deliver(session, left("", nick, []));
      return;
    }
    const agent = this.troupe.cast(RoomActor, room);
    try {
      await agent.leave(nick, session.id);
      this.roomConns.get(room)?.delete(session.id);
      session.meta.set("room", "");
    } catch (e) {
      await this.deliver(session, error("leave_failed", errorMessage(e) || "leave failed"));
    }
  }

  // ---- 出站投递（有界 mailbox/限时入队/溢出策略由 troupe-gateway 执行） ----

  private async deliver(session: Session, msg: WireMsg): Promise<boolean> {
    return this.ws.deliver(session, msg);
  }

  // ---- 房间事件路由（Show → Outbox 源 → 网关派发循环） ----

  /** 懒订阅房间话题：Show 回调（turn 提交时刻）append 进 Outbox 源，派发循环 claim 后路由。 */
  private ensureSubscribed(room: string): void {
    this.outbox.subscribeRoom(room, ROOM_TOPIC_PREFIX + room);
  }

  /** 网关派发循环回调：按 append 时刻的目标快照分发（event_id 去重已在 gateway 内完成）。 */
  private async routeEvent(record: OutboxRecord): Promise<void> {
    const room = record.topic.startsWith(ROOM_TOPIC_PREFIX)
      ? record.topic.slice(ROOM_TOPIC_PREFIX.length)
      : record.topic;
    const event = record.payload as WireMsg;
    const kind = event?.type;
    const presenceNick = kind === "joined" || kind === "left" ? event.nick : null;
    for (const conn of this.outbox.targetsOf(record)) {
      const session = this.ws.session(conn);
      if (!session || session.closedMailbox) {
        // 死会话惰性清理
        this.roomConns.get(room)?.delete(conn);
        continue;
      }
      // presence 自回声抑制：自己的 joined/left 不回发（welcome/退出已覆盖）。
      if (presenceNick && session.meta.get("nick") === presenceNick) continue;
      // 慢消费者/死会话惰性清理：deliver 失败（溢出/已关）即移出房间集合。
      if (!(await this.deliver(session, event))) {
        this.roomConns.get(room)?.delete(conn);
      }
    }
  }
}

// ---- 内部工具 ----

function isName(e: unknown, ctor: abstract new (...args: never[]) => Error): boolean {
  return e instanceof ctor || (e instanceof Error && e.name === ctor.name);
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
