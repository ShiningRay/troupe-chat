/**
 * Show → Outbox 源桥（chat 应用层）：RoomActor 经 `publishShow` 发布的事件，
 * 在 Show 本地回调（turn 提交时刻同步执行）append 进 Outbox，由 troupe-gateway
 * 的派发循环 claim → onOutbox 路由。
 *
 * 关键语义：**append 时刻快照投递目标**（当时刻房间成员集合随记录一并保存）——
 * 晚加入者不会收到加入前的 joined/left 迟到广播（成员表由 welcome 提供），
 * 消除「轮询窗口内 join」的竞态；claim 租约（失败不 markDone → 到期重投）保持
 * 至少一次，event_id 去重由 troupe-gateway 执行。
 */
import type { OutboxRecord, OutboxSource } from "troupe-gateway";
import type { Troupe } from "troupe";

interface PendingEntry {
  rec: OutboxRecord;
  /** append 时刻的投递目标（conn id 集合快照） */
  targets: string[];
  leaseUntil: number | null;
}

export class ShowOutboxSource implements OutboxSource {
  private seq = 0;
  private pending: PendingEntry[] = [];
  private readonly subscribed = new Set<string>();

  constructor(
    private readonly troupe: Troupe,
    /** 房间 → 当时刻投递目标快照（ChatGateway 的房间成员表） */
    private readonly snapshotTargets: (room: string) => string[],
  ) {}

  /** 懒订阅房间话题（幂等）；Show 回调即 append。 */
  subscribeRoom(room: string, topic: string): void {
    if (this.subscribed.has(room)) return;
    this.subscribed.add(room); // 同步登记防并发重复订阅；troupe 侧 Set 去重本就幂等
    void this.troupe.subscribe(topic, (event) => {
      this.seq += 1;
      this.pending.push({
        rec: {
          id: `show-${this.seq}`,
          eventId: `show-${this.seq}`,
          topic,
          payload: event,
          actorKey: room,
          createdAt: Date.now(),
        },
        targets: this.snapshotTargets(room),
        leaseUntil: null,
      });
    });
  }

  async claimBatch(_workerId: string, limit: number, leaseMs: number): Promise<OutboxRecord[]> {
    const now = Date.now();
    const claimed: OutboxRecord[] = [];
    for (const entry of this.pending) {
      if (claimed.length >= limit) break;
      if (entry.leaseUntil !== null && entry.leaseUntil > now) continue;
      entry.leaseUntil = now + leaseMs;
      claimed.push(entry.rec);
    }
    return [...claimed];
  }

  async markDone(rec: OutboxRecord): Promise<void> {
    const idx = this.pending.findIndex((e) => e.rec.id === rec.id);
    if (idx >= 0) this.pending.splice(idx, 1);
  }

  /** 按记录取 append 时刻保存的投递目标（onOutbox 路由用）。 */
  targetsOf(rec: OutboxRecord): string[] {
    return this.pending.find((e) => e.rec.id === rec.id)?.targets ?? [];
  }
}
