#!/usr/bin/env node
// lyte-wt-sidecar — same-box WebTransport ↔ UDP opaque datagram relay for B-2.
//
// Browser Chrome speaks WebTransport datagrams; this process relays opaque
// bytes onto a loopback UDP peer (built-in echo) and back. It never parses
// Lyte envelopes or Noise — ciphertext-only by construction. Does not bind
// standing host UDP 41151.
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

function parseArgs(argv) {
  const out = {
    host: "127.0.0.1",
    wtPort: 0,
    metaOut: null,
    path: "/lyte-datagram",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--host") out.host = argv[++i];
    else if (a === "--wt-port") out.wtPort = Number(argv[++i]);
    else if (a === "--meta-out") out.metaOut = argv[++i];
    else if (a === "--path") out.path = argv[++i];
    else if (a === "--help" || a === "-h") {
      console.log(
        "usage: wt-sidecar.mjs [--host 127.0.0.1] [--wt-port 0] [--meta-out path] [--path /lyte-datagram]"
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

async function relaySession(session, relay, echoPort, host) {
  await session.ready;
  const writer = session.datagrams.writable.getWriter();
  const reader = session.datagrams.readable.getReader();

  const onUdp = (msg, rinfo) => {
    if (rinfo.port !== echoPort) return;
    writer.write(new Uint8Array(msg)).catch(() => {});
  };
  relay.on("message", onUdp);

  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      await new Promise((resolve, reject) => {
        relay.send(value, echoPort, host, (err) => (err ? reject(err) : resolve()));
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

const echoSock = await listenUdp(args.host);
const echoPort = echoSock.address().port;
echoSock.on("message", (msg, rinfo) => {
  echoSock.send(msg, rinfo.port, rinfo.address);
});

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

const meta = {
  adapter: "lyte-wt-sidecar",
  shape: "webtransport-datagram-to-udp-echo",
  url: `https://${args.host}:${wtPort}${args.path}`,
  host: args.host,
  wtPort,
  relayUdpPort: relayPort,
  echoUdpPort: echoPort,
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
      relaySession(session, relaySock, echoPort, args.host);
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
    echoSock.close();
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
