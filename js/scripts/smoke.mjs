/** Smoke：对运行中的 TroupeChat(troupejs) 服务端做 join/say/ack/chat/ping 实连验证 */
const url = process.argv[2] ?? "ws://127.0.0.1:7890/";

const ws = new WebSocket(url);
const log = [];
let step = 0;

function expectNext(label, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`等待 ${label} 超时`)), timeoutMs);
    const onMsg = (ev) => {
      const msg = JSON.parse(String(ev.data));
      log.push(msg);
      clearTimeout(timer);
      ws.removeEventListener("message", onMsg);
      resolve(msg);
    };
    ws.addEventListener("message", onMsg);
  });
}

const fail = (e) => {
  console.error("SMOKE FAILED:", e.message);
  console.error("收到消息序列:", JSON.stringify(log, null, 2));
  process.exit(1);
};

ws.addEventListener("error", () => fail(new Error("连接失败")));

ws.addEventListener("open", async () => {
  try {
    ws.send(JSON.stringify({ type: "join", room: "lobby", nick: "smoker" }));
    const w = await expectNext("welcome");
    if (w.type !== "welcome" || w.you !== "smoker" || w.room !== "lobby") throw new Error("welcome 字段不符: " + JSON.stringify(w));
    if (!Array.isArray(w.members) || w.members[0] !== "smoker") throw new Error("welcome.members 不符");
    if (w.last_id !== 0 || !Array.isArray(w.history)) throw new Error("welcome.last_id/history 不符");

    ws.send(JSON.stringify({ type: "say", text: "你好，troupejs", cid: "smoke-1" }));
    const a = await expectNext("ack");
    if (a.type !== "ack" || a.cid !== "smoke-1" || a.id !== 1) throw new Error("ack 字段不符: " + JSON.stringify(a));
    const c = await expectNext("chat");
    if (c.type !== "chat" || c.id !== 1 || c.from !== "smoker" || c.text !== "你好，troupejs" || c.room !== "lobby" || typeof c.ts !== "number")
      throw new Error("chat 字段不符: " + JSON.stringify(c));

    ws.send(JSON.stringify({ type: "ping" }));
    const p = await expectNext("pong");
    if (p.type !== "pong") throw new Error("pong 不符");

    // 幂等重放：同 cid 重发，应只有重复 ack，无第二条 chat
    ws.send(JSON.stringify({ type: "say", text: "你好，troupejs", cid: "smoke-1" }));
    const a2 = await expectNext("ack");
    if (a2.id !== 1) throw new Error("幂等重放 id 不符: " + JSON.stringify(a2));

    ws.close();
    console.log("SMOKE OK：join→welcome / say→ack / chat 回声 / ping→pong / 同 cid 幂等重放 全部通过");
    console.log("消息序列:", log.map((m) => m.type).join(" → "));
    process.exit(0);
  } catch (e) {
    fail(e);
  }
});
