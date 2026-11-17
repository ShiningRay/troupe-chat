# TroupeChat.rb

TroupeChat 服务端 monorepo 的 **Ruby 实现**：用 [`trouperb`](../../trouperb)（Troupe.js
的 Ruby 版 Virtual Actor 框架）实现的聊天室服务器，**WebSocket 接口与
[crystal/](../crystal)（Crystal + troupe.cr，首个参照实现）完全一致** —— 同一协议、
同一错误码、同一语义，可直接对接 [tessell-chat](https://github.com/ShiningRay/tessell-chat)
客户端。

协议见 [`docs/protocol.md`](../docs/protocol.md)（WS 文本帧单条 JSON，路径 `/`）。

## 结构

```
ruby/
├── protocol/   # 消息编解码（纯 Ruby 零依赖；protocol.cr 的逐条移植）
├── server/     # chat_server：RoomActor + WebSocket 网关（依赖 troupe）
├── smoke_e2e.rb      # 手动冒烟：双客户端全链路
└── smoke_restart.rb  # 手动冒烟：SQLite 崩溃重启恢复
```

## 运行

环境：Ruby >= 3.2（本机 4.0 验证）。`-d` 指定 SQLite 文件路径需要 `sqlite3` gem
（已写入 Gemfile）。依赖本地 trouperb 仓库：

```sh
bundle install

# WebSocket 服务端（8077 端口风格沿用：默认 7777，SQLite 持久化到 chat.db）
bundle exec ruby server/bin/chat_server -p 7777 -d chat.db

# 内存库（测试/临时演示，无持久化）+ 健康/指标端点
bundle exec ruby server/bin/chat_server -p 7777 -d :memory: -m 7778
```

参数与 crystal 版一致：`-H/--host`（默认 127.0.0.1）、`-p/--port`（默认 7777）、
`-d/--db`（默认 chat.db，`:memory:` 走内存 Provider）、`-m/--metrics-port`
（0 关闭，提供 `/health` 与 `/metrics` JSON）、`-h/--help`。

客户端对接：[tessell-chat](https://github.com/ShiningRay/tessell-chat) 客户端默认连
`ws://127.0.0.1:7777`，无需修改。

### 手动冒烟（无 GUI）

```sh
# 终端 1
bundle exec ruby server/bin/chat_server -p 18077 -d :memory:

# 终端 2：双客户端互发全链路（welcome/nick_taken/joined/pong/say→ack→广播/断线 left）
bundle exec ruby smoke_e2e.rb 18077

# SQLite 崩溃恢复（先 seed 写入 → 硬杀进程 → 重启 verify 校验）
bundle exec ruby server/bin/chat_server -p 18079 -d smoke.db &
bundle exec ruby smoke_restart.rb 18079 seed
#   （kill 掉服务端进程后重启同 -d smoke.db）
bundle exec ruby smoke_restart.rb 18079 verify
```

## 测试

```sh
bundle exec rake test        # 协议 9 例 + RoomActor 9 例 + 网关端到端 7 例
```

> rubygems.org 不可达时（bundler 解析 trouperb 的 pstore 依赖需联网查 spec），
> 可用全局 gem（minitest/sqlite3/pstore 均已装）绕过 bundler 直接跑，trouperb 以
> path 加入加载路径：
>
> ```sh
> ruby -I"../../trouperb/lib" -e "$:.unshift('protocol/lib'); require 'minitest/autorun'; Dir.glob('{protocol,server}/test/*_test.rb').sort.each { |f| require File.expand_path(f) }"
> ```

覆盖要点（对照 crystal 版的两份 spec）：join/重名拒绝、发言幂等重放（同 cid 不
重复广播/入库）、同 cid 不同参数拒绝、历史截断 MAX_HISTORY=200、断线兜底 leave、
SQLite 重启恢复（成员/历史/消息号续接）、协议往返转义、网关端到端
（join→welcome→say→ack→双向广播→断线 left→重进）。

## 架构要点（trouperb 的用武之地）

| 诉求 | Crystal 版（troupe.cr） | Ruby 版（trouperb） |
|---|---|---|
| 房间 = 有状态实体 | Virtual Actor `ActorId("chat","room",房间名)` | `RoomActor < Troupe::Actor`，`role_id "room"`，`cast(RoomActor, 房间名)` |
| 消息顺序 | strict Turn 串行；广播经 Outbox 与提交同序 | 同一 Turn 串行语义；`emit_event` + `save_props` 同原子提交 |
| 不丢不重 | `idempotent(cid, fingerprint)` helper + Outbox 至少一次 | Props 内幂等表逐条复刻 troupe.cr helper（重放/拒绝/过期/失败记录），OutboxDispatcher 至少一次 + 网关 event_id 去重 + 客户端 id 去重 |
| 重启恢复 | SQLite WAL Props | SQLite（WAL）Props，重启即回放 |
| 网关粘合层 | troupe-gateway + `gateway.cr` | `ws_server.rb`（stdlib RFC6455，有界出站 256/慢消费者踢除）+ `gateway.rb`（同一路由语义） |
| 可观测 | Director `/health /metrics /events` | `-m` 起 `/health /metrics`（troupe.metrics + outbox 计数） |

## 实现说明（与 Crystal 版的差异）

- **SQLite Outbox 适配器**：trouperb 内置 Provider 中仅 Memory/PostgreSQL 实现了
  Outbox 合同（SQLite/PStore 的 `write(outbox:)` 显式拒绝）。本仓
  `server/lib/chat/sqlite_outbox_store.rb` 在 `Troupe::SqlitePropStore` 上补齐：
  Props CAS 与 Outbox 插入**同一事务**原子提交 + claim/lease/退避/死信
  （语义对齐 trouperb Memory/PG 实现与 troupe.cr OutboxDispatcher 合同），
  使 `-d chat.db` 同时获得持久化与有序广播。
- **幂等键**：troupe.cr 的 `idempotent()` 是框架 helper；trouperb 无此 helper，
  本仓在 RoomActor 的 Props 内实现同一语义（含 7 天保留期与首次失败记录）。
- **多节点**：单进程单节点（`transport: false`），与 Crystal 版当前状态一致；
  trouperb 的 PostgreSQL Provider/接管在框架层已具备，接入留待后续。
- **慢消费者**：出站邮箱有界 256（同 troupe-gateway 默认），满即踢除该连接；
  Ruby 4 的 `SizedQueue#push(timeout: 0)` 非阻塞入队（旧版 Ruby 回退 ThreadError 语义）。
- **presence 自回声抑制**：join 先写 session 元数据再走 Turn（Crystal 版是 Turn 后
  写）——修复交付线程在 Turn 返回前投递 joined 导致自回声漏抑制的窗口；
  其余时序与 Crystal 版相同（先挂房间集合再调 Turn）。
- `-m` 端点为极简实现（`/health` `/metrics`），未覆盖 Crystal Director 的 `/events`。

## 已知限制

- 单进程、单节点（多节点接管未接入，同 crystal 版）。
- 客户端断线后不自动重连（客户端侧行为，与 crystal 版一致）。
- 广播 at-least-once：崩溃重放时网关按 `event_id` 去重，极端情况下可能重复可见。
- WebSocket 实现为 RFC 6455 文本帧子集（握手/掩码/ping-pong/close/分片重组，
  单条消息上限 64KB）；不支持扩展协商与 permessage-deflate。

## License

MIT，见根目录 [LICENSE](../LICENSE)。
