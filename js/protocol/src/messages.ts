/**
 * TroupeChat 共享协议（WebSocket 协议 v1，与 Crystal 版 protocol/ 逐条对齐）。
 *
 * 客户端 ⇄ 服务端的全部消息都是 JSON 文本帧，详见 troupe-chat/docs/protocol.md。
 * 本模块零运行时依赖；服务端与客户端共用，保证两端编解码一致。
 */

/** 一条聊天消息（历史/广播/welcome 复用同一形状）。 */
export interface ChatMessage {
  id: number;
  from: string;
  text: string;
  /** UTC 毫秒时间戳 */
  ts: number;
}

// ---- 客户端 → 服务端 ----

export interface JoinMsg {
  kind: "join";
  room: string;
  nick: string;
}

export interface SayMsg {
  kind: "say";
  text: string;
  /** 客户端生成的幂等键（可为空串） */
  cid: string;
}

export type ClientMsg = JoinMsg | SayMsg | "leave" | "ping";

export class ChatParseError extends Error {}

function requireString(json: Record<string, unknown>, key: string): string {
  const value = json[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new ChatParseError(`缺少字段 ${key}`);
  }
  return value;
}

/**
 * 解析客户端上行消息。join/say 返回对应对象，leave/ping 返回 Symbol 字符串。
 * 非法结构抛 ChatParseError。
 */
export function parseClient(json: unknown): ClientMsg {
  if (typeof json !== "object" || json === null || Array.isArray(json)) {
    throw new ChatParseError("缺少 type 字段");
  }
  const obj = json as Record<string, unknown>;
  const type = obj["type"];
  if (typeof type !== "string" || type.length === 0) {
    throw new ChatParseError("缺少 type 字段");
  }
  switch (type) {
    case "join":
      return { kind: "join", room: requireString(obj, "room"), nick: requireString(obj, "nick") };
    case "say":
      return { kind: "say", text: requireString(obj, "text"), cid: typeof obj["cid"] === "string" ? obj["cid"] : "" };
    case "leave":
      return "leave";
    case "ping":
      return "ping";
    default:
      throw new ChatParseError(`未知消息类型：${type}`);
  }
}

export function joinFrame(room: string, nick: string): string {
  return JSON.stringify({ type: "join", room, nick });
}

export function sayFrame(text: string, cid: string): string {
  return JSON.stringify({ type: "say", text, cid });
}

// ---- 服务端 → 客户端 ----

export interface WelcomeMsg extends Record<string, unknown> {
  type: "welcome";
  room: string;
  you: string;
  members: string[];
  last_id: number;
  history: ChatMessage[];
}

export interface ChatMsg extends Record<string, unknown> {
  type: "chat";
  room: string;
  id: number;
  from: string;
  text: string;
  ts: number;
}

export interface AckMsg extends Record<string, unknown> {
  type: "ack";
  cid: string;
  id: number;
}

export interface PresenceMsg extends Record<string, unknown> {
  type: "joined" | "left";
  room: string;
  nick: string;
  members: string[];
}

export interface ErrorMsg extends Record<string, unknown> {
  type: "error";
  code: string;
  message: string;
}

export type WireMsg =
  | WelcomeMsg
  | ChatMsg
  | AckMsg
  | PresenceMsg
  | ErrorMsg
  | { type: "pong" }
  | { type: "disconnected"; reason: string };

export function welcome(room: string, you: string, members: string[], history: ChatMessage[], lastId: number): WelcomeMsg {
  return { type: "welcome", room, you, members, last_id: lastId, history };
}

export function chatMsg(room: string, id: number, from: string, text: string, ts: number): ChatMsg {
  return { type: "chat", room, id, from, text, ts };
}

export function ack(cid: string, id: number): AckMsg {
  return { type: "ack", cid, id };
}

export function joined(room: string, nick: string, members: string[]): PresenceMsg {
  return { type: "joined", room, nick, members };
}

export function left(room: string, nick: string, members: string[]): PresenceMsg {
  return { type: "left", room, nick, members };
}

export function error(code: string, message: string): ErrorMsg {
  return { type: "error", code, message };
}

export function pong(): { type: "pong" } {
  return { type: "pong" };
}
