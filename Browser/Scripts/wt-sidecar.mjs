#!/usr/bin/env node
// lyte-wt-sidecar — same-box WebTransport ↔ UDP opaque datagram relay to
// --udp-peer host:port (a Lyte host or control peer). It never parses Lyte
// envelopes or Noise, and never relays to the standing host UDP 41151. Each
// WebTransport session (at most MAX_SESSIONS at once) gets its own UDP
// socket. It listens on loopback unless --allow-remote. Datagrams are
// unreliable end to end: the relay holds none longer than a beat or two
// and drops, never retries, one its writer refuses. Writes JSON metadata
// (url, cert hash, ports) to --meta-out for serverCertificateHashes
// dialing.

import { createHash } from "node:crypto";
import { createSocket } from "node:dgram";
import { lookup } from "node:dns/promises";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const harnessRoot = fileURLToPath(new URL("../Harness", import.meta.url));

function ensureRwebtransport() {
  try {
    return require.resolve("rwebtransport", { paths: [harnessRoot] });
  } catch {
    console.error("wt-sidecar: installing Harness deps from its lockfile (rwebtransport)…");
    const r = spawnSync(
      "npm",
      ["ci", "--silent", "--no-fund", "--no-audit"],
      { cwd: harnessRoot, stdio: "inherit" }
    );
    if (r.status !== 0) {
      console.error("wt-sidecar: npm ci in Browser/Harness failed");
      process.exit(1);
    }
    return require.resolve("rwebtransport", { paths: [harnessRoot] });
  }
}

const rwebtransportEntry = ensureRwebtransport();
const { WebTransportServer } = await import(pathToFileURL(rwebtransportEntry).href);

function parsePeer(spec) {
  const idx = spec.lastIndexOf(":");
  if (idx <= 0) {
    throw new Error(`--udp-peer expects host:port, got ${spec}`);
  }
  const host = spec.slice(0, idx);
  const port = Number(spec.slice(idx + 1));
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`--udp-peer expects host:port, got ${spec}`);
  }
  if (port === 41151) {
    throw new Error(
      "wt-sidecar: refusing standing host UDP 41151 — use a fresh 41xxx test port"
    );
  }
  return { host, port };
}

function isLoopback(host) {
  return host === "localhost" || host === "::1" || /^127\./.test(host);
}

function parseArgs(argv) {
  const out = {
    host: "127.0.0.1",
    wtPort: 0,
    metaOut: null,
    path: "/lyte-datagram",
    udpPeer: null,
    allowRemote: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--host") out.host = argv[++i];
    else if (a === "--wt-port") out.wtPort = Number(argv[++i]);
    else if (a === "--meta-out") out.metaOut = argv[++i];
    else if (a === "--path") out.path = argv[++i];
    else if (a === "--udp-peer") out.udpPeer = parsePeer(argv[++i]);
    else if (a === "--allow-remote") out.allowRemote = true;
    else if (a === "--help" || a === "-h") {
      console.log(
        "usage: wt-sidecar.mjs [--host 127.0.0.1] [--allow-remote] [--wt-port 0] " +
          "[--meta-out path] [--path /lyte-datagram] --udp-peer host:port"
      );
      process.exit(0);
    }
  }
  if (!out.udpPeer) {
    throw new Error("wt-sidecar: --udp-peer host:port is required");
  }
  if (!out.allowRemote && !isLoopback(out.host)) {
    throw new Error(`wt-sidecar: refusing to listen on ${out.host} without --allow-remote`);
  }
  return out;
}

function mintCert(dir) {
  const keyPath = join(dir, "key.pem");
  const certPath = join(dir, "cert.pem");
  // Chrome WebTransport + serverCertificateHashes: ECDSA P-256, ≤14-day validity.
  const r = spawnSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-keyout",
      keyPath,
      "-out",
      certPath,
      "-days",
      "13",
      "-nodes",
      "-subj",
      "/CN=lyte-wt-sidecar",
    ],
    { encoding: "utf8" }
  );
  if (r.status !== 0) {
    console.error("wt-sidecar: openssl failed:\n" + (r.stderr || r.stdout));
    process.exit(1);
  }
  return { keyPath, certPath };
}

function certSha256(certPath) {
  const pem = readFileSync(certPath, "utf8");
  const b64 = pem
    .replace(/-----BEGIN CERTIFICATE-----/, "")
    .replace(/-----END CERTIFICATE-----/, "")
    .replace(/\s+/g, "");
  return createHash("sha256").update(Buffer.from(b64, "base64")).digest();
}

function listenUdp(host) {
  return new Promise((resolve, reject) => {
    const sock = createSocket("udp4");
    sock.once("error", reject);
    sock.bind(0, host, () => {
      sock.removeListener("error", reject);
      resolve(sock);
    });
  });
}

// Datagrams waiting for the WebTransport writer older than this are
// dropped: a relay must not become an opaque browser-side buffer.
const MAX_PENDING_AGE_MS = 50;
// A memory bound under a writer that stops draining altogether.
const MAX_PENDING_WT_WRITES = 256;
const MAX_SESSIONS = 8;

