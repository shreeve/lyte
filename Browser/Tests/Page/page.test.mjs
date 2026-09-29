// The page's IO shell under node: canvas input against a fake canvas, and
// the session proof's loop against a fake bridge, pump and sink.
// Run: node --test Browser/Tests/Page/page.test.mjs (the macOS gate does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { AudioPlayout, estimateRingDepth } from "../../Page/audio-playout.js";
import { installCanvasInput } from "../../Page/interaction.js";
import { webTransportOptions } from "../../Page/lyte-io.js";
import {
  Viewer,
  decodeCertificateHash,
  parseViewerConfig,
  reconnectDelayMs,
} from "../../Page/viewer.js";
import { runSessionProof } from "../../Page/session-proof.js";
import { SessionPump } from "../../Page/session-pump.js";
import { VideoSink } from "../../Page/video-sink.js";

/** Replays DOM events into installCanvasInput; returns what the host saw. */
function replay(events, { kinds = ["keyKeycode", "pointerButton"] } = {}) {
  const listeners = {};
  const canvas = {
    addEventListener: (type, fn) => (listeners[type] = fn),
    removeEventListener: () => {},
    focus() {},
    setPointerCapture() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 100 }),
  };
  const sent = [];
  const held = new Map();
  installCanvasInput(canvas, {
    sendInput: (kind, _now, a, b) => {
      if (!kinds.includes(kind)) return;
      if (kind === "pointerMotionAbsolute") {
        sent.push(`${kind}:${a}:${b}`);
        return;
      }
      sent.push(`${kind}:${a}:${b ? "down" : "up"}`);
      held.set(`${kind}:${a}`, b);
    },
    hostSize: () => ({ width: 100, height: 100 }),
  });
  for (const [type, fields] of events) {
    listeners[type]({
      type, clientX: 5, clientY: 5, pointerId: 1, buttons: 0, repeat: false,
      preventDefault() {}, ...fields,
    });
  }
  const stuck = [...held].filter(([, pressed]) => pressed).map(([key]) => key);
  return { sent, stuck };
}

test("a key released under Ctrl is released on the host, and Ctrl reaches it", () => {
  const { sent, stuck } = replay([
    ["keydown", { code: "KeyA" }],
    ["keydown", { code: "ControlLeft", ctrlKey: true }],
    ["keyup", { code: "KeyA", ctrlKey: true }],
    ["keydown", { code: "KeyC", ctrlKey: true }],
    ["keyup", { code: "KeyC", ctrlKey: true }],
    ["keyup", { code: "ControlLeft" }],
  ]);
  assert.deepEqual(stuck, []);
  assert.deepEqual(sent, [
    "keyKeycode:30:down", "keyKeycode:29:down", "keyKeycode:30:up",
    "keyKeycode:46:down", "keyKeycode:46:up", "keyKeycode:29:up",
  ]);
});

test("Meta and Meta chords stay with the browser", () => {
  const { sent } = replay([
    ["keydown", { code: "MetaLeft", metaKey: true }],
    ["keydown", { code: "KeyC", metaKey: true }],
    ["keyup", { code: "KeyC", metaKey: true }],
    ["keyup", { code: "MetaLeft" }],
  ]);
  assert.deepEqual(sent, []);
});

test("volume keys stay with the listener's own machine, as in the native client", () => {
  const events = ["AudioVolumeMute", "AudioVolumeDown", "AudioVolumeUp"].flatMap((code) => [
    ["keydown", { code }],
    ["keyup", { code }],
  ]);
  assert.deepEqual(replay(events).sent, []);
});

test("chorded buttons that arrive as pointermove balance on the host", () => {
  // Pointer Events: pointerdown for the first press, pointerup for the
  // last release, pointermove for every edge between.
  const { sent, stuck } = replay([
    ["pointerdown", { button: 0, buttons: 1 }],
    ["pointermove", { button: 2, buttons: 3 }],
    ["pointermove", { button: 0, buttons: 2 }],
    ["pointerup", { button: 2, buttons: 0 }],
  ]);
  assert.deepEqual(stuck, []);
  assert.deepEqual(sent, [
    "pointerButton:272:down", "pointerButton:273:down",
    "pointerButton:272:up", "pointerButton:273:up",
  ]);
});

