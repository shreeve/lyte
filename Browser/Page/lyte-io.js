// Shared browser IO helpers: hex, time, packed datagram batches, the
// WebTransport datagram reader, harness metadata and the HEVC decoder
// config probe. Policy never lives here — it lives in WASM.

export function bytesFromHex(hex) {
  const clean = hex.replace(/\s+/g, "").toLowerCase();
  if (clean.length % 2 !== 0) throw new Error("odd hex length");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** Monotonic µs since navigation start — the client clock domain. */
export function nowMicros() {
  return Math.floor(performance.now() * 1000);
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// A received datagram's age at the batch's `now` rides in its record, so
// WASM stamps each one at its arrival, not at the drain.
const MAX_AGE_MICROS = 0xffff_ffff;

/**
 * Received datagrams cross into WASM packed as `u16 big-endian length +
 * u32 big-endian age µs + bytes` records in one Uint8Array (see
 * BrowserBridge.swift); `arrivals` are their nowMicros() stamps.
 */
export function packDatagrams(datagrams, arrivals, now) {
  let total = 0;
  for (const d of datagrams) total += 6 + d.length;
  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);
  let offset = 0;
  for (let i = 0; i < datagrams.length; i++) {
    const d = datagrams[i];
    view.setUint16(offset, d.length);
    view.setUint32(offset + 2, Math.min(Math.max(now - arrivals[i], 0), MAX_AGE_MICROS));
    out.set(d, offset + 6);
    offset += 6 + d.length;
  }
  return out;
}

/** Zero-copy views over an outbound batch (`u16 length + bytes` records). */
export function* unpackDatagrams(packed) {
  let offset = 0;
  while (offset + 2 <= packed.length) {
    const length = (packed[offset] << 8) | packed[offset + 1];
    offset += 2;
    yield packed.subarray(offset, offset + length);
    offset += length;
  }
}

/**
 * One background reader per WebTransport session. Datagrams queue as they
 * arrive, each stamped with its arrival; the pump drains them
 * synchronously, so an empty burst costs no timer and no per-datagram
 * promise race.
 */
export class DatagramReader {
  constructor(readable, { maxQueued = 4096 } = {}) {
    this.queue = [];
    this.arrivals = [];
    this.dropped = 0;
    this.done = false;
    this.error = null;
    this.maxQueued = maxQueued;
    this.reader = readable.getReader();
    this.waiters = [];
    this.loop = this.run();
  }

  async run() {
    try {
      for (;;) {
        const { value, done } = await this.reader.read();
        if (done) break;
        if (!value) continue;
        if (this.queue.length >= this.maxQueued) {
          this.queue.shift();
          this.arrivals.shift();
          this.dropped += 1;
        }
        this.queue.push(value);
        this.arrivals.push(nowMicros());
        this.wake();
      }
    } catch (error) {
      this.error = error;
    } finally {
      this.done = true;
      this.wake();
    }
  }

  wake() {
    const waiters = this.waiters;
    this.waiters = [];
    for (const resolve of waiters) resolve();
  }

  /** Everything queued so far, with the arrival stamps. */
  take() {
    const taken = { datagrams: this.queue, arrivals: this.arrivals };
    this.queue = [];
    this.arrivals = [];
    return taken;
  }

  /** Resolves when a datagram is queued, the stream ends, or `ms` passes. */
  wait(ms) {
    if (this.queue.length || this.done) return Promise.resolve();
    return new Promise((resolve) => {
      const waiter = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        resolve();
      }, ms);
      this.waiters.push(waiter);
    });
  }

  async cancel() {
    try {
      await this.reader.cancel();
    } catch {
      /* already closed */
    }
  }
}

// A datagram this old is past any use (the Conductor's cue ceiling is
// 150 ms and the ARQ retransmits what must arrive): the carrier drops it
// rather than delivering it late.
const DATAGRAM_MAX_AGE_MS = 100;

/**
 * Opens WebTransport to the sidecar with its pinned certificate hash, over
 * HTTP/3 only (never a reliable HTTP/2 fallback), with bounded datagram
 * queues each way.
 */
export async function openWebTransport(sidecar) {
  if (typeof WebTransport !== "function") {
    throw new Error("WebTransport unavailable");
  }
  const wt = new WebTransport(sidecar.url, {
    requireUnreliable: true,
    serverCertificateHashes: [
      { algorithm: "sha-256", value: bytesFromHex(sidecar.hashHex) },
    ],
  });
  await wt.ready;
  wt.datagrams.incomingMaxAge = DATAGRAM_MAX_AGE_MS;
  wt.datagrams.outgoingMaxAge = DATAGRAM_MAX_AGE_MS;
  return wt;
}

async function loadJson(url, label) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(`${label} HTTP ${res.status}`);
  return res.json();
}

export function loadSidecarMeta(url = "./wt-sidecar.json") {
  return loadJson(url, "wt-sidecar.json");
}

export function loadControlPeerMeta(url = "./control-peer.json") {
  return loadJson(url, "control-peer.json");
}

/** First HEVC VideoDecoder config Chrome supports at this geometry. */
export async function pickHevcConfig(width, height) {
  if (typeof VideoDecoder !== "function") {
    return { ok: false, detail: "VideoDecoder API unavailable" };
  }
  for (const codec of [
    "hev1.1.6.L150.B0",
    "hev1.1.6.L120.B0",
    "hev1.1.6.L93.B0",
    "hvc1.1.6.L150.B0",
  ]) {
    const config = {
      codec,
      codedWidth: width,
      codedHeight: height,
      hardwareAcceleration: "prefer-hardware",
    };
    try {
      const { supported, config: accepted } =
        await VideoDecoder.isConfigSupported(config);
      if (supported) {
        return { ok: true, config: accepted || config, detail: `codec=${codec}` };
      }
    } catch (error) {
      return { ok: false, detail: `isConfigSupported threw: ${error?.message || error}` };
    }
  }
  return {
    ok: false,
    detail: "no HEVC VideoDecoder config supported (Chrome needs hardware HEVC)",
  };
}
