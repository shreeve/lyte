// B-3 control-only session pump: WebTransport datagrams ↔ WASM initiator.
// JS owns the carrier, clock, and PIN; LyteWire / LyteClientSession stay in WASM.

import { loadSidecarMeta } from "./webtransport-carrier.js";

function bytesFromHex(hex) {
  const clean = hex.replace(/\s+/g, "").toLowerCase();
  if (!clean) return new Uint8Array();
  if (clean.length % 2 !== 0) throw new Error("odd hex length");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function hexFromBytes(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function nowMicros() {
  // performance.now is ms since navigation start — fine as a monotonic µs domain
  // for one short control session (not wall clock, not shared with the host).
  return Math.floor(performance.now() * 1000);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function splitOutbound(step) {
  const raw = step?.outboundHex || "";
  if (!raw) return [];
  return raw.split("\n").filter(Boolean);
}

async function sendAll(writer, step) {
  for (const hex of splitOutbound(step)) {
    await writer.write(bytesFromHex(hex));
  }
}

/**
 * Run Noise + PIN PAKE + capabilities + teardown against a host peer
 * reached through lyte-wt-sidecar --udp-peer.
 */
export async function runControlSessionProof(opts) {
  const {
    sidecar,
    hostStaticPublicKeyHex,
    pin,
    timeoutMs = 45_000,
  } = opts;
  const bridge = globalThis.lyteBrowser;
  if (!bridge?.controlOpen) {
    throw new Error("lyteBrowser.controlOpen missing — rebuild WASM");
  }
  if (typeof WebTransport !== "function") {
    throw new Error("WebTransport API unavailable");
  }
  if (!sidecar?.url || !sidecar?.hashHex) {
    throw new Error("sidecar meta missing url/hashHex");
  }
  if (!hostStaticPublicKeyHex || !pin) {
    throw new Error("hostStaticPublicKeyHex and pin are required");
  }

  const opened = bridge.controlOpen(hostStaticPublicKeyHex, pin);
  if (!opened?.ok) {
    throw new Error(`controlOpen failed: ${opened?.error || "unknown"}`);
  }

  const hash = bytesFromHex(sidecar.hashHex);
  const wt = new WebTransport(sidecar.url, {
    serverCertificateHashes: [{ algorithm: "sha-256", value: hash }],
  });
  await wt.ready;
  const writer = wt.datagrams.writable.getWriter();
  const reader = wt.datagrams.readable.getReader();

  const lines = [];
  const pushEvents = (step) => {
    const ev = (step?.events || "").split("\n").filter(Boolean);
    for (const line of ev) {
      if (!lines.includes(line)) lines.push(line);
    }
  };

  let begin = bridge.controlBegin(nowMicros());
  pushEvents(begin);
  await sendAll(writer, begin);

  const deadline = Date.now() + timeoutMs;
  let ready = false;
  let failed = false;
  let lastStatus = begin.status;
  let pendingRead = reader.read();

  while (Date.now() < deadline && !ready && !failed) {
    const raced = await Promise.race([
      pendingRead.then((r) => ({ kind: "datagram", r })),
      sleep(20).then(() => ({ kind: "tick" })),
    ]);

    if (raced.kind === "tick") {
      const tick = bridge.controlTick(nowMicros());
      pushEvents(tick);
      await sendAll(writer, tick);
      lastStatus = tick.status;
      if (tick.failed) {
        failed = true;
        break;
      }
      if (tick.ready) {
        ready = true;
        break;
      }
      continue;
    }

    pendingRead = reader.read();
    const { value, done } = raced.r;
    if (done) break;
    if (!value) continue;
    const step = bridge.controlIngest(hexFromBytes(value), nowMicros());
    pushEvents(step);
    await sendAll(writer, step);
    lastStatus = step.status;
    if (step.failed) {
      failed = true;
      break;
    }
    if (step.ready) {
      ready = true;
      break;
    }
  }

  let teardownOk = false;
  if (ready && !failed) {
    const tear = bridge.controlTeardown(nowMicros());
    pushEvents(tear);
    await sendAll(writer, tear);
    teardownOk = !!tear.closed || tear.status === "closed";
    for (let i = 0; i < 25 && Date.now() < deadline; i++) {
      const tick = bridge.controlTick(nowMicros());
      await sendAll(writer, tick);
      const raced = await Promise.race([
        pendingRead.then((r) => ({ kind: "d", r })),
        sleep(20).then(() => ({ kind: "t" })),
      ]);
      if (raced.kind === "d") {
        pendingRead = reader.read();
        if (raced.r.value) {
          const step = bridge.controlIngest(
            hexFromBytes(raced.r.value),
            nowMicros()
          );
          pushEvents(step);
          await sendAll(writer, step);
        }
      }
    }
  }

  try {
    wt.close({ closeCode: 0, reason: "b3-done" });
  } catch {
    /* ignore */
  }

  const noiseOk = lines.some((l) => l.includes("noise: handshake completed"));
  const pairOk = lines.some((l) => l.includes("pairing: PAIRED"));
  const capsOk = lines.some((l) => l.includes("capabilities: agreed"));
  const readyOk = ready && noiseOk && pairOk && capsOk;

  const summary = [
    readyOk
      ? "PASS  control-session/noise-pair-caps — Noise IK + PIN PAKE + capabilities"
      : `FAIL  control-session/noise-pair-caps — status=${lastStatus}`,
    teardownOk
      ? "PASS  control-session/teardown — typed SessionTeardown sent"
      : "FAIL  control-session/teardown — not closed",
  ];

  const passed = readyOk && teardownOk;
  return {
    passed,
    lines: [
      ...lines.map((l) => (l.startsWith("FAIL") ? l : `INFO  ${l}`)),
      ...summary,
    ].join("\n"),
    status: lastStatus,
    clientStaticPublicKeyHex: opened.clientStaticPublicKeyHex,
    ready: readyOk,
    teardown: teardownOk,
  };
}

export async function loadControlPeerMeta(url = "./control-peer.json") {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) {
    throw new Error(`control-peer.json HTTP ${res.status}`);
  }
  return res.json();
}

export { loadSidecarMeta };
