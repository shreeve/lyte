// The viewer: a standing session shell over the organs the proof harness
// runs. It reads a same-origin config, dials the relay (unpaired unless the
// config carries a PIN), shows the desktop full-window, forwards input,
// plays audio once a click unlocks it, and re-dials whenever the carrier or
// the session ends. WASM decides everything a session does; this file
// opens, pumps, and opens again.

import { AudioPlayout } from "./audio-playout.js";
import { installCanvasInput } from "./interaction.js";
import { bytesFromHex, nowMicros } from "./lyte-io.js";
import { SessionPump } from "./session-pump.js";
import { VideoSink } from "./video-sink.js";

export const VIEWER_CONFIG_URL = "./lyte-viewer.json";

// One pump turn waits at most this long for a datagram before ticking.
const TURN_WAIT_MS = 2;
// After a session ends, wait this long for the host to acknowledge its
// teardown before the carrier closes.
const LINGER_MS = 300;
// The geometry the pointer maps to until the first frame decodes.
const DEFAULT_GEOMETRY = { width: 2048, height: 1280 };

/** A SHA-256 certificate hash, as 64 hex digits or base64 (either alphabet). */
export function decodeCertificateHash(text) {
  if (typeof text !== "string") throw new Error("certificate hash must be a string");
  const clean = text.trim().replace(/:/g, "");
  if (/^[0-9a-fA-F]{64}$/.test(clean)) return bytesFromHex(clean);
  if (!/^[A-Za-z0-9+/_-]+=*$/.test(clean)) {
    throw new Error("certificate hash is neither hex nor base64");
  }
  const binary = atob(clean.replace(/-/g, "+").replace(/_/g, "/"));
  if (binary.length !== 32) {
    throw new Error(`certificate hash is ${binary.length} bytes, not SHA-256's 32`);
  }
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/**
 * Validates `lyte-viewer.json`. `relayUrl` resolves against the page, so a
 * same-origin relay may be a path; it must be https. The host's static key
 * is 64 hex digits. `serverCertificateHashes` (one string or a list) pins a
 * self-signed relay; absent, the relay must present a CA-trusted
 * certificate. `pin` is optional: without one the viewer connects unpaired.
 */
export function parseViewerConfig(raw, baseUrl) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("config must be a JSON object");
  }
  if (typeof raw.relayUrl !== "string" || !raw.relayUrl.trim()) {
    throw new Error("relayUrl is required");
  }
  const url = new URL(raw.relayUrl.trim(), baseUrl);
  if (url.protocol !== "https:") {
    throw new Error(`relayUrl must be https (WebTransport), got ${url.protocol}`);
  }
  const hostKey = raw.hostStaticPublicKeyHex;
  if (typeof hostKey !== "string" || !/^[0-9a-fA-F]{64}$/.test(hostKey.trim())) {
    throw new Error("hostStaticPublicKeyHex must be 64 hex digits");
  }
  const hashes = raw.serverCertificateHashes ?? [];
  const certificateHashes = (Array.isArray(hashes) ? hashes : [hashes]).map(
    decodeCertificateHash
  );
  if (raw.pin != null && typeof raw.pin !== "string") {
    throw new Error("pin must be a string");
  }
  return {
    relay: { url: url.href, certificateHashes },
    hostStaticPublicKeyHex: hostKey.trim().toLowerCase(),
    pin: raw.pin?.trim() || "",
  };
}

/**
 * The relay as its descriptor names it. A Janus `webtransport` route
 * answers `GET <path>` with `{url, max_datagram, certificate_hashes}`
 * (`certificate_hashes`: `{algorithm: "sha-256", value: <base64>}`), fetched
 * before every dial because pinned hashes rotate. A relay that answers with
 * anything else keeps the config's own URL and hashes.
 */
export async function resolveRelay(relay, fetchJson) {
  let descriptor;
  try {
    descriptor = await fetchJson(relay.url);
  } catch {
    return relay;
  }
  if (!descriptor || typeof descriptor.url !== "string"
      || !Array.isArray(descriptor.certificate_hashes)) {
    return relay;
  }
  const url = new URL(descriptor.url, relay.url);
  if (url.protocol !== "https:") return relay;
  const certificateHashes = descriptor.certificate_hashes
    .filter((h) => h && h.algorithm === "sha-256")
    .map((h) => decodeCertificateHash(h.value));
  return { url: url.href, certificateHashes };
}

