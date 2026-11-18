# TroupeChat 服务端（troupe-js / TypeScript）

TroupeChat 服务端 monorepo 的 **Node.js/TypeScript 实现**：WebSocket 线上协议与
[crystal/](../crystal)（首个参照实现）**完全一致**（TroupeChat WebSocket 协议 v1），
[tessell-chat](https://github.com/ShiningRay/tessell-chat) 客户端无需修改即可连接。

- **运行时**：[troupe-js](https://github.com/ShiningRay/troupe-js) Virtual Actor 框架
  （`file:` path 依赖本地仓库，与 crystal 版的 shards path 依赖同构）——每个房间一个
  `RoomActor`（成员/最近消息为 Props，SQLite WAL 持久化；发言以客户端 `cid` 作幂等键）；
- **网关**：[`troupe-gateway-js`](https://github.com/ShiningRay/troupe-gateway-js) 伴生包（会话生命周期/有界 mailbox/Outbox 派发循环/event_id 去重）+ 应用协议路由；
  房间广播经 troupe-js **Show** 话题（`chat:<room>`）接出，turn 串行 ⇒ 广播顺序
  与 Turn 提交顺序严格一致（对照 crystal 版的 Outbox 同序投递）。

协议见 [docs/protocol.md](../docs/protocol.md)。

## 结构

```
js/
├── protocol/   # 消息编解码（纯 TS，零依赖；与 crystal protocol/ 逐条对齐）
├── server/     # RoomActor（troupe-js Actor）+ WebSocket 网关 + 入口
└── scripts/    # smoke.mjs（实连冒烟探针）
```

## 运行

环境：Node >= 22.13。依赖本地 troupe-js 仓库（先确保其 `dist/` 已构建）：

```sh
cd ../../troupejs && npm run build   # 首次/更新 troupe-js 后
cd ../../troupe-chat/js && npm install

# 1) 服务端（默认 7777 端口，SQLite 持久化到 chat.db）
npm run dev -- -p 7777 -d chat.db
# 或 :memory:（测试/临时演示）
npm run dev -- -p 7777 -d :memory:
# Booth 内省面板（对照 crystal 版 --metrics-port）
npm run dev -- -p 7777 -d :memory: -m 7500

# 2) 客户端（另开终端，tessell 客户端直连本服务端）
cd ../../tessell-chat && crystal run src/client.cr -- --server ws://127.0.0.1:7777 --nick alice
```

启动后填写昵称点击「连接」（默认房间 lobby），回车或点「发送」发言；多开几个客户端即可互聊。

## 测试

```sh
npm test          # vitest：协议编解码 6 例 + RoomActor 语义 9 例 + 网关端到端 9 例
npm run typecheck # tsc --noEmit
```

覆盖要点（对照 crystal 版两份 spec）：join/重名拒绝、发言幂等重放（同 cid 不重复广播，
同 cid 不同参数 `id_conflict`）、历史截断（≤200）、断线兜底 leave、SQLite 重启恢复、
ping/pong、主动 leave 无回包、晚加入者历史/last_id、坏 JSON → bad_request、
ack 先于本人回声（对齐 Outbox「提交后再送」时序）。

## 架构要点（troupe-js 的用武之地）

| 诉求 | troupe-js 机制 |
|---|---|
| 房间 = 有状态实体 | Virtual Actor：`troupe.cast(RoomActor, 房间名)`，按需激活 |
| 消息顺序 | 每房间 strict Turn 串行；广播经 Show 话题，turn 内发布 ⇒ 与提交顺序严格一致 |
| 不丢不重 | `say.cid` 幂等键（`this.idempotent` 重放首次结果；同键不同指纹拒绝）；客户端按消息 `id` 去重 |
| 重启恢复 | Props（成员/最近 200 条消息）随 `saveProps()` 原子落 SQLite（WAL），重开即回放 |
| 可观测 | troupe-js Booth 内省面板（`-m` 端口）：Actor 状态机/revision/事件流 |
| 慢消费者隔离 | 每连接出站邮箱有界（256 帧），溢出剔除该连接，不阻塞其他订阅者 |

网关（[server/src/gateway.ts](server/src/gateway.ts)）是唯一粘合层：WebSocket 会话 ⇄
typed Agent 调用；Show 事件回拨 → `setImmediate` 投递（模拟 Outbox 轮询的「提交后再送」，
保证 ack 先于本人 chat 回声、每房间 FIFO）→ 房间成员表路由（presence 自回声抑制）。

## 与 crystal 版的差异

- **接口（线上协议）一致**：消息类型、字段、错误码、有序性/幂等语义全部对齐，
  真实 tessell 客户端可直接连（见下方验证方式）。
- **广播投递为进程内 Show（尽力而为，非 durable Outbox）**：进程崩溃瞬间在途
  广播可能丢失一次；客户端重连后 `welcome` 携带全量历史兜底（协议本就要求客户端按
  `id` 去重/合并）。crystal 版经 troupe Outbox 至少一次投递 + 网关按 event_id 去重，
  崩溃重放语义更强。
- **慢消费者剔除**：有界出站邮箱（256 帧）+ 溢出断开；无 crystal 版的 200ms 单次
  投递限时。
- **`-m`**：troupe-js Booth 内省面板（对照 crystal 版 Director `/health /metrics`）。
- 已知限制同 crystal 版：单进程、单节点；客户端断线不自动重连。

### 自动化验证（无人工交互）

```sh
# 1) 本实现 e2e（Node 内置 WebSocket 客户端）
npm test
# 1b) 实连冒烟
npx tsx server/src/main.ts -p 7777 -d :memory: &
node scripts/smoke.mjs ws://127.0.0.1:7777/

# 2) 用真实 tessell 客户端做互操作（接口一致的最强证据）
npx tsx server/src/main.ts -p 7777 -d :memory: &
cd ../../tessell-chat && crystal run src/client.cr -- \
  --autotest --send "hello" --nick alice --frames=150 --server ws://127.0.0.1:7777
# stdout 出现 [autotest] acked: … 即 join/say/ack/chat 全链路通过
```

## License

MIT，见根目录 [LICENSE](../LICENSE)。
