// The page's IO shell under node: canvas input against a fake canvas, and
// the session proof's loop against a fake bridge, pump and sink.
// Run: node --test Browser/Tests/Page/page.test.mjs (the macOS gate does).
import { test } from "node:test";
import assert from "node:assert/strict";
import { installCanvasInput } from "../../Page/interaction.js";
import { runSessionProof } from "../../Page/session-proof.js";
import { SessionPump } from "../../Page/session-pump.js";
import { VideoSink } from "../../Page/video-sink.js";

/** Replays DOM events into installCanvasInput; returns what the host saw. */
function replay(events) {
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
    sendInput: (kind, _now, code, pressed) => {
      if (kind !== "keyKeycode" && kind !== "pointerButton") return;
      sent.push(`${kind}:${code}:${pressed ? "down" : "up"}`);
      held.set(`${kind}:${code}`, pressed);
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
    stats: {}, presentations: [], busy: false, presenter: {},
    enqueue() {}, pumpDecode() {}, pumpPresent: () => false, close() {},
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
