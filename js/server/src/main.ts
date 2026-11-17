/**
 * TroupeChat 服务端入口（TypeScript/troupejs）。
 *
 * 用法（与 Crystal 版 server.cr 参数一致）：
 *   npx tsx server/src/main.ts -- -p 7777 -d chat.db
 *   npx tsx server/src/main.ts -- -p 7777 -d :memory:
 *
 * - SQLite 持久化（WAL，SqlitePropStore）：房间成员/最近消息随 Turn 原子提交，重启即恢复；
 * - -d :memory: 走内存 PropStore（测试/临时演示）；
 * - --metrics-port 开启 troupejs Booth 内省面板（对照 Crystal 版的 Director /health /metrics）。
 */
import { dirname, basename } from "node:path";
import { InMemoryPropStore, SqlitePropStore, Troupe } from "troupe";
import { ChatGateway } from "./gateway.js";
import { RoomActor } from "./room-actor.js";

interface Options {
  host: string;
  port: number;
  db: string;
  metricsPort: number;
}

function parseArgs(argv: string[]): Options {
  const opts: Options = { host: "127.0.0.1", port: 7777, db: "chat.db", metricsPort: 0 };
  const args = [...argv];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    const next = () => args[++i];
    switch (arg) {
      case "-H":
      case "--host":
        opts.host = next() ?? opts.host;
        break;
      case "-p":
      case "--port":
        opts.port = Number(next() ?? opts.port);
        break;
      case "-d":
      case "--db":
        opts.db = next() ?? opts.db;
        break;
      case "-m":
      case "--metrics-port":
        opts.metricsPort = Number(next() ?? opts.metricsPort);
        break;
      case "-h":
      case "--help":
        console.log(
          [
            "TroupeChat server（troupejs 版）",
            "  -H, --host=HOST        监听地址（默认 127.0.0.1）",
            "  -p, --port=PORT        WebSocket 端口（默认 7777）",
            "  -d, --db=PATH          SQLite 路径或 :memory:（默认 chat.db）",
            "  -m, --metrics-port=PORT  Booth 内省面板端口（0 关闭，默认 0）",
            "  -h, --help             帮助",
          ].join("\n"),
        );
        process.exit(0);
      default:
        if (arg.startsWith("--host=")) opts.host = arg.slice("--host=".length);
        else if (arg.startsWith("--port=")) opts.port = Number(arg.slice("--port=".length));
        else if (arg.startsWith("--db=")) opts.db = arg.slice("--db=".length);
        else if (arg.startsWith("--metrics-port=")) opts.metricsPort = Number(arg.slice("--metrics-port=".length));
        else {
          console.error(`未知参数：${arg}`);
          process.exit(2);
        }
    }
  }
  return opts;
}

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));

  const troupe = await Troupe.form({
    actors: [RoomActor],
    // SQLite PropStore：-d 指定文件路径（对照 Crystal SQLitePropStore.open(db)）；:memory: 走内存
    propStore:
      opts.db === ":memory:" ? new InMemoryPropStore() : new SqlitePropStore(dirname(opts.db) || ".", basename(opts.db)),
    defaultIntermission: "10m", // 空闲房间下场：Props 落盘归还，下次消息重新登台
    ...(opts.metricsPort > 0 ? { booth: { port: opts.metricsPort } } : {}),
  });

  const gateway = new ChatGateway(troupe);
  const actual = await gateway.listen(opts.host, opts.port);
  console.log(`TroupeChat server: ws://${opts.host}:${actual}/  db=${opts.db}`);

  if (opts.metricsPort > 0) {
    console.log(`metrics(Booth): ${troupe.boothAddress()}`);
  }

  const shutdown = async (): Promise<void> => {
    console.log("\n优雅停机：排空 → offStage + saveProps…");
    await gateway.stop();
    await troupe.shutdown();
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

// vitest 导入本模块做单测时不启动服务
if (process.env.VITEST === undefined) {
  void main();
}
