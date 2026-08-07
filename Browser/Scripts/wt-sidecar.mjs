#!/usr/bin/env node
// lyte-wt-sidecar — same-box WebTransport ↔ UDP opaque datagram relay.
//
// Browser Chrome speaks WebTransport datagrams; this process relays opaque
// bytes onto a UDP peer and back. It never parses Lyte envelopes or Noise —
// ciphertext-only by construction. Does not bind standing host UDP 41151.
//
// Modes:
//   • echo (default, B-2): loopback UDP echo for carrier proofs
//   • --udp-peer host:port (B-3): forward to a real Lyte host / control peer
//
// Writes JSON metadata (url, cert hash, measured ports) to --meta-out so the
// proof page can dial with serverCertificateHashes.

import { createHash } from "node:crypto";
import { createSocket } from "node:dgram";
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
    console.error("wt-sidecar: installing Harness deps (rwebtransport)…");
    const r = spawnSync(
      "npm",
      ["install", "--silent", "--no-fund", "--no-audit"],
      { cwd: harnessRoot, stdio: "inherit" }
    );
    if (r.status !== 0) {
      console.error("wt-sidecar: npm install in Browser/Harness failed");
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

function parseArgs(argv) {
  const out = {
    host: "127.0.0.1",
    wtPort: 0,
    metaOut: null,
    path: "/lyte-datagram",
    udpPeer: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--host") out.host = argv[++i];
    else if (a === "--wt-port") out.wtPort = Number(argv[++i]);
    else if (a === "--meta-out") out.metaOut = argv[++i];
    else if (a === "--path") out.path = argv[++i];
    else if (a === "--udp-peer") out.udpPeer = parsePeer(argv[++i]);
    else if (a === "--help" || a === "-h") {
      console.log(
        "usage: wt-sidecar.mjs [--host 127.0.0.1] [--wt-port 0] [--meta-out path] " +
          "[--path /lyte-datagram] [--udp-peer host:port]"
      );
      process.exit(0);
    }
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

async function relaySession(session, relay, destination) {
  await session.ready;
  const writer = session.datagrams.writable.getWriter();
  const reader = session.datagrams.readable.getReader();

  const onUdp = (msg, rinfo) => {
    // One WT session ↔ one UDP peer port. Opaque bytes only.
    if (rinfo.port !== destination.port) return;
    writer.write(new Uint8Array(msg)).catch(() => {});
  };
  relay.on("message", onUdp);

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
    // session closed / reset — fine for a proof sidecar
  } finally {
    relay.off("message", onUdp);
    try {
      writer.releaseLock();
    } catch {
      /* ignore */
    }
  }
}

const args = parseArgs(process.argv.slice(2));
const certDir = mkdtempSync(join(tmpdir(), "lyte-wt-sidecar-"));
const { keyPath, certPath } = mintCert(certDir);
const hash = certSha256(certPath);

let echoSock = null;
let echoPort = null;
let peer = args.udpPeer;

if (!peer) {
  echoSock = await listenUdp(args.host);
  echoPort = echoSock.address().port;
  echoSock.on("message", (msg, rinfo) => {
    echoSock.send(msg, rinfo.port, rinfo.address);
  });
  peer = { host: args.host, port: echoPort };
}

const relaySock = await listenUdp(args.host);
const relayPort = relaySock.address().port;

const server = new WebTransportServer({
  host: args.host,
  port: args.wtPort,
  cert: certPath,
  key: keyPath,
});
await server.ready;
const wtPort = server.port;

const shape = args.udpPeer
  ? "webtransport-datagram-to-udp-peer"
  : "webtransport-datagram-to-udp-echo";

const meta = {
  adapter: "lyte-wt-sidecar",
  shape,
  url: `https://${args.host}:${wtPort}${args.path}`,
  host: args.host,
  wtPort,
  relayUdpPort: relayPort,
  echoUdpPort: echoPort,
  udpPeerHost: peer.host,
  udpPeerPort: peer.port,
  path: args.path,
  hashHex: Buffer.from(hash).toString("hex"),
  hashAlgorithm: "sha-256",
  lyteBudgetBytes: 1152,
  note:
    "Opaque bytes only. Pairing/Noise stay end-to-end in WASM↔host; this sidecar never unseals.",
};

if (args.metaOut) {
  mkdirSync(dirname(args.metaOut), { recursive: true });
  writeFileSync(args.metaOut, JSON.stringify(meta, null, 2) + "\n");
}

console.log(JSON.stringify(meta));

void (async () => {
  const reader = server.incomingSessions.getReader();
  for (;;) {
    const { value: session, done } = await reader.read();
    if (done) break;
    if (session) {
      relaySession(session, relaySock, peer);
    }
  }
})();

function shutdown() {
  try {
    server.close();
  } catch {
    /* ignore */
  }
  try {
    echoSock?.close();
  } catch {
    /* ignore */
  }
  try {
    relaySock.close();
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

// Keep the event loop alive.
setInterval(() => {}, 1 << 30);