/**
 * One WebTransport session ↔ its own UDP socket, so each session has its own
 * 4-tuple toward the peer and hears only the peer's replies to it.
 */
async function relaySession(session, host, destination) {
  await session.ready;
  const relay = await listenUdp(host);
  const writer = session.datagrams.writable.getWriter();
  const reader = session.datagrams.readable.getReader();
  const pending = [];
  let open = true;
  let draining = false;
  let udpIn = 0;
  let wtOut = 0;
  let dropped = 0;
  let writeFailures = 0;

  // Writes are serialized: fire-and-forget writes lose datagrams under
  // burst. A write the carrier refuses is a lost datagram, as on UDP.
  const drainWrites = async () => {
    if (draining) return;
    draining = true;
    try {
      while (open && pending.length > 0) {
        const { bytes, queuedAt } = pending.shift();
        if (performance.now() - queuedAt > MAX_PENDING_AGE_MS) {
          dropped += 1;
          continue;
        }
        try {
          await writer.write(bytes);
          wtOut += 1;
        } catch (err) {
          writeFailures += 1;
          if (writeFailures <= 3 || writeFailures % 50 === 0) {
            console.error(
              `wt-sidecar: write fail #${writeFailures} pending=${pending.length}`,
              err?.message || err
            );
          }
        }
      }
    } finally {
      draining = false;
    }
  };

  relay.on("message", (msg, rinfo) => {
    if (rinfo.port !== destination.port || rinfo.address !== destination.address) return;
    udpIn += 1;
    if (pending.length >= MAX_PENDING_WT_WRITES) {
      pending.shift();
      dropped += 1;
    }
    pending.push({ bytes: new Uint8Array(msg), queuedAt: performance.now() });
    void drainWrites();
  });

  session.closed
    ?.catch(() => {})
    .finally(() => {
      open = false;
      pending.length = 0;
    });

  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      await new Promise((resolve, reject) => {
        relay.send(value, destination.port, destination.host, (err) =>
          err ? reject(err) : resolve()
        );
      });
    }
  } catch {
    // Session closed or reset.
  } finally {
    open = false;
    relay.close();
    try {
      writer.releaseLock();
    } catch {
      /* already released */
    }
    console.error(
      `wt-sidecar: session end udpIn=${udpIn} wtOut=${wtOut} dropped=${dropped} ` +
        `writeFailures=${writeFailures}`
    );
  }
}

const args = parseArgs(process.argv.slice(2));
const certDir = mkdtempSync(join(tmpdir(), "lyte-wt-sidecar-"));
const { keyPath, certPath } = mintCert(certDir);
const hash = certSha256(certPath);

// Replies are matched on the peer's resolved address as well as its port.
const peer = {
  ...args.udpPeer,
  address: (await lookup(args.udpPeer.host, { family: 4 })).address,
};

const server = new WebTransportServer({
  host: args.host,
  port: args.wtPort,
  cert: certPath,
  key: keyPath,
});
await server.ready;
const wtPort = server.port;

const meta = {
  adapter: "lyte-wt-sidecar",
  url: `https://${args.host}:${wtPort}${args.path}`,
  host: args.host,
  wtPort,
  udpPeerHost: peer.host,
  udpPeerPort: peer.port,
  path: args.path,
  hashHex: Buffer.from(hash).toString("hex"),
  hashAlgorithm: "sha-256",
  note:
    "Opaque bytes only. Pairing/Noise stay end-to-end in WASM↔host; this sidecar never unseals.",
};

if (args.metaOut) {
  mkdirSync(dirname(args.metaOut), { recursive: true });
  writeFileSync(args.metaOut, JSON.stringify(meta, null, 2) + "\n");
}

console.log(JSON.stringify(meta));

// Each session's UDP socket binds where the peer is reachable from.
const relayBindHost = isLoopback(peer.address) ? "127.0.0.1" : "0.0.0.0";
let activeSessions = 0;

void (async () => {
  const reader = server.incomingSessions.getReader();
  for (;;) {
    const { value: session, done } = await reader.read();
    if (done) break;
    if (!session) continue;
    if (activeSessions >= MAX_SESSIONS) {
      console.error(`wt-sidecar: refusing a session past ${MAX_SESSIONS} at once`);
      session.close?.({ closeCode: 1, reason: "busy" });
      continue;
    }
    // One failed session (a bad handshake, a reset) must never take the
    // relay down for everyone else.
    activeSessions += 1;
    relaySession(session, relayBindHost, peer)
      .catch((error) => console.error("wt-sidecar: session failed:", error?.message || error))
      .finally(() => {
        activeSessions -= 1;
      });
  }
})();

function shutdown() {
  try {
    server.close();
  } catch {
    /* ignore */
  }
  try {
    rmSync(certDir, { recursive: true, force: true });
  } catch {
    /* ignore */
  }
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
// The certificate key never outlives the relay.
process.on("uncaughtException", (error) => {
  console.error("wt-sidecar:", error?.stack || error);
  shutdown();
});

// Keep the event loop alive.
setInterval(() => {}, 1 << 30);