async function fetchDescriptor(url) {
  const response = await fetch(url, {
    cache: "no-store", headers: { Accept: "application/json" },
  });
  if (!response.ok) throw new Error(`descriptor ${response.status}`);
  return response.json();
}

/**
 * Milliseconds before re-dial `attempt` (0-based since the last session
 * that stayed live): the first is immediate, then the native dial ladder's
 * floor, doubling to its ceiling.
 */
export function reconnectDelayMs(attempt, { floorMs, ceilingMs }) {
  if (attempt <= 0) return 0;
  return Math.min(ceilingMs, floorMs * 2 ** (attempt - 1));
}

/**
 * One viewer: dial, pump until the session ends, re-dial. `onStatus`
 * receives `{ state, detail, retryInMs }` with state `connecting`, `live`,
 * `reconnecting` or `stopped`. Everything that touches the browser is
 * injectable so the loop runs under node.
 */
export class Viewer {
  constructor({
    bridge,
    config,
    canvas,
    onStatus = () => {},
    openPump = (b, relay, opts) => SessionPump.open(b, relay, opts),
    fetchJson = fetchDescriptor,
    openSink = (b, surface) => VideoSink.open(b, surface),
    openAudio = (b) => AudioPlayout.open(b),
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    clock = () => performance.now(),
  }) {
    Object.assign(this, {
      bridge, config, canvas, onStatus, openPump, fetchJson, openSink, openAudio,
    });
    this.sleepFor = sleep;
    this.clock = clock;
    this.stopped = false;
    this.stopReason = null;
    this.current = null;
    this.audio = null;
    this.audioOpening = null;
    this.sessions = 0;
    this.wake = null;
    this.ladder = {
      floorMs: bridge.redialFloorMicroseconds / 1000,
      ceilingMs: bridge.redialCeilingMicroseconds / 1000,
    };
  }

  /** The live session's pump, or null between sessions. */
  get pump() {
    return this.current?.pump ?? null;
  }

  /** The stream geometry input maps to. */
  get frameSize() {
    return this.current?.sink?.frameSize || DEFAULT_GEOMETRY;
  }

  report(state, detail = "", retryInMs = null) {
    this.onStatus({ state, detail, retryInMs });
  }

  /** Runs sessions until stop(). */
  async run() {
    let attempt = 0;
    while (!this.stopped) {
      this.report("connecting", attempt > 0 ? `attempt ${attempt + 1}` : "");
      const outcome = await this.session();
      if (this.stopped) break;
      // A session that stayed live a full ladder step restarts the ladder.
      if (outcome.liveMs >= this.ladder.floorMs) attempt = 0;
      const delay = reconnectDelayMs(attempt, this.ladder);
      attempt += 1;
      this.report("reconnecting", outcome.reason, delay);
      await this.pause(delay);
    }
    this.report("stopped", this.stopReason || "");
  }

  /** One session from dial to end: `{ reason, liveMs }`. */
  async session() {
    let pump = null;
    let sink = null;
    let liveAt = null;
    let reason = "ended";
    const { bridge, config } = this;
    try {
      sink = await this.openSink(bridge, this.canvas);
      if (this.stopped) return { reason: "stopped", liveMs: 0 };
      const relay = await resolveRelay(config.relay, this.fetchJson);
      if (this.stopped) return { reason: "stopped", liveMs: 0 };
      pump = await this.openPump(bridge, relay, {
        hostStaticPublicKeyHex: config.hostStaticPublicKeyHex,
        pin: config.pin,
      });
      this.sessions += 1;
      this.current = { pump, sink };
      pump.onScheduled = (scheduled) => sink.enqueue(scheduled);
      this.audio?.resetStream();
      await pump.begin();
      sink.startPresenting();
      while (!this.stopped && !pump.failed && !pump.closed) {
        await pump.turn(TURN_WAIT_MS);
        sink.pumpDecode();
        this.audio?.pump();
        if (pump.ready && liveAt == null) {
          liveAt = this.clock();
          this.report("live");
        }
        if (sink.error) {
          reason = `video decode: ${sink.error?.message || sink.error}`;
          break;
        }
      }
      if (this.stopped) reason = this.stopReason || "stopped";
      else if (pump.failed) reason = pump.failure || "session failed";
      else if (pump.closed) reason = "the session closed";
      await this.linger(pump);
    } catch (error) {
      reason = error?.message || String(error);
    } finally {
      this.current = null;
      sink?.close();
      await pump?.close(reason);
    }
    return { reason, liveMs: liveAt == null ? 0 : this.clock() - liveAt };
  }

