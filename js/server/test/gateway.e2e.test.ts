/**
 * 网关端到端：真实 WebSocket 连接（Node 内置客户端），移植 troupe-chat
 * server/spec/gateway_spec.cr 全部场景 + ping/pong、主动 leave、ack 先于回声。
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { InMemoryPropStore, Troupe, type Troupe as TroupeInstance } from "troupe";
import { ChatGateway } from "../src/gateway.js";
import { RoomActor } from "../src/room-actor.js";

interface AnyMsg extends Record<string, unknown> {
  type: string;
}

/** 测试客户端：内置 WebSocket + 按到达顺序的收件队列 */
class TestClient {
  private readonly ws: WebSocket;
  private readonly queue: AnyMsg[] = [];
  private readonly waiters: Array<{ type?: string; resolve: (m: AnyMsg | undefined) => void; timer: NodeJS.Timeout }> = [];
  private readonly opened: Promise<void>;

  constructor(url: string) {
    this.ws = new WebSocket(url);
    this.opened = new Promise((resolve, reject) => {
      this.ws.addEventListener("open", () => resolve());
      this.ws.addEventListener("error", () => reject(new Error("连接失败")));
    });
    this.ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(String(ev.data)) as AnyMsg;
      const idx = this.waiters.findIndex((w) => !w.type || w.type === msg.type);
      if (idx >= 0) {
        const w = this.waiters.splice(idx, 1)[0]!;
        clearTimeout(w.timer);
        w.resolve(msg);
      } else {
        this.queue.push(msg);
      }
    });
    this.ws.addEventListener("close", () => {
      for (const w of this.waiters.splice(0)) {
        clearTimeout(w.timer);
        w.resolve(undefined);
      }
    });
  }

  sendRaw(raw: string): void {
    this.ws.send(raw);
  }

  async send(msg: object): Promise<void> {
    await this.opened;
    this.ws.send(JSON.stringify(msg));
  }

  /** 等待指定类型的下一条消息（FIFO；超时返回 undefined） */
  expect(type: string, timeoutMs = 2000): Promise<AnyMsg | undefined> {
    return this.next(timeoutMs, type);
  }

  /** 等待下一条消息（任意类型；用于断言到达顺序） */
  next(timeoutMs = 2000, type?: string): Promise<AnyMsg | undefined> {
    const idx = this.queue.findIndex((m) => !type || m.type === type);
    if (idx >= 0) return Promise.resolve(this.queue.splice(idx, 1)[0]!);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i >= 0) this.waiters.splice(i, 1);
        resolve(undefined);
      }, timeoutMs);
      const waiter = { type, resolve, timer };
      this.waiters.push(waiter);
    });
  }

  /** 短暂等待用于「不应有消息」的断言 */
  async assertSilence(timeoutMs = 300): Promise<void> {
    const msg = await this.next(timeoutMs);
    if (msg) throw new Error(`不应收到消息，却收到：${JSON.stringify(msg)}`);
  }

  async close(): Promise<void> {
    await this.opened;
    this.ws.close();
  }
}

