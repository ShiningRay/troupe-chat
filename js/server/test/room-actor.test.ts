import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { IdempotencyConflictError, InMemoryPropStore, SqlitePropStore, Troupe, type Troupe as TroupeInstance } from "troupe";
import { MAX_HISTORY, NickTakenError, RoomActor } from "../src/room-actor.js";
import { type WireMsg } from "../../protocol/src/messages.js";

/** 驱动方式与 Crystal room_actor_spec 同构：真实 Stage + typed Agent 全管线 */
async function makeTroupe(propStore?: SqlitePropStore): Promise<TroupeInstance> {
  return Troupe.form({
    actors: [RoomActor],
    propStore: propStore ?? new InMemoryPropStore(),
    defaultIntermission: "10m", // 测试期间不主动下场
  });
}

describe("RoomActor 语义", () => {
  it("join 返回 welcome 快照", async () => {
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "lobby");
    const w = await room.join("alice", "conn-a");
    expect(w.type).toBe("welcome");
    expect(w.you).toBe("alice");
    expect(w.members).toEqual(["alice"]);
    expect(w.history).toEqual([]);
    expect(w.last_id).toBe(0);
    await troupe.shutdown();
  });

  it("重名 join 被拒绝且不污染成员表", async () => {
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "lobby");
    await room.join("alice", "conn-a");
    await expect(room.join("alice", "conn-a2")).rejects.toThrow(NickTakenError);
    const snap = await room.snapshot();
    expect(snap.members).toEqual(["alice"]);
    await troupe.shutdown();
  });

  it("post 分配递增 id", async () => {
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "lobby");
    const m1 = await room.post("alice", "第一条", "cid-1");
    const m2 = await room.post("alice", "第二条", "cid-2");
    expect(m1.id).toBe(1);
    expect(m2.id).toBe(2);
    const snap = await room.snapshot();
    expect(snap.history).toHaveLength(2);
    expect(snap.history[0]!.text).toBe("第一条");
    await troupe.shutdown();
  });

  it("post 幂等重放：同 cid 不重复入史，同 cid 不同参数拒绝", async () => {
    // Crystal spec 共享同一 Stage（此前用例已 post 过 cid-1/cid-2）；此处等价重排：先发两条再重放
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "lobby");
    await room.post("alice", "第一条", "cid-1");
    const m2 = await room.post("alice", "第二条", "cid-2");
    expect(m2.id).toBe(2);
    const again = await room.post("alice", "第二条", "cid-2");
    expect(again.id).toBe(2);
    await expect(room.post("alice", "被篡改的内容", "cid-2")).rejects.toThrow(IdempotencyConflictError);
    const snap = await room.snapshot();
    expect(snap.history).toHaveLength(2);
    await troupe.shutdown();
  });

  it("leave 移除成员；重复 leave 幂等", async () => {
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "lobby");
    await room.join("alice", "conn-a");
    const first = await room.leave("alice", "conn-a");
    expect(first.members).toHaveLength(0);
    const again = await room.leave("alice", "conn-a");
    expect(again.type).toBe("left");
    expect(again.members).toHaveLength(0);
    await troupe.shutdown();
  });

  it("空 conn 的 leave 按昵称兜底剔除", async () => {
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "lobby");
    await room.join("bob", "conn-b");
    await room.join("carol", "conn-c");
    const leftMsg = await room.leave("bob", "");
    expect(leftMsg.members).toEqual(["carol"]);
    await troupe.shutdown();
  });

  it("历史截断到 MAX_HISTORY", async () => {
    const troupe = await makeTroupe();
    const room = troupe.cast(RoomActor, "hot");
    for (let i = 1; i <= MAX_HISTORY + 10; i++) {
      await room.post("spammer", `m${i}`, `hot-${i}`);
    }
    const snap = await room.snapshot();
    expect(snap.history).toHaveLength(MAX_HISTORY);
    expect(snap.history[MAX_HISTORY - 1]!.text).toBe(`m${MAX_HISTORY + 10}`);
    expect(snap.history[0]!.text).toBe("m11");
    await troupe.shutdown();
  });

  it("SQLite 持久化：重开 Troupe 后成员与历史恢复", async () => {
    const dir = mkdtempSync(join(tmpdir(), "troupe-chat-js-server-"));
    try {
      const store = new SqlitePropStore(dir);
      const troupe1 = await Troupe.form({ actors: [RoomActor], propStore: store });
      const room1 = troupe1.cast(RoomActor, "persist");
      await room1.join("dave", "conn-d");
      await room1.post("dave", "跨重启仍在", "cid-p");
      await troupe1.shutdown(); // 释放所有权租约

      const troupe2 = await Troupe.form({ actors: [RoomActor], propStore: new SqlitePropStore(dir) });
      const room2 = troupe2.cast(RoomActor, "persist");
      const w = await room2.join("erin", "conn-e");
      expect(w.you).toBe("erin");
      expect(w.members).toEqual(["dave", "erin"]);
      expect(w.history[w.history.length - 1]!.text).toBe("跨重启仍在");
      await troupe2.shutdown();
    } finally {
      // troupejs 未暴露 store.close：Windows 下 SQLite 文件句柄在进程退出前不释放
      // （与 Crystal spec 手动 close pool 同类问题），这里尽力清理，失败则留给系统临时目录
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {
        /* 尽力而为 */
      }
    }
  });

  it("事件序列：join→joined、post→chat、leave→left（Show 话题保序投递）", async () => {
    const troupe = await makeTroupe();
    const events: WireMsg[] = [];
    const unsubscribe = await troupe.subscribe("chat:lobby", (event) => {
      events.push(event as WireMsg);
    });
    const room = troupe.cast(RoomActor, "lobby");
    await room.join("alice", "conn-a");
    await room.post("alice", "hi", "cid-1");
    await room.leave("alice", "conn-a");

    expect(events.map((e) => e.type)).toEqual(["joined", "chat", "left"]);
    const joinedMsg = events[0]!;
    expect(joinedMsg).toMatchObject({ room: "lobby", nick: "alice", members: ["alice"] });
    expect(events[1]).toMatchObject({ room: "lobby", id: 1, from: "alice", text: "hi" });
    expect(events[2]).toMatchObject({ room: "lobby", nick: "alice", members: [] });
    await unsubscribe();
    await troupe.shutdown();
  });
});