  /**
   * A ready session closes with a typed teardown; any session keeps
   * pumping briefly so what it queued is acknowledged.
   */
  async linger(pump) {
    if (pump.ready) await pump.send(this.bridge.controlTeardown(nowMicros()));
    const deadline = this.clock() + LINGER_MS;
    while (!pump.facts().reliableQuiescent && this.clock() < deadline) {
      await pump.turn(15);
    }
  }

  /** Sleeps `ms`, or less if stop() comes first. */
  pause(ms) {
    if (ms <= 0 || this.stopped) return Promise.resolve();
    return new Promise((resolve) => {
      this.wake = resolve;
      this.sleepFor(ms).then(resolve);
    }).finally(() => {
      this.wake = null;
    });
  }

  /** Ends the viewer: the live session tears down and the loop exits. */
  stop(reason = "stopped") {
    if (this.stopped) return;
    this.stopped = true;
    this.stopReason = reason;
    this.wake?.();
  }

  /**
   * The page is going away: the teardown leaves now and the carrier
   * closes without waiting on anything.
   */
  stopNow(reason = "page closed") {
    this.stop(reason);
    const pump = this.pump;
    if (!pump) return;
    if (pump.ready) pump.send(this.bridge.controlTeardown(nowMicros())).catch(() => {});
    pump.close(reason).catch(() => {});
  }

  /** Call from a user gesture: starts (or resumes) audio playout. */
  enableAudio() {
    if (this.audio) {
      this.audio.ring.resume?.().catch?.(() => {});
      return this.audio;
    }
    this.audioOpening ??= this.openAudio(this.bridge).then(
      (playout) => {
        this.audio = playout;
        return playout;
      },
      (error) => {
        this.audioOpening = null;
        this.report(this.pump?.ready ? "live" : "connecting", `audio: ${error?.message || error}`);
        return null;
      }
    );
    return this.audioOpening;
  }
}

/** Wires a Viewer to viewer.html's DOM and runs it. */
export async function startViewer(doc = document) {
  const canvas = doc.getElementById("screen");
  const statusEl = doc.getElementById("status");
  const hint = doc.getElementById("hint");
  const show = ({ state, detail, retryInMs }) => {
    const words = {
      connecting: "Connecting…",
      live: "Live",
      reconnecting: retryInMs ? `Reconnecting in ${Math.ceil(retryInMs / 1000)} s` : "Reconnecting…",
      stopped: "Disconnected",
      error: "Cannot start",
    };
    statusEl.textContent = [words[state] || state, detail].filter(Boolean).join(" — ");
    doc.body.dataset.state = state;
  };

  let viewer;
  try {
    show({ state: "connecting", detail: "loading" });
    const response = await fetch(VIEWER_CONFIG_URL, { cache: "no-store" });
    if (!response.ok) throw new Error(`${VIEWER_CONFIG_URL}: HTTP ${response.status}`);
    const config = parseViewerConfig(await response.json(), doc.baseURI);
    const { init } = await import("./index.js");
    await init();
    viewer = new Viewer({ bridge: globalThis.lyteBrowser, config, canvas, onStatus: show });
  } catch (error) {
    show({ state: "error", detail: error?.message || String(error) });
    return null;
  }

  const bridge = globalThis.lyteBrowser;
  installCanvasInput(canvas, {
    sendInput: (kind, now, ...args) => {
      const pump = viewer.pump;
      if (pump?.ready) pump.send(bridge.controlSendInput(kind, now, ...args));
    },
    hostSize: () => viewer.frameSize,
  });
  // Autoplay: audio starts on the first click or key, which also focuses
  // the canvas for input.
  const unlock = () => {
    viewer.enableAudio();
    canvas.focus();
  };
  canvas.addEventListener("pointerdown", unlock);
  doc.addEventListener("keydown", unlock);
  hint?.addEventListener("pointerdown", unlock);
  canvas.addEventListener("focus", () => (doc.body.dataset.focused = "true"));
  canvas.addEventListener("blur", () => (doc.body.dataset.focused = "false"));
  globalThis.addEventListener("pagehide", () => viewer.stopNow("page closed"));
  globalThis.lyteViewer = viewer;
  viewer.run();
  return viewer;
}
