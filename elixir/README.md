# Elixir 版 TroupeChat 服务端（占位）

> **状态：规划中，尚未实现。** 本目录预留 Elixir 实现的位置，目录约定与其余三语言
> （[crystal/](../crystal)、[ruby/](../ruby)、[js/](../js)）同构，实现落地时照此展开。

## 运行时

基于 [`troupe-elixir`](https://github.com/ShiningRay/troupe-elixir)（Troupe Virtual Actor
运行时的 Elixir 实现）。当前运行时已具备：Actor/Agent/PropStore/Ownership/HashRing/
Cues/Show 等核心模块（见其 `lib/troupe/`），聊天服务端实现待规划排期。

## 计划目录约定（与其余三语言同构）

```
elixir/
├── protocol/           # 消息编解码（纯 Elixir，零依赖）：Chat.Protocol
│   ├── lib/
│   └── test/
└── server/             # chat_server：RoomActor + WebSocket 网关（依赖 troupe-elixir）
    ├── lib/chat/
    │   ├── room_actor.ex
    │   └── gateway.ex
    └── test/
```

## 实现清单（对齐协议 v1，验收见根 README「横向对比」）

- [ ] `protocol/`：join/say/leave/ping 编解码 + welcome/chat/ack/joined/left/error/pong 构造器
- [ ] `RoomActor`：成员/最近 200 条消息为 Props；`say.cid` 幂等键；广播经 Show/Outbox 与提交同序
- [ ] WebSocket 网关：上行路由、错误分类（nick_taken/no_room/bad_request/id_conflict/…）、
      presence 自回声抑制、断线兜底 leave、慢消费者有界出站邮箱
- [ ] SQLite 或 Postgres PropStore 持久化（重启恢复）
- [ ] 测试：协议往返 + Actor 语义 + 网关端到端（对照 crystal/ruby/js 三版测试矩阵）
- [ ] 验收：tessell 客户端 `--autotest` 连通打出 `[autotest] acked`

## 参考

- 协议：[docs/protocol.md](../docs/protocol.md)
- 其余三语言实现的映射表与已知差异：各目录 README