test("the JIS Kana and Eisu keys reach the host as the native client sends them", () => {
  const { sent } = replay([
    ["keydown", { code: "Lang1" }],
    ["keyup", { code: "Lang1" }],
    ["keydown", { code: "Lang2" }],
    ["keyup", { code: "Lang2" }],
  ]);
  assert.deepEqual(sent, [
    "keyKeycode:92:down", "keyKeycode:92:up", "keyKeycode:94:down", "keyKeycode:94:up",
  ]);
});

test("a drag that leaves the canvas keeps moving the host pointer to its edge", () => {
  const { sent } = replay(
    [
      ["pointerdown", { button: 0, buttons: 1, clientX: 50, clientY: 50 }],
      ["pointermove", { buttons: 1, clientX: 180, clientY: -20 }],
      ["pointerup", { button: 0, buttons: 0, clientX: 180, clientY: -20 }],
      ["pointermove", { buttons: 0, clientX: 180, clientY: -20 }],
    ],
    { kinds: ["pointerMotionAbsolute", "pointerButton"] }
  );
  assert.deepEqual(sent, [
    "pointerMotionAbsolute:50:50", "pointerButton:272:down",
    "pointerMotionAbsolute:100:0", "pointerButton:272:up",
  ]);
});

test("a drag that enters the canvas with a button already down presses nothing", () => {
  const { sent } = replay([
    ["pointermove", { button: -1, buttons: 1 }],
    ["pointerup", { button: 0, buttons: 0 }],
  ]);
  assert.deepEqual(sent, []);
});

test("the session proof stops as soon as the host closes the session", async (t) => {
  const facts = {
    status: "closed", handshakeCompleted: true, paired: true,
    capabilitiesAgreed: true, reliableQuiescent: true,
  };
  globalThis.lyteBrowser = {
    conductorBeatMicroseconds: 16_667,
    classifyAnnexBBytes: () => null,
    mediaStats: () => ({ assembled: 3, skippedLate: 0 }),
    controlFacts: () => facts,
    interactionStats: () => ({}),
  };
  const pump = {
    status: "ready", notes: [], ingested: 0, batches: 0,
    get ready() { return this.status === "ready"; },
    get failed() { return this.status === "failed"; },
    get closed() { return this.status === "closed"; },
    async begin() {},
    // The host's teardown lands mid-video.
    async turn() { this.status = "closed"; },
    async close() {},
  };
  const sink = {
    stats: {}, recent: [], busy: false, presenter: {},
    enqueue() {}, pumpDecode() {}, startPresenting() {}, close() {},
  };
  const open = [SessionPump.open, VideoSink.open];
  SessionPump.open = async () => pump;
  VideoSink.open = async () => sink;
  t.after(() => {
    [SessionPump.open, VideoSink.open] = open;
    delete globalThis.lyteBrowser;
  });

  const started = Date.now();
  await runSessionProof({ sidecar: {}, timeoutMs: 3_000 });
  assert.ok(Date.now() - started < 1_000, "the loop ran to its deadline");
});

/** A VideoSink over a fake decoder and bridge; nothing is presented. */
function stalledSink(bridge) {
  globalThis.VideoDecoder ??= class {
    decodeQueueSize = 0;
    configure() {}
    decode() {}
  };
  return new VideoSink(bridge, { detail: "", config: { codec: "hvc1" } }, {});
}

test("a page that stops presenting keeps only the newest keyframe's chain queued", () => {
  const dropped = [];
  const sink = stalledSink({ mediaNoteDropped: (n) => dropped.push(n) });
  for (let n = 0; n < 1_000; n++) {
    sink.enqueue([{ frameNumber: n, isRandomAccess: n % 60 === 0, presentationMicroseconds: n }]);
  }
  assert.ok(sink.queue.length <= 121, `queue=${sink.queue.length}`);
  assert.equal(sink.queue[0].isRandomAccess, true);
  assert.equal(dropped.length + sink.queue.length, 1_000);
});

