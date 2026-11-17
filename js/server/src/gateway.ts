/**
 * Chat 网关：WebSocket 会话 ⇄ RoomActor typed Agent 调用的应用协议路由。
 *
 * 与 Crystal 版 troupe-chat/server/src/chat/gateway.cr 逐条对齐：
 * - 上行路由：join/say/leave/ping → RoomActor 调用（troupe.cast 代理）；
 * - 房间成员表（conn 集合）与 presence 自回声抑制；
 * - 断线兜底补 leave；慢消费者有界出站邮箱（256）溢出剔除；
 * - 房间事件经 troupe Show 话题订阅（`chat:<room>`）接出。
 *
 * 时序要点：先把连接挂进房间集合、订阅话题，再调用 join turn，保证 turn 提交后
 * 产生的第一波事件不会因注册晚于投递而丢失；Show 回调经 setImmediate 投递，
 * 模拟 Crystal Outbox 轮询的「提交后再送」——ack 先于本人 chat 回声，且每房间 FIFO 保序。
 */
import { randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { IdempotencyConflictError, type Troupe } from "troupe";
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
import { attachWebSocket, type WsConnection } from "./ws.js";

/** 每连接出站邮箱上限（对齐 troupe-gateway 有界 mailbox；溢出剔除该连接） */
const MAX_MAILBOX = 256;

interface Session {
  id: string;
  ws: WsConnection;
  meta: { nick?: string; room?: string };
  /** 出站在途帧数（write 回调记账） */
  pending: number;
}

export class ChatGateway {
  private readonly sessions = new Map<string, Session>();
  private readonly roomConns = new Map<string, Set<string>>();
  private readonly subscribedRooms = new Set<string>();
  private server: Server | null = null;

  constructor(private readonly troupe: Troupe) {}

  /** 监听并返回实际端口（port=0 时随机分配，测试用） */
  async listen(host: string, port: number): Promise<number> {
    const server = createServer((req, res) => {
      // 非 WebSocket 请求兜底（对应 Crystal 侧 FallbackHandler）
      res.writeHead(426, { "content-type": "text/plain; charset=utf-8" });
      res.end("TroupeChat WebSocket server：请用 WebSocket 连接（协议见 troupe-chat/docs/protocol.md）\n");
    });
    attachWebSocket(server, { onConnection: (ws) => this.onConnection(ws) });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, host, () => resolve());
    });
    this.server = server;
    return (server.address() as AddressInfo).port;
  }

  async stop(): Promise<void> {
    for (const s of this.sessions.values()) s.ws.destroy();
    this.sessions.clear();
    const server = this.server;
    this.server = null;
    if (!server) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  // ---- 连接生命周期 ----

  private onConnection(ws: WsConnection): void {
    const session: Session = { id: randomUUID(), ws, meta: {}, pending: 0 };
    this.sessions.set(session.id, session);
    ws.bind(
      (raw) => void this.handleRaw(session, raw),
      () => this.cleanup(session),
    );
  }

  /** 断线清理：actor 侧补 leave（真实 conn），房间集合移除。 */
  private cleanup(session: Session): void {
    this.sessions.delete(session.id);
    const room = session.meta.room;
    const nick = session.meta.nick;
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
        this.deliver(session, pong());
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
        this.deliver(session, error("bad_request", errorMessage(e) || "bad request"));
        return;
      }
      this.deliver(session, error("internal", errorMessage(e) || "internal error"));
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
      await this.ensureSubscribed(room);
      const agent = this.troupe.cast(RoomActor, room);
      const welcomeMsg = await agent.join(nick, session.id);
      session.meta.nick = nick;
      session.meta.room = room;
      this.deliver(session, welcomeMsg);
    } catch (e) {
      conns.delete(session.id);
      if (isName(e, NickTakenError)) {
        this.deliver(session, error("nick_taken", errorMessage(e) || "nick taken"));
      } else {
        this.deliver(session, error("join_failed", errorMessage(e) || "join failed"));
      }
    }
  }

  private async handleSay(session: Session, text: string, cid: string): Promise<void> {
    const room = session.meta.room;
    if (!room) {
      this.deliver(session, error("no_room", "尚未加入房间"));
      return;
    }
    const agent = this.troupe.cast(RoomActor, room);
    try {
      const msg = await agent.post(session.meta.nick ?? "", text, cid);
      this.deliver(session, ack(cid, msg.id));
    } catch (e) {
      if (isName(e, IdempotencyConflictError)) {
        this.deliver(session, error("id_conflict", errorMessage(e) || "cid 冲突"));
      } else {
        this.deliver(session, error("say_failed", errorMessage(e) || "say failed"));
      }
    }
  }

  private async handleLeave(session: Session): Promise<void> {
    const room = session.meta.room;
    const nick = session.meta.nick ?? "";
    if (!room) {
      // 对齐 Crystal：未加入房间的 leave 回发空房间 left 帧
      this.deliver(session, left("", nick, []));
      return;
    }
    const agent = this.troupe.cast(RoomActor, room);
    try {
      await agent.leave(nick, session.id);
      this.roomConns.get(room)?.delete(session.id);
      session.meta.room = "";
    } catch (e) {
      this.deliver(session, error("leave_failed", errorMessage(e) || "leave failed"));
    }
  }

  // ---- 出站投递（有界邮箱 + 慢消费者剔除） ----

  /** 投递一帧；邮箱溢出/连接已死时剔除连接并返回 false。 */
  private deliver(session: Session, msg: WireMsg): boolean {
    if (session.ws.closed) return false;
    if (session.pending >= MAX_MAILBOX) {
      session.ws.destroy(); // 触发 close → cleanup → 断线兜底 leave
      return false;
    }
    session.pending++;
    try {
      session.ws.sendText(JSON.stringify(msg), () => {
        session.pending--;
      });
    } catch {
      session.ws.destroy();
      return false;
    }
    return true;
  }

  // ---- 房间事件路由（troupe Show 订阅） ----

  private async ensureSubscribed(room: string): Promise<void> {
    if (this.subscribedRooms.has(room)) return;
    this.subscribedRooms.add(room); // 同步登记防并发重复订阅；Set 去重本就幂等
    await this.troupe.subscribe(`chat:${room}`, (event) => {
      // 模拟 Outbox 轮询异步性：提交后投递，FIFO 保序
      setImmediate(() => this.routeEvent(room, event as WireMsg));
    });
  }

  private routeEvent(room: string, event: WireMsg): void {
    const kind = event.type;
    const presenceNick = kind === "joined" || kind === "left" ? event.nick : null;
    const conns = [...(this.roomConns.get(room) ?? [])];
    for (const conn of conns) {
      const session = this.sessions.get(conn);
      if (!session || session.ws.closed) {
        // 死会话惰性清理
        this.roomConns.get(room)?.delete(conn);
        continue;
      }
      // presence 自回声抑制：自己的 joined/left 不回发（welcome/退出已覆盖）。
      if (presenceNick && session.meta.nick === presenceNick) continue;
      if (!this.deliver(session, event)) {
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
