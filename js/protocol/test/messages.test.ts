import { describe, expect, it } from "vitest";
import {
  ChatParseError,
  ack,
  chatMsg,
  error,
  joinFrame,
  joined,
  left,
  parseClient,
  pong,
  sayFrame,
  welcome,
  type ChatMessage,
} from "../src/messages.js";

describe("parseClient", () => {
  it("解析 join/say/leave/ping", () => {
    expect(parseClient({ type: "join", room: "lobby", nick: "alice" })).toEqual({ kind: "join", room: "lobby", nick: "alice" });
    expect(parseClient({ type: "say", text: "你好", cid: "c-1" })).toEqual({ kind: "say", text: "你好", cid: "c-1" });
    expect(parseClient({ type: "leave" })).toBe("leave");
    expect(parseClient({ type: "ping" })).toBe("ping");
  });

  it("say 的 cid 可缺省为空串", () => {
    expect(parseClient({ type: "say", text: "x" })).toEqual({ kind: "say", text: "x", cid: "" });
    expect(parseClient({ type: "say", text: "x", cid: 42 })).toEqual({ kind: "say", text: "x", cid: "" });
  });

  it("缺 type / 缺字段 / 空串字段 / 未知类型均抛 ChatParseError", () => {
    expect(() => parseClient({})).toThrow(ChatParseError);
    expect(() => parseClient({ type: "join", nick: "alice" })).toThrow(/room/);
    expect(() => parseClient({ type: "join", room: "", nick: "alice" })).toThrow(/room/);
    expect(() => parseClient({ type: "say" })).toThrow(/text/);
    expect(() => parseClient({ type: "say", text: "" })).toThrow(/text/);
    expect(() => parseClient({ type: "dance" })).toThrow(/未知消息类型/);
    expect(() => parseClient([1, 2])).toThrow(ChatParseError);
    expect(() => parseClient("hello")).toThrow(ChatParseError);
  });
});

describe("下行构造器", () => {
  it("welcome 携带 room/you/members/last_id/history", () => {
    const history: ChatMessage[] = [{ id: 1, from: "alice", text: "hi", ts: 1700000000000 }];
    const w = welcome("lobby", "bob", ["alice", "bob"], history, 1);
    expect(w).toEqual({
      type: "welcome",
      room: "lobby",
      you: "bob",
      members: ["alice", "bob"],
      last_id: 1,
      history,
    });
    // JSON 往返保持字段名（snake_case）
    const round = JSON.parse(JSON.stringify(w)) as typeof w;
    expect(round.last_id).toBe(1);
    expect(round.history[0]!.text).toBe("hi");
  });

  it("chat/ack/joined/left/error/pong 形状", () => {
    expect(chatMsg("lobby", 7, "alice", "hi", 123)).toEqual({ type: "chat", room: "lobby", id: 7, from: "alice", text: "hi", ts: 123 });
    expect(ack("c-1", 7)).toEqual({ type: "ack", cid: "c-1", id: 7 });
    expect(joined("lobby", "bob", ["alice", "bob"])).toEqual({ type: "joined", room: "lobby", nick: "bob", members: ["alice", "bob"] });
    expect(left("lobby", "alice", [])).toEqual({ type: "left", room: "lobby", nick: "alice", members: [] });
    expect(error("nick_taken", "x")).toEqual({ type: "error", code: "nick_taken", message: "x" });
    expect(pong()).toEqual({ type: "pong" });
  });
});

describe("上行构造器", () => {
  it("joinFrame/sayFrame 输出可被 parseClient 往返解析", () => {
    const j = parseClient(JSON.parse(joinFrame("lobby", "alice")));
    expect(j).toEqual({ kind: "join", room: "lobby", nick: "alice" });
    const s = parseClient(JSON.parse(sayFrame("你好", "c-9")));
    expect(s).toEqual({ kind: "say", text: "你好", cid: "c-9" });
  });
});
