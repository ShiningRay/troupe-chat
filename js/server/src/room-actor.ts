/**
 * 房间 Virtual Actor：每个房间一个 RoomActor（role=Room, stageName=房间名）。
 *
 * 与 Crystal 版 troupe-chat/server/src/chat/room_actor.cr 逐条对齐：
 * - 房间成员与最近消息是 Actor 的 Props，随 `saveProps()`/幂等提交原子落盘（SQLite WAL）；
 * - 广播事件不直发 WebSocket，而是 `publishShow()` 发布到房间话题（ troupejs Show，
 *   网关经 troupe.subscribe 订阅；turn 串行 ⇒ 广播顺序与 Turn 提交顺序严格一致）；
 * - 发言以客户端 cid 作幂等键：网络重发不会产生重复消息/重复广播；
 * - 网关断线兜底补 leave（conn 为空串时按昵称剔除）。
 */
import { Actor, type Agent } from "troupe";
import {
  chatMsg,
  joined,
  left,
  welcome,
  type ChatMessage,
  type ChatMsg,
  type PresenceMsg,
  type WelcomeMsg,
} from "../../protocol/src/messages.js";

export const MAX_HISTORY = 200;

/** 昵称被占用：业务异常，Turn 内抛出后原样送达调用方。 */
export class NickTakenError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "NickTakenError";
  }
}

export interface Member {
  nick: string;
  conn: string;
}

export interface RoomProps {
  nextId: number;
  members: Member[];
  messages: ChatMessage[];
}

export class RoomActor extends Actor<RoomProps> {
  static role = "Room";
  static initialProps = (): RoomProps => ({ nextId: 1, members: [], messages: [] });

  /** 房间 Show 话题（与 troupejs examples/chat 的 `chat:<room>` 同构） */
  private get topic(): string {
    return `chat:${this.stageName}`;
  }

  /** 加入房间：重名拒绝；成功后发布 joined 广播，返回 welcome 快照。 */
  async join(nick: string, conn: string): Promise<WelcomeMsg> {
    if (this.member(nick)) throw new NickTakenError(`昵称已被占用：${nick}`);
    this.props.members.push({ nick, conn });
    await this.saveProps();
    await this.publishShow(this.topic, joined(this.stageName, nick, this.nickList()));
    return welcome(this.stageName, nick, this.nickList(), this.props.messages, this.lastId());
  }

  /**
   * 发言：cid 作幂等键。首次执行：分配消息 id → 追加（截断到 MAX_HISTORY）→
   * 幂等 helper 与 Props 一次原子提交（fn 内只改内存，不 saveProps）→
   * 提交成功后才发布 chat 广播；重放：直接返回首次结果，不重复落库也不重复广播。
   */
  async post(from: string, text: string, cid: string): Promise<ChatMsg> {
    let firstRun = false;
    const msg = await this.idempotent(cid, `post|${from}|${text}`, async () => {
      firstRun = true;
      return this.appendMessage(from, text);
    });
    if (firstRun) {
      await this.publishShow(this.topic, chatMsg(this.stageName, msg.id, msg.from, msg.text, msg.ts));
    }
    return chatMsg(this.stageName, msg.id, msg.from, msg.text, msg.ts);
  }

  /**
   * 离开：conn 为空串时按昵称剔除（网关断线兜底路径）。
   * 重复 leave（本就不是成员）幂等：无变化则不广播不落盘。
   */
  async leave(nick: string, conn: string): Promise<PresenceMsg> {
    const before = this.props.members.length;
    this.props.members = this.props.members.filter(
      (m) => !(m.nick === nick && (conn === "" || m.conn === conn)),
    );
    if (this.props.members.length < before) {
      await this.saveProps();
      await this.publishShow(this.topic, left(this.stageName, nick, this.nickList()));
    }
    return left(this.stageName, nick, this.nickList());
  }

  async snapshot(): Promise<WelcomeMsg> {
    return welcome(this.stageName, "", this.nickList(), this.props.messages, this.lastId());
  }

  private member(nick: string): boolean {
    return this.props.members.some((m) => m.nick === nick);
  }

  private nickList(): string[] {
    return this.props.members.map((m) => m.nick);
  }

  private lastId(): number {
    const last = this.props.messages[this.props.messages.length - 1];
    return last ? last.id : this.props.nextId - 1;
  }

  private appendMessage(from: string, text: string): ChatMessage {
    const msg: ChatMessage = { id: this.props.nextId, from, text, ts: Date.now() };
    this.props.nextId += 1;
    this.props.messages.push(msg);
    if (this.props.messages.length > MAX_HISTORY) {
      this.props.messages.splice(0, this.props.messages.length - MAX_HISTORY);
    }
    return msg;
  }
}

/** 房间 Actor 的 typed 句柄（gateway 用） */
export type RoomAgent = Agent<RoomActor>;
