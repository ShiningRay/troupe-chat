# TroupeChat 服务端（多语言 monorepo）

**TroupeChat 的服务端仓库**：同一 TroupeChat WebSocket 协议 v1 的四个语言实现放在一处，
一起修改、一起验收、横向对比。客户端（tessell 自绘 GUI）在
[tessell-chat](https://github.com/ShiningRay/tessell-chat)。

协议见 [docs/protocol.md](docs/protocol.md)（唯一权威；各实现各有该协议的本语言编解码）。

## 实现

| 目录 | 语言 | 运行时 | 状态 | 测试 |
|---|---|---|---|---|
| [crystal/](crystal/) | Crystal | [troupe.cr](https://github.com/ShiningRay/troupe.cr) + troupe-gateway | ✅ 完整（首个参照实现） | 14 spec |
| [ruby/](ruby/) | Ruby | [trouperb](https://github.com/ShiningRay/trouperb) | ✅ 完整 | 25 test + 2 smoke |
| [js/](js/) | TypeScript | [troupejs](https://github.com/ShiningRay/troupejs) | ✅ 完整 | 24 vitest |
| [elixir/](elixir/) | Elixir | [troupe-elixir](https://github.com/ShiningRay/troupe-elixir) | 🚧 占位（实现待排期） | — |

各实现语义逐条对齐（见各目录 README 的「与 Crystal 版差异」节）：

- 房间 = Virtual Actor（每房间一个 `RoomActor`，按需激活）；
- 成员 / 最近 200 条消息为 Props，随 Turn 原子落 SQLite，重启即回放；
- 发言以客户端 `cid` 作幂等键：网络重发不重复入库/广播，同键不同参数拒绝（`id_conflict`）；
- 广播与 Turn 提交同序；`ack` 先于本人 `chat` 回声；presence 不回发本人；
- 断线服务端兜底补 `leave`；慢消费者有界出站邮箱剔除。

## 统一验收探针

[tessell-chat](https://github.com/ShiningRay/tessell-chat) 的 autotest 是所有实现的
标准验收探针——任一服务端能让它打出 `[autotest] acked` 即协议兼容：

```sh
# 例：验 js 实现（其余实现换对应启动命令，见各目录 README）
cd js && npx tsx server/src/main.ts -p 7777 -d :memory: &
cd ../../tessell-chat && shards install
crystal run src/client.cr -- --autotest --send "hello" --nick alice --frames=150 --server ws://127.0.0.1:7777
```

## 各实现测试

```sh
cd crystal/server && shards install && crystal spec        # 14 例（语义 + 网关端到端）
cd ruby && bundle install && rake                          # 25 例 + ruby smoke_e2e.rb
cd js && npm install && npm test                           # 24 例（协议 + 语义 + e2e）
```

## 结构

```
troupe-chat/
├── docs/protocol.md   # WebSocket 协议 v1（唯一权威）
├── crystal/           # protocol/（共享编解码 shard）+ server/（chat_server）
├── ruby/              # protocol/ + server/ + smoke 脚本
├── js/                # protocol/ + server/ + smoke 脚本
└── elixir/            # 占位：目录约定与实现清单
```

> 历史注：本仓原为 Crystal 两端仓，客户端已抽出为
> [tessell-chat](https://github.com/ShiningRay/tessell-chat)；Ruby/JS 实现自各自独立
> 目录并入，Elixir 版按 elixir/README 的清单实现后入列。

## License

MIT，见 [LICENSE](LICENSE)。