describe("Gateway 端到端", () => {
  let troupe: TroupeInstance;
  let gateway: ChatGateway;
  let url: string;

  beforeAll(async () => {
    troupe = await Troupe.form({ actors: [RoomActor], propStore: new InMemoryPropStore() });
    gateway = new ChatGateway(troupe);
    const port = await gateway.listen("127.0.0.1", 0);
    url = `ws://127.0.0.1:${port}/`;
  });

  afterAll(async () => {
    await gateway.stop();
    await troupe.shutdown();
  });

  it("join→welcome，say→ack，双方都收到广播", async () => {
    const a = new TestClient(url);
    const b = new TestClient(url);

    await a.send({ type: "join", room: "lobby", nick: "alice" });
    const welcome = await a.expect("welcome");
    expect(welcome?.you).toBe("alice");

    await b.send({ type: "join", room: "lobby", nick: "bob" });
    await b.expect("welcome");
    const joinedMsg = await a.expect("joined");
    expect(joinedMsg?.nick).toBe("bob");
    expect(joinedMsg?.members).toEqual(["alice", "bob"]);

    await a.send({ type: "say", text: "大家好", cid: "c-1" });
    const ackMsg = await a.expect("ack");
    expect(ackMsg?.cid).toBe("c-1");
    const id = ackMsg?.id;

    const chatA = await a.expect("chat");
    expect(chatA?.id).toBe(id);
    expect(chatA?.from).toBe("alice");
    expect(chatA?.text).toBe("大家好");

    const chatB = await b.expect("chat");
    expect(chatB?.id).toBe(id);

    await a.close();
    await b.close();
  });

  it("后加入者的 welcome 携带已有历史（事件不回灌历史）", async () => {
    const a = new TestClient(url);
    const b = new TestClient(url);

    await a.send({ type: "join", room: "hist", nick: "alice" });
    await a.expect("welcome");
    await a.send({ type: "say", text: "第一条历史", cid: "h1" });
    await a.expect("ack");
    await a.expect("chat");

    await b.send({ type: "join", room: "hist", nick: "bob" });
    const welcome = await b.expect("welcome");
    const history = (welcome?.history ?? []) as Array<{ text: string; from: string }>;
    expect(history).toHaveLength(1);
    expect(history[0]!.text).toBe("第一条历史");
    expect(history[0]!.from).toBe("alice");
    expect(welcome?.last_id).toBe(1);

    await a.close();
    await b.close();
  });

  it("重名 join 得到 nick_taken 错误", async () => {
    const a = new TestClient(url);
    const b = new TestClient(url);

    await a.send({ type: "join", room: "dup", nick: "alice" });
    await a.expect("welcome");
    await b.send({ type: "join", room: "dup", nick: "alice" });
    const err = await b.expect("error");
    expect(err?.code).toBe("nick_taken");

    await a.close();
    await b.close();
  });

  it("未加入房间就 say 得到 no_room；非法 JSON 得到 bad_request", async () => {
    const c = new TestClient(url);

    await c.send({ type: "say", text: "hello", cid: "c-0" });
    const err = await c.expect("error");
    expect(err?.code).toBe("no_room");

    c.sendRaw('{"type":"broken');
    const err2 = await c.expect("error");
    expect(err2?.code).toBe("bad_request");

    await c.close();
  });

  it("断线后其他成员收到 left（actor 侧兜底剔除）", async () => {
    const a = new TestClient(url);
    const b = new TestClient(url);

    await a.send({ type: "join", room: "drop", nick: "alice" });
    await a.expect("welcome");
    await b.send({ type: "join", room: "drop", nick: "bob" });
    await a.expect("joined");

    await b.close();
    const leftMsg = await a.expect("left", 5000);
    expect(leftMsg?.nick).toBe("bob");

    await a.close();
  });

  it("say 幂等：同 cid 重发只产生一条广播", async () => {
    const a = new TestClient(url);
    const b = new TestClient(url);

    await a.send({ type: "join", room: "idem", nick: "alice" });
    await a.expect("welcome");
    await b.send({ type: "join", room: "idem", nick: "bob" });
    await b.expect("welcome");
    await a.expect("joined");

    await a.send({ type: "say", text: "只算一次", cid: "same-cid" });
    await a.expect("ack");
    await a.expect("chat");
    const chatB = await b.expect("chat");
    expect(chatB?.id).toBe(1);

    await a.send({ type: "say", text: "只算一次", cid: "same-cid" });
    const ack2 = await a.expect("ack");
    expect(ack2?.cid).toBe("same-cid");
    expect(ack2?.id).toBe(1);

    // 等待可能的第二条广播——若幂等生效则不会有新 chat
    await b.assertSilence(300);

    await a.close();
    await b.close();
  });

  it("ping 得到 pong", async () => {
    const c = new TestClient(url);
    await c.send({ type: "ping" });
    const msg = await c.next();
    expect(msg?.type).toBe("pong");
    await c.close();
  });

  it("主动 leave：本人无回包且再 say 得 no_room，他人收到 left", async () => {
    const a = new TestClient(url);
    const b = new TestClient(url);

    await a.send({ type: "join", room: "quit", nick: "alice" });
    await a.expect("welcome");
    await b.send({ type: "join", room: "quit", nick: "bob" });
    await b.expect("welcome");
    await a.expect("joined");

    await b.send({ type: "leave" });
    await b.assertSilence(300); // 主动 leave 无回包
    const leftMsg = await a.expect("left");
    expect(leftMsg?.nick).toBe("bob");
    expect(leftMsg?.members).toEqual(["alice"]);

    await b.send({ type: "say", text: "还在吗", cid: "after-leave" });
    const err = await b.expect("error");
    expect(err?.code).toBe("no_room");

    await a.close();
    await b.close();
  });

  it("ack 先于本人 chat 回声到达（对齐 Outbox「提交后再送」时序）", async () => {
    const c = new TestClient(url);

    await c.send({ type: "join", room: "order", nick: "solo" });
    await c.expect("welcome");

    await c.send({ type: "say", text: "时序", cid: "ord-1" });
    const first = await c.next();
    const second = await c.next();
    expect(first?.type).toBe("ack");
    expect(second?.type).toBe("chat");
    expect(second?.id).toBe(first?.id);

    await c.close();
  });
});
