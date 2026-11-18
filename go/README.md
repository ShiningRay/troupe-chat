# TroupeChat 服务端（Go / troupe-go）

TroupeChat 服务端 monorepo 的 **Go 实现**：运行时 [`troupe-go`](https://github.com/ShiningRay/troupe-go)
（M0–M6 全交付，golden 跨语言向量对齐），网关用
[`troupe-gateway-go`](https://github.com/ShiningRay/troupe-gateway-go)（ADR-0007 L3
传输桥：会话生命周期/有界 mailbox + 限时投递/溢出策略/Outbox **逐 actor 轮询**
派发（与 Crystal 语义一致）/event_id 去重）。WebSocket 线上协议与
[crystal/](../crystal)（首个参照实现）完全一致，
[tessell-chat](https://github.com/ShiningRay/tessell-chat) 客户端无需修改即可连接。

协议见 [docs/protocol.md](../docs/protocol.md)。

## 结构

```
go/
├── protocol/            # 消息编解码（纯 Go 零依赖；protocol.cr 的逐条移植）
└── server/
    ├── chat/            # RoomActor + 应用层网关路由 + SQLite Outbox 适配器
    └── cmd/chat_server/ # 入口（CLI 与 crystal 版 server.cr 参数同构）
```

## 运行

环境：Go >= 1.23。

```sh
# WebSocket 服务端（默认 7777，SQLite 持久化到 chat.db）
go run ./server/cmd/chat_server -p 7777 -d chat.db
# 内存库（测试/临时演示）
go run ./server/cmd/chat_server -p 7777 -d :memory:

# 客户端（另开终端）
cd ../../tessell-chat && crystal run src/client.cr -- --server ws://127.0.0.1:7777 --nick alice
```

参数与 crystal 版一致：`-H/--host`（默认 127.0.0.1）、`-p/--port`（默认 7777）、
`-d/--db`（默认 chat.db，`:memory:` 走内存 OutboxStore）、`-h/--help`。

## 测试

```sh
gofmt -l . && go vet ./...   # 无输出
go test -race ./...          # 协议 6 + RoomActor 8 + SQLite Outbox 2 + 网关 e2e 9
```

覆盖要点（对照 crystal 版两份 spec）：join/重名拒绝、发言幂等重放（同 cid 不重复
广播/入库；同 cid 不同参数 `id_conflict`）、历史截断（≤200）、断线兜底 leave、
SQLite 重启恢复（成员/历史/消息号续接）、Outbox 原子提交与 CAS 回滚、
ping/pong、主动 leave 无回包、晚加入者历史/last_id、坏 JSON → bad_request、
ack 先于本人回声。

## 架构要点（troupe-go / troupe-gateway-go 的用武之地）

| 诉求 | crystal 版（troupe.cr + troupe-gateway） | Go 版（troupe-go + troupe-gateway-go） |
|---|---|---|
| 房间 = 有状态实体 | Virtual Actor `ActorId("chat","room",房间名)` | `troupe.MustActorID("chat","room",房间名)`，按需激活 |
| 消息顺序 | strict Turn 串行；Outbox 与提交同序 | 同一 Turn 串行语义；`EmitEvent` 记入 journal、随下次提交原子落盘 |
| 不丢不重 | `idempotent(cid, fingerprint)` helper + Outbox 至少一次 | `a.Idempotent(cid, "post\|from\|text")` helper（Props+journal+outbox 同事务）+ 逐 actor 轮询至少一次 + 网关去重 + 客户端 id 去重 |
| 重启恢复 | SQLite WAL Props | SQLite（WAL）Props，重启即回放 |
| 网关粘合层 | troupe-gateway + `gateway.cr` | `troupe-gateway-go` + `gateway.go`（同一分层：传输管理下沉伴生库，应用层只写路由语义） |
| 慢消费者 | 有界 mailbox + 溢出策略 | 同（gateway-go `MailboxCap`/`PushWait`/`Overflow`，默认值与 Crystal 一致） |

## 实现说明（与 crystal 版的差异）

- **SQLite Outbox 为 chat 层适配器**：troupe-go 运行时侧 SQLite Provider 暂无
  Outbox 实现（仅 Memory/PostgreSQL）。`server/chat/sqlite_outbox.go` 补齐
  `WriteWithOutbox`（Props CAS + journal + outbox **同一事务**，CAS 失败整体回滚）+
  `PollOutbox`/`MarkSent` 两表模式（语义对齐 troupepg 与 crystal OutboxDispatcher）。
- **迟到事件过滤**：网关按「会话加入时刻 vs 事件 CreatedAt」过滤滞留广播——
  晚加入者从 welcome 拿历史/成员表，不补发加入前的 joined/left/chat（比 crystal 版
  轮询窗口的固有竞态语义更确定，与 js 版 append 时刻快照目标等价）。
- **presence 自回声抑制**：join 先写 session 元数据再走 turn（同 crystal），
  Outbox 派发线程投递 joined 时能立刻读到 nick。
- **`-m` metrics 端点未提供**（crystal 版 Director `/health /metrics`、ruby 版有极简
  `/health /metrics`）；Go 版暂缺，后续可补。

## License

MIT，见根目录 [LICENSE](../LICENSE)。
