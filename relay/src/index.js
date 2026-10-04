// Mewo on Fire relay as a Cloudflare Worker (PROTOCOL.md v1.4).
//
// A PC behind its provider's NAT cannot be reached from the internet, so the
// daemon and the phone both connect out to this relay, and it passes bytes
// between them. What passes is the phone's ordinary connection to the daemon
// (TLS with the PC's pinned certificate, then the token): the relay only
// sees ciphertext.
//
//   daemon: wss://<relay>/pc/<pc_id>/listen?key=<key>
//   phone:  wss://<relay>/pc/<pc_id>/connect
//
// One Durable Object per PC holds its sockets. To the daemon, a phone is a
// number: `{"open": N}` / `{"close": N}` as text, and its bytes as binary
// messages with the number in the first four bytes (big endian). To a phone,
// everything is plain bytes.
//
// `mewo relay-server` is the same relay for a machine of your own.

import { DurableObject } from "cloudflare:workers";

const PATH = /^\/pc\/([0-9a-fA-F]{8,64})\/(listen|connect)$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = PATH.exec(url.pathname);
    if (!match) {
      return new Response("Mewo on Fire relay\n", { status: url.pathname === "/" ? 200 : 404 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("WebSocket expected\n", { status: 426 });
    }
    const pc = env.RELAY.get(env.RELAY.idFromName(match[1].toLowerCase()));
    return pc.fetch(request);
  },
};

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export class Relay extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url);
    const [client, server] = Object.values(new WebSocketPair());

    if (url.pathname.endsWith("/listen")) {
      // The first daemon to listen for an id sets its key; nobody else can
      // take the id afterwards.
      const key = url.searchParams.get("key") || "";
      if (key.length < 16) return new Response("key expected\n", { status: 400 });
      const hash = await sha256(key);
      const known = await this.ctx.storage.get("key");
      if (known && known !== hash) return new Response("wrong key\n", { status: 403 });
      if (!known) await this.ctx.storage.put("key", hash);
      // A daemon that reconnects replaces itself; its phones start again.
      for (const old of this.ctx.getWebSockets("daemon")) old.close(4000, "replaced");
      for (const phone of this.ctx.getWebSockets("phone")) phone.close(4001, "PC restarted");
      this.ctx.acceptWebSocket(server, ["daemon"]);
    } else {
      const daemon = this.ctx.getWebSockets("daemon")[0];
      if (!daemon) return new Response("PC offline\n", { status: 503 });
      const n = crypto.getRandomValues(new Uint32Array(1))[0];
      this.ctx.acceptWebSocket(server, ["phone", `n:${n}`]);
      server.serializeAttachment({ n });
      daemon.send(JSON.stringify({ open: n }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    if (this.ctx.getTags(ws).includes("daemon")) {
      if (typeof message === "string") {
        let control;
        try {
          control = JSON.parse(message);
        } catch {
          return;
        }
        if (Number.isInteger(control.close)) {
          for (const phone of this.ctx.getWebSockets(`n:${control.close}`)) phone.close(1000, "closed");
        }
        return;
      }
      if (message.byteLength < 4) return;
      const n = new DataView(message).getUint32(0);
      for (const phone of this.ctx.getWebSockets(`n:${n}`)) phone.send(message.slice(4));
      return;
    }
    // From a phone: its bytes, numbered, to the daemon.
    if (typeof message === "string") return;
    const daemon = this.ctx.getWebSockets("daemon")[0];
    if (!daemon) {
      ws.close(4001, "PC offline");
      return;
    }
    const framed = new Uint8Array(4 + message.byteLength);
    new DataView(framed.buffer).setUint32(0, ws.deserializeAttachment().n);
    framed.set(new Uint8Array(message), 4);
    daemon.send(framed);
  }

  webSocketClose(ws, code, reason) {
    if (this.ctx.getTags(ws).includes("daemon")) {
      // Unless another daemon connection took over, its phones are cut off.
      if (this.ctx.getWebSockets("daemon").every((d) => d === ws)) {
        for (const phone of this.ctx.getWebSockets("phone")) phone.close(4001, "PC offline");
      }
    } else {
      const daemon = this.ctx.getWebSockets("daemon")[0];
      if (daemon) daemon.send(JSON.stringify({ close: ws.deserializeAttachment().n }));
    }
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      // already closed
    }
  }

  webSocketError(ws) {
    this.webSocketClose(ws, 1011, "error");
  }
}