test("a page that stops presenting still closes the frames WASM abandoned", () => {
  const closed = [];
  const sink = stalledSink({ mediaTakeAbandoned: () => [7] });
  sink.decoded.set(1, { frame: { close: () => closed.push(7) }, meta: { frameNumber: 7 } });
  sink.pumpDecode();
  assert.deepEqual(closed, [7]);
  assert.equal(sink.decoded.size, 0);
});

/** An AudioPlayout over a fake ring and decoder; outputs are released by hand. */
async function fakePlayout(verdicts) {
  const pulls = [];
  const bridge = {
    audioPacketFrames: 240,
    audioPull: (_now, pipeline) => {
      pulls.push(pipeline);
      return verdicts.shift() ?? null;
    },
  };
  const pushed = [];
  const ring = {
    depthFrames: () => pushed.reduce((sum, pcm) => sum + pcm.length / 2, 0),
    pushPcm: (pcm) => pushed.push(pcm),
    close: async () => {},
  };
  const decoders = [];
  const factory = async (onPcm) => {
    const decoder = {
      ok: true, detail: "fake opus", decoding: [], failed: false,
      decode(bytes) {
        if (this.failed) throw new Error("decoder closed");
        this.decoding.push(bytes[0]);
      },
      /** Emits the oldest decode as 240 frames of its first byte. */
      output() {
        onPcm(new Float32Array(480).fill(this.decoding.shift()));
      },
      close() {},
    };
    decoders.push(decoder);
    return decoder;
  };
  const playout = new AudioPlayout(bridge, ring, factory);
  await playout.resetStream();
  return { playout, pulls, pushed, decoders };
}

const opusPacket = (value) => ({ bytes: new Uint8Array([value]), captureMicroseconds: value });

test("decoded and concealed audio reach the ring in the order WASM pulled it", async () => {
  const { playout, pushed, decoders } = await fakePlayout([
    opusPacket(1), { conceal: true, number: 2 }, opusPacket(3),
  ]);
  playout.pump(0);
  assert.equal(pushed.length, 0, "the concealment waits behind the packet still decoding");
  decoders[0].output();
  decoders[0].output();
  assert.deepEqual(pushed.map((pcm) => pcm[0]), [1, Math.fround(95 / 96), 3]);
  assert.equal(pushed[1][2 * 96], 0, "a concealment decays to silence");
});

test("WASM sees the audio the page holds, decoding included", async () => {
  const { playout, pulls } = await fakePlayout([opusPacket(1), opusPacket(2), opusPacket(3)]);
  playout.pump(0);
  assert.deepEqual(pulls, [0, 240, 480, 720]);
});

test("a decoder that fails is replaced and its unfilled slots never block the ring", async () => {
  const { playout, pushed, decoders } = await fakePlayout([opusPacket(1), opusPacket(2)]);
  playout.pump(0);
  decoders[0].failed = true;
  playout.bridge.audioPull = (_now, pipeline) => (pipeline < 720 ? opusPacket(9) : null);
  playout.pump(0);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(decoders.length, 2, "a fresh decoder replaces the failed one");
  assert.equal(playout.slots.length, 0);
  playout.pump(0);
  decoders[1].output();
  assert.deepEqual(pushed.map((pcm) => pcm[0]), [9]);
});

test("audio pushed into an empty ring counts whole until the ring reports it played", () => {
  // The ring ran dry 8 ms before its last report; 4 800 frames arrive now.
  assert.equal(estimateRingDepth(0, 4_800, 8), 4_800);
  // What it held at the report drains at 48 frames per ms, never below zero.
  assert.equal(estimateRingDepth(960, 0, 5), 720);
  assert.equal(estimateRingDepth(960, 240, 50), 240);
});

// MARK: the viewer

