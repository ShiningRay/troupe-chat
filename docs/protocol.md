# TroupeChat WebSocket 协议 v1

传输：WebSocket 文本帧，单帧一条 UTF-8 JSON object。路径：`/`。
共享编解码实现：[`protocol/`](../protocol)（服务端与客户端 path 依赖同一 shard）。

## 客户端 → 服务端

| type | 字段 | 说明 |
|---|---|---|
| `join` | `room: String`, `nick: String` | 加入房间；重名收到 `error/nick_taken` |
| `say` | `text: String`, `cid: String` | 发言。`cid` 为客户端生成的幂等键（重发不重复入库/广播）；成功收到 `ack` |
| `leave` | — | 主动离开房间（断线时服务端兜底补发） |
| `ping` | — | 心跳，回 `pong` |

示例：

```json
{"type":"join","room":"lobby","nick":"alice"}
{"type":"say","text":"你好","cid":"9f2c…"}
```

## 服务端 → 客户端

| type | 字段 | 说明 |
|---|---|---|
| `welcome` | `room`, `you`, `members[]`, `last_id`, `history[]` | join 成功后的房间快照（历史 ≤ 200 条） |
| `chat` | `room`, `id`, `from`, `text`, `ts` | 房间广播（有序，含本人发言回声；客户端按 `id` 去重） |
| `ack` | `cid`, `id` | say 已提交，`id` 为服务端消息号 |
| `joined` | `room`, `nick`, `members[]` | 成员加入广播（不回发本人） |
| `left` | `room`, `nick`, `members[]` | 成员离开广播（不回发本人） |
| `error` | `code`, `message` | `nick_taken` / `no_room` / `bad_request` / `id_conflict` / `say_failed` / `join_failed` / `leave_failed` / `internal` / `connect_failed` |
| `pong` | — | 心跳应答 |
| `disconnected` | `reason` | 仅客户端本地生成：连接断开通知 |

## 有序性与幂等（troupe.cr 承担的部分）

- **广播有序**：房间事件由 `RoomActor` 的 Turn 内 `emit_event` 写入 troupe Outbox，
  与 Props（成员/最近消息）同原子提交；`OutboxDispatcher` 轮询投递 → 每房间广播
  顺序与 Turn 提交顺序严格一致。
- **至少一次 + 去重**：投递失败下轮重投；网关按 `event_id` 去重，客户端按消息 `id` 去重，
  双层兜底。
- **发言幂等**：`say.cid` 作为 troupe 幂等键（同键同参数指纹重放首次结果）——
  网络重发不会产生重复消息或重复广播；同键不同指纹拒绝（`id_conflict`）。
- **持久化**：SQLite WAL；进程重启后房间成员与历史从 Props 恢复（welcome 携带）。
- **慢消费者隔离**：每连接出站 mailbox 有界（256），投递限时 200ms，超时剔除该连接，
  不阻塞其他订阅者。

## 时序

```
client A          gateway           RoomActor(lobby)        Outbox        client B
  │ join ──────────▶│ ──join turn────▶ │                      │              │
  │                 │◀─welcome─────────│                      │              │
  │◀── welcome ─────│                  │                      │              │
  │                 │   （A 先挂房间集合，后收 welcome：welcome 之后的事件不丢）
  │ say(cid) ──────▶│ ──post turn─────▶ │ id=1, append+save+emit_event(chat)
  │                 │◀─ msg json ──────│                      │              │
  │◀── ack(cid,1) ──│                  │ ── poll ────────────▶│──chat(1)───▶│
  │◀── chat(1) ─────│◀──────────────────────────────────────────┘             │
```
