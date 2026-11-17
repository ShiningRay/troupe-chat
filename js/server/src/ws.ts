/**
 * 零依赖 WebSocket（RFC 6455 最小服务端实现）：
 * - 握手（Sec-WebSocket-Accept）+ 文本帧收发 + 协议层 ping/pong + close
 * - 客户端帧必须 mask（协议要求），分片（continuation）支持
 * - 不支持二进制/扩展（TroupeChat 仅 JSON 文本帧）
 *
 * 与 Crystal 侧 troupe-gateway 的 HTTP::WebSocketHandler 行为对齐：
 * 接受任意路径的升级请求（tessell 客户端连 ws://host:port/）。
 */
import { createHash } from "node:crypto";
import type { IncomingMessage, Server } from "node:http";
import type { Socket } from "node:net";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const MAX_MESSAGE = 1024 * 1024;

export class WsConnection {
  private buffer = Buffer.alloc(0);
  private fragments: Buffer[] = [];
  private fragmentOpcode = 0;
  closed = false;

  private messageHandler: ((text: string) => void) | null = null;
  private closeHandler: (() => void) | null = null;

  constructor(readonly socket: Socket, head: Buffer) {
    socket.on("data", (chunk) => this.feed(chunk));
    socket.on("close", () => this.handleClose());
    socket.on("error", () => this.handleClose());
    if (head.length > 0) this.feed(head);
  }

  /** 绑定消息/关闭处理器 */
  bind(onMessage: (text: string) => void, onClose: () => void): void {
    this.messageHandler = onMessage;
    this.closeHandler = onClose;
  }

  private handleClose(): void {
    if (this.closed) return;
    this.closed = true;
    this.closeHandler?.();
  }

  private feed(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const frame = this.parseFrame();
      if (!frame) return;
      const { opcode, payload } = frame;
      if (opcode === 0x8) {
        // close：回 close 帧并断开
        this.sendFrame(0x8, payload.subarray(0, 2));
        this.socket.end();
        this.handleClose();
        return;
      }
      if (opcode === 0x9) {
        this.sendFrame(0xa, payload); // ping → pong
        continue;
      }
      if (opcode === 0xa) continue; // pong
      if (opcode === 0x1 || opcode === 0x2) {
        if (!frame.fin) {
          this.fragmentOpcode = opcode;
          this.fragments = [payload];
          continue;
        }
        this.deliver(payload);
        continue;
      }
      if (opcode === 0x0) {
        // continuation
        this.fragments.push(payload);
        const total = this.fragments.reduce((n, f) => n + f.length, 0);
        if (total > MAX_MESSAGE) {
          this.close(1009);
          return;
        }
        if (frame.fin) {
          const full = Buffer.concat(this.fragments);
          this.fragments = [];
          if (this.fragmentOpcode === 0x1) this.deliver(full);
        }
        continue;
      }
    }
  }

  private deliver(payload: Buffer): void {
    if (payload.length > MAX_MESSAGE) {
      this.close(1009);
      return;
    }
    this.messageHandler?.(payload.toString("utf8"));
  }

  /** 解析一帧；数据不足返回 null。客户端帧必须 mask。 */
  private parseFrame(): { fin: boolean; opcode: number; payload: Buffer } | null {
    const buf = this.buffer;
    if (buf.length < 2) return null;
    const b0 = buf[0]!;
    const b1 = buf[1]!;
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let offset = 2;
    if (len === 126) {
      if (buf.length < offset + 2) return null;
      len = buf.readUInt16BE(offset);
      offset += 2;
    } else if (len === 127) {
      if (buf.length < offset + 8) return null;
      const big = buf.readBigUInt64BE(offset);
      if (big > BigInt(MAX_MESSAGE)) {
        this.close(1009);
        return null;
      }
      len = Number(big);
      offset += 8;
    }
    let mask: Buffer | null = null;
    if (masked) {
      if (buf.length < offset + 4) return null;
      mask = buf.subarray(offset, offset + 4);
      offset += 4;
    }
    if (buf.length < offset + len) return null;
    const payload = Buffer.from(buf.subarray(offset, offset + len));
    if (mask) {
      for (let i = 0; i < payload.length; i++) payload[i] = payload[i]! ^ mask[i % 4]!;
    }
    this.buffer = buf.subarray(offset + len);
    return { fin, opcode, payload };
  }

  private sendFrame(opcode: number, payload: Buffer): void {
    if (this.closed || this.socket.destroyed) return;
    const len = payload.length;
    let head: Buffer;
    if (len < 126) {
      head = Buffer.from([0x80 | opcode, len]);
    } else if (len < 65_536) {
      head = Buffer.alloc(4);
      head[0] = 0x80 | opcode;
      head[1] = 126;
      head.writeUInt16BE(len, 2);
    } else {
      head = Buffer.alloc(10);
      head[0] = 0x80 | opcode;
      head[1] = 127;
      head.writeBigUInt64BE(BigInt(len), 2);
    }
    this.socket.write(Buffer.concat([head, payload]));
  }

  /** 发送文本帧；cb 在数据写入底层套接字后回调（慢消费者出站邮箱记账用） */
  sendText(text: string, cb?: () => void): void {
    if (this.closed || this.socket.destroyed) {
      cb?.();
      return;
    }
    const len = Buffer.byteLength(text, "utf8");
    let head: Buffer;
    if (len < 126) {
      head = Buffer.from([0x81, len]);
    } else if (len < 65_536) {
      head = Buffer.alloc(4);
      head[0] = 0x81;
      head[1] = 126;
      head.writeUInt16BE(len, 2);
    } else {
      head = Buffer.alloc(10);
      head[0] = 0x81;
      head[1] = 127;
      head.writeBigUInt64BE(BigInt(len), 2);
    }
    this.socket.write(Buffer.concat([head, Buffer.from(text, "utf8")]), cb);
  }

  close(code = 1000): void {
    if (this.closed) return;
    const body = Buffer.alloc(2);
    body.writeUInt16BE(code, 0);
    this.sendFrame(0x8, body);
    this.socket.end();
    this.handleClose();
  }

  /** 慢消费者剔除：不握手直接断 */
  destroy(): void {
    this.socket.destroy();
    this.handleClose();
  }
}

export interface WsAttachOptions {
  /** 升级前鉴权；拒绝时返回 401 */
  authorize?(req: IncomingMessage): boolean;
  onConnection(conn: WsConnection, req: IncomingMessage): void;
}

/** 把 WS 升级处理挂到 HTTP server（与 Crystal HTTP::WebSocketHandler 一致：任意路径） */
export function attachWebSocket(server: Server, opts: WsAttachOptions): void {
  server.on("upgrade", (req: IncomingMessage, socket, head: Buffer) => {
    const sock = socket as Socket;
    try {
      if (req.headers.upgrade?.toLowerCase() !== "websocket") {
        sock.destroy();
        return;
      }
      if (opts.authorize && !opts.authorize(req)) {
        sock.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
        sock.destroy();
        return;
      }
      const key = req.headers["sec-websocket-key"];
      if (!key || (req.headers["sec-websocket-version"] ?? "") !== "13") {
        sock.write("HTTP/1.1 400 Bad Request\r\n\r\n");
        sock.destroy();
        return;
      }
      const accept = createHash("sha1").update(key + WS_GUID).digest("base64");
      sock.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
          "Upgrade: websocket\r\n" +
          "Connection: Upgrade\r\n" +
          `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
      );
      opts.onConnection(new WsConnection(sock, head), req);
    } catch {
      sock.destroy();
    }
  });
}