const HOST_KEY = "ab".repeat(32);
const HASH_HEX = "0f".repeat(32);

test("a CA-trusted relay dials without pinned certificate hashes", () => {
  const options = webTransportOptions({ url: "https://relay.example/", certificateHashes: [] });
  assert.deepEqual(options, { requireUnreliable: true });
  assert.equal("serverCertificateHashes" in options, false);
});

test("a self-signed relay dials with its pinned hash, from the sidecar or the config", () => {
  const fromSidecar = webTransportOptions({ url: "https://127.0.0.1:1/", hashHex: HASH_HEX });
  const fromConfig = webTransportOptions({
    url: "https://127.0.0.1:1/",
    certificateHashes: [decodeCertificateHash(HASH_HEX)],
  });
  for (const options of [fromSidecar, fromConfig]) {
    assert.equal(options.requireUnreliable, true);
    assert.equal(options.serverCertificateHashes.length, 1);
    assert.equal(options.serverCertificateHashes[0].algorithm, "sha-256");
    assert.deepEqual([...options.serverCertificateHashes[0].value], Array(32).fill(0x0f));
  }
});

test("the viewer config connects unpaired by default and resolves a same-origin relay path", () => {
  const config = parseViewerConfig(
    { relayUrl: "/lyte-relay", hostStaticPublicKeyHex: HOST_KEY.toUpperCase() },
    "https://desk.example/"
  );
  assert.deepEqual(config, {
    relay: { url: "https://desk.example/lyte-relay", certificateHashes: [] },
    hostStaticPublicKeyHex: HOST_KEY,
    pin: "",
  });
});

test("certificate hashes may be hex or base64, and must be SHA-256 sized", () => {
  const bytes = Uint8Array.from({ length: 32 }, (_, i) => i * 7 + 250);
  const hex = Buffer.from(bytes).toString("hex");
  const base64 = Buffer.from(bytes).toString("base64");
  const base64url = Buffer.from(bytes).toString("base64url");
  const config = parseViewerConfig(
    {
      relayUrl: "https://relay.example:4433/lyte",
      hostStaticPublicKeyHex: HOST_KEY,
      serverCertificateHashes: [hex, base64, base64url],
      pin: " 246810 ",
    },
    "https://desk.example/"
  );
  for (const hash of config.relay.certificateHashes) assert.deepEqual([...hash], [...bytes]);
  assert.equal(config.pin, "246810");
  assert.throws(() => decodeCertificateHash(Buffer.alloc(20).toString("base64")), /32/);
  assert.throws(() => decodeCertificateHash("not a hash!"), /hex nor base64/);
});

test("a viewer config the relay could not serve is refused", () => {
  const base = "https://desk.example/";
  const ok = { relayUrl: "https://relay.example/", hostStaticPublicKeyHex: HOST_KEY };
  assert.throws(() => parseViewerConfig({ ...ok, relayUrl: "http://relay.example/" }, base), /https/);
  assert.throws(() => parseViewerConfig({ ...ok, relayUrl: "" }, base), /relayUrl/);
  assert.throws(() => parseViewerConfig({ ...ok, hostStaticPublicKeyHex: "abc" }, base), /64 hex/);
  assert.throws(() => parseViewerConfig({ ...ok, pin: 246810 }, base), /pin/);
  assert.throws(() => parseViewerConfig([], base), /object/);
});

