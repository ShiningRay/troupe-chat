import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["protocol/test/**/*.test.ts", "server/test/**/*.test.ts"],
    // gateway e2e 用真实 WebSocket 连接，留足超时
    testTimeout: 15_000,
    hookTimeout: 15_000,
  },
});