test("re-dials climb the native dial ladder after one immediate retry", () => {
  const ladder = { floorMs: 2_000, ceilingMs: 30_000 };
  assert.deepEqual(
    [0, 1, 2, 3, 4, 5, 6].map((attempt) => reconnectDelayMs(attempt, ladder)),
    [0, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
  );
});

/**
 * A Viewer over fakes. `script(n)` shapes session n's pump: how many
 * turns it stays ready, and how it ends.
 */
function fakeViewer({ script, sessions = 3 }) {
  let clockMs = 0;
  const statuses = [];
  const delays = [];
  const log = [];
  const bridge = {
    redialFloorMicroseconds: 2_000_000,
    redialCeilingMicroseconds: 30_000_000,
    controlTeardown: () => "teardown",
  };
  let opened = 0;
  let viewer = null;
  const openPump = async () => {
    const n = opened++;
    if (n >= sessions) viewer.stop("test over");
    const plan = script(n);
    if (plan.dialError) throw new Error(plan.dialError);
    let turns = 0;
    return {
      status: "handshaking",
      failure: null,
      get ready() { return this.status === "ready"; },
      get failed() { return this.status === "failed"; },
      get closed() { return this.status === "closed"; },
      async begin() {},
      async turn() {
        // A real turn waits on the carrier: let other tasks run.
        await new Promise(setImmediate);
        clockMs += 100;
        turns += 1;
        if (turns === 1) this.status = "ready";
        if (turns > plan.liveTurns) {
          this.status = plan.end === "closed" ? "closed" : "failed";
          this.failure = plan.end === "closed" ? null : plan.end;
        }
      },
      async send(step) {
        log.push(`session ${n} sent ${step}`);
        if (step === "teardown") this.status = "closed";
      },
      facts: () => ({ reliableQuiescent: true }),
      async close(reason) {
        log.push(`session ${n} closed: ${reason}`);
      },
    };
  };
  const sink = () => ({
    error: null, frameSize: null,
    enqueue() {}, startPresenting() {}, pumpDecode() {}, close() {},
  });
  viewer = new Viewer({
    bridge,
    config: { relay: { url: "https://relay.example/" }, hostStaticPublicKeyHex: HOST_KEY, pin: "" },
    canvas: {},
    onStatus: (status) => statuses.push(status),
    openPump,
    openSink: async () => sink(),
    sleep: async (ms) => {
      delays.push(ms);
      clockMs += ms;
    },
    clock: () => clockMs,
  });
  return { viewer, statuses, delays, log, opened: () => opened };
}

test("the viewer stays live until its carrier ends, then re-dials at once", async () => {
  const { viewer, statuses, delays, log } = fakeViewer({
    script: () => ({ liveTurns: 50, end: "carrier closed: EOF" }),
  });
  await viewer.run();
  const states = statuses.map((s) => s.state);
  assert.deepEqual(states.slice(0, 4), ["connecting", "live", "reconnecting", "connecting"]);
  assert.equal(statuses[2].detail, "carrier closed: EOF");
  assert.deepEqual(delays, [], "a session live past the ladder's floor re-dials at once");
  assert.ok(log.includes("session 0 closed: carrier closed: EOF"));
  assert.equal(states.at(-1), "stopped");
});

test("dials that keep failing back off along the ladder", async () => {
  const { viewer, delays, statuses } = fakeViewer({
    sessions: 6,
    script: () => ({ dialError: "WebTransport: connection refused" }),
  });
  await viewer.run();
  assert.deepEqual(delays, [2_000, 4_000, 8_000, 16_000, 30_000]);
  assert.ok(statuses.some((s) => s.state === "reconnecting" && s.detail.includes("refused")));
});

test("a session the host closes is re-dialed, and a short-lived one does not reset the ladder", async () => {
  const { viewer, delays } = fakeViewer({
    sessions: 4,
    script: () => ({ liveTurns: 2, end: "closed" }),
  });
  await viewer.run();
  assert.deepEqual(delays, [2_000, 4_000, 8_000]);
});

test("stopping the viewer tears the live session down and ends the loop", async () => {
  const { viewer, log, statuses } = fakeViewer({
    sessions: 1,
    script: () => ({ liveTurns: Infinity }),
  });
  const running = viewer.run();
  while (!statuses.some((s) => s.state === "live")) await new Promise(setImmediate);
  viewer.stop("page closed");
  await running;
  assert.ok(log.includes("session 0 sent teardown"), log.join(" | "));
  assert.ok(log.includes("session 0 closed: page closed"), log.join(" | "));
  assert.equal(statuses.at(-1).state, "stopped");
  assert.equal(statuses.at(-1).detail, "page closed");
});
