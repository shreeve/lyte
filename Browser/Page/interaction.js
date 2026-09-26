// Interaction organs: DOM input → sealed InputEvent, clipboard text over
// capability-gated CTRL, Opus → WebCodecs → AudioWorklet ring. Policy stays
// in WASM; this file is the browser IO shell.

import { nowMicros, sleep } from "./lyte-io.js";

// DOM `KeyboardEvent.code` (physical position) → Linux evdev KEY_* codes.
// The protocol carries position codes; the host's XKB map owns layout.
// Volume keys are absent, as in the native client: the stream plays here,
// so volume belongs to the listener's own machine.
const EVDEV_KEYS = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6,
  Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10, Digit0: 11, Minus: 12,
  Equal: 13, Backspace: 14, Tab: 15, KeyQ: 16, KeyW: 17, KeyE: 18,
  KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24, KeyP: 25,
  BracketLeft: 26, BracketRight: 27, Enter: 28, ControlLeft: 29, KeyA: 30,
  KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37,
  KeyL: 38, Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42,
  Backslash: 43, KeyZ: 44, KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48,
  KeyN: 49, KeyM: 50, Comma: 51, Period: 52, Slash: 53, ShiftRight: 54,
  NumpadMultiply: 55, AltLeft: 56, Space: 57, CapsLock: 58, F1: 59,
  F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68,
  NumLock: 69, ScrollLock: 70, Numpad7: 71, Numpad8: 72, Numpad9: 73,
  NumpadSubtract: 74, Numpad4: 75, Numpad5: 76, Numpad6: 77,
  NumpadAdd: 78, Numpad1: 79, Numpad2: 80, Numpad3: 81, Numpad0: 82,
  NumpadDecimal: 83, IntlBackslash: 86, F11: 87, F12: 88, IntlRo: 89,
  NumpadEnter: 96, ControlRight: 97, NumpadDivide: 98, PrintScreen: 99,
  AltRight: 100, Home: 102, ArrowUp: 103, PageUp: 104, ArrowLeft: 105,
  ArrowRight: 106, End: 107, ArrowDown: 108, PageDown: 109, Insert: 110,
  Delete: 111, NumpadEqual: 117, Pause: 119, NumpadComma: 121,
  IntlYen: 124, MetaLeft: 125, MetaRight: 126, ContextMenu: 127,
  // JIS Kana / Eisu: KEY_HENKAN / KEY_MUHENKAN, as the native client maps
  // the same keys.
  Lang1: 92, Lang2: 94,
  F13: 183, F14: 184, F15: 185, F16: 186, F17: 187, F18: 188, F19: 189,
  F20: 190, F21: 191, F22: 192, F23: 193, F24: 194,
};

export function evdevKeyForCode(code) {
  return EVDEV_KEYS[code] ?? null;
}

/** DOM buttons → Linux BTN_* (left/middle/right/side/extra). */
export function domButtonToEvdev(button) {
  return [272, 274, 273, 275, 276][button] ?? null;
}

// `PointerEvent.buttons` bits → Linux BTN_* (left, right, middle, side, extra).
const BUTTON_BITS = [[1, 272], [2, 273], [4, 274], [8, 275], [16, 276]];

// KEY_LEFTMETA / KEY_RIGHTMETA. Meta never reaches the host: its chords
// belong to the browser and OS, and a lone Super tap would toggle GNOME's
// Activities.
const META_KEYCODES = new Set([125, 126]);

/**
 * Canvas CSS pixels → host stream pixels (aspect-fit letterbox). Outside
 * the stream it is null, or the nearest edge point when `clamp` is set (a
 * drag that leaves the canvas keeps moving the host pointer).
 */
export function mapPointerToHost(canvas, clientX, clientY, hostW, hostH, clamp = false) {
  const rect = canvas.getBoundingClientRect();
  const scale = Math.min(rect.width / hostW, rect.height / hostH);
  if (!(scale > 0)) return null;
  const ox = (rect.width - hostW * scale) / 2;
  const oy = (rect.height - hostH * scale) / 2;
  const hx = (clientX - rect.left - ox) / scale;
  const hy = (clientY - rect.top - oy) / scale;
  if (clamp) return { x: Math.min(Math.max(hx, 0), hostW), y: Math.min(Math.max(hy, 0), hostH) };
  if (hx < 0 || hy < 0 || hx > hostW || hy > hostH) return null;
  return { x: hx, y: hy };
}

// Wheel lines/pages → pixels, at libinput's ~15 px per detent (the native
// client's constant). DOM deltaY is already positive-down like evdev.
const PIXELS_PER_LINE = 15;
const PIXELS_PER_PAGE = PIXELS_PER_LINE * 20;
// DOM has no scroll phase; a quiet gap ends the gesture.
const AXIS_FINISH_AFTER_MS = 150;

/**
 * Captures pointer, wheel and keyboard on the video canvas.
 * `sendInput(kind, ...args)` delivers one event to the session, which
 * coalesces motion and never drops an edge it accepted, so the held sets
 * here are what the host holds. `hostSize()` returns the stream geometry.
 * Every key and button the host was told is down is released on blur and
 * on dispose, so the host never keeps a stuck key.
 */
export function installCanvasInput(canvas, { sendInput, hostSize }) {
  const heldKeys = new Set();
  const heldButtons = new Set();
  let axisTimer = null;

  const send = (kind, ...args) => sendInput(kind, nowMicros(), ...args);
  const toHost = (event) => {
    const { width, height } = hostSize();
    return mapPointerToHost(
      canvas, event.clientX, event.clientY, width, height, heldButtons.size > 0
    );
  };

  // Pointer Events report only the first press and last release; chorded
  // edges arrive as pointermove. Each event's `buttons` mask is the truth,
  // and presses count only while a press that began on the canvas is down.
  const syncButtons = (event, allowPress) => {
    for (const [bit, button] of BUTTON_BITS) {
      const down = (event.buttons & bit) !== 0;
      if (down === heldButtons.has(button) || (down && !allowPress)) continue;
      event.preventDefault();
      send("pointerButton", button, down);
      if (down) heldButtons.add(button);
      else heldButtons.delete(button);
    }
  };
  const onMove = (event) => {
    const mapped = toHost(event);
    if (mapped) send("pointerMotionAbsolute", mapped.x, mapped.y);
    syncButtons(event, heldButtons.size > 0);
  };
  const onDown = (event) => {
    if (domButtonToEvdev(event.button) == null) return;
    event.preventDefault();
    canvas.focus();
    canvas.setPointerCapture?.(event.pointerId);
    const mapped = toHost(event);
    if (mapped) send("pointerMotionAbsolute", mapped.x, mapped.y);
    syncButtons(event, true);
  };
  const onUp = (event) => syncButtons(event, false);
  const onWheel = (event) => {
    event.preventDefault();
    const scale =
      event.deltaMode === 1 ? PIXELS_PER_LINE : event.deltaMode === 2 ? PIXELS_PER_PAGE : 1;
    send("pointerAxis", event.deltaX * scale, event.deltaY * scale, false);
    clearTimeout(axisTimer);
    axisTimer = setTimeout(() => send("pointerAxis", 0, 0, true), AXIS_FINISH_AFTER_MS);
  };
  const onKey = (event) => {
    const keycode = evdevKeyForCode(event.code);
    if (keycode == null) return;
    if (event.type === "keyup") {
      // A release of anything the host holds crosses every gate.
      if (!heldKeys.has(keycode)) return;
      event.preventDefault();
      send("keyKeycode", keycode, false);
      heldKeys.delete(keycode);
      return;
    }
    if (event.metaKey || META_KEYCODES.has(keycode)) return;
    event.preventDefault();
    // The wire has no repeat value: a stream of downs is a wedged key.
    if (event.repeat) return;
    send("keyKeycode", keycode, true);
    heldKeys.add(keycode);
  };
  const releaseAll = () => {
    for (const keycode of heldKeys) send("keyKeycode", keycode, false);
    for (const button of heldButtons) send("pointerButton", button, false);
    heldKeys.clear();
    heldButtons.clear();
  };
  const onContextMenu = (event) => event.preventDefault();

  canvas.tabIndex = 0;
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerdown", onDown);
  canvas.addEventListener("pointerup", onUp);
  canvas.addEventListener("pointercancel", releaseAll);
  canvas.addEventListener("wheel", onWheel, { passive: false });
  canvas.addEventListener("keydown", onKey);
  canvas.addEventListener("keyup", onKey);
  canvas.addEventListener("blur", releaseAll);
  canvas.addEventListener("contextmenu", onContextMenu);

  return () => {
    clearTimeout(axisTimer);
    releaseAll();
    canvas.removeEventListener("pointermove", onMove);
    canvas.removeEventListener("pointerdown", onDown);
    canvas.removeEventListener("pointerup", onUp);
    canvas.removeEventListener("pointercancel", releaseAll);
    canvas.removeEventListener("wheel", onWheel);
    canvas.removeEventListener("keydown", onKey);
    canvas.removeEventListener("keyup", onKey);
    canvas.removeEventListener("blur", releaseAll);
    canvas.removeEventListener("contextmenu", onContextMenu);
  };
}

/**
 * AudioWorklet PCM ring bounded at WASM's `maxQueuedFrames`. Plays through
 * a realtime AudioContext; `offline` renders 100 ms into an
 * OfflineAudioContext instead — for headless smoke runs, where there is no
 * output device to prove anything with.
 */
export async function createAudioRing({ offline = false, maxQueuedFrames } = {}) {
  let ctx;
  if (offline) {
    if (typeof OfflineAudioContext !== "function") {
      throw new Error("OfflineAudioContext unavailable");
    }
    ctx = new OfflineAudioContext(2, 4_800, 48_000);
  } else {
    const Ctx = globalThis.AudioContext || globalThis.webkitAudioContext;
    if (!Ctx) throw new Error("AudioContext unavailable");
    ctx = new Ctx({ sampleRate: 48_000, latencyHint: "interactive" });
    if (ctx.state === "suspended") {
      // Autoplay policy may hold resume() until a user gesture; never wait
      // on it — the ring still loads and buffers.
      ctx.resume().catch(() => {});
    }
  }
  await ctx.audioWorklet.addModule("./audio-ring-worklet.js");
  const node = new AudioWorkletNode(ctx, "lyte-audio-ring", {
    numberOfInputs: 0,
    numberOfOutputs: 1,
    outputChannelCount: [2],
    processorOptions: { maxQueuedFrames },
  });
  node.connect(ctx.destination);
  let framesPushed = 0;
  return {
    mode: offline ? "offline" : "realtime",
    /** Takes ownership of an interleaved stereo Float32Array (transferred). */
    pushPcm(interleaved) {
      framesPushed += interleaved.length / 2;
      node.port.postMessage({ pcm: interleaved }, [interleaved.buffer]);
    },
    framesPushed: () => framesPushed,
    renderOffline: () => (offline ? ctx.startRendering() : Promise.resolve(null)),
    /** The ring's own counters (realtime only: an offline one has ended). */
    stats: () =>
      new Promise((resolve) => {
        node.port.onmessage = (event) => resolve(event.data);
        node.port.postMessage({ type: "stats" });
      }),
    async close() {
      node.disconnect();
      if (!offline) await ctx.close().catch(() => {});
    },
  };
}

/** Frames of a rendered AudioBuffer carrying any non-zero sample. */
function audibleFrames(buffer) {
  if (!buffer) return 0;
  const left = buffer.getChannelData(0);
  let frames = 0;
  for (let i = 0; i < left.length; i++) if (left[i] !== 0) frames += 1;
  return frames;
}

/** WebCodecs Opus decode → interleaved stereo Float32. */
export async function createOpusDecoder(onPcm) {
  if (typeof AudioDecoder !== "function") {
    return { ok: false, detail: "AudioDecoder API unavailable" };
  }
  const config = { codec: "opus", sampleRate: 48_000, numberOfChannels: 2 };
  try {
    if (!(await AudioDecoder.isConfigSupported(config)).supported) {
      return { ok: false, detail: "Opus AudioDecoder config unsupported" };
    }
  } catch (error) {
    return { ok: false, detail: `isConfigSupported: ${error?.message || error}` };
  }
  let error = null;
  let outputs = 0;
  const decoder = new AudioDecoder({
    output: (audioData) => {
      try {
        const frames = audioData.numberOfFrames;
        const interleaved = new Float32Array(frames * 2);
        if (audioData.numberOfChannels === 2 && audioData.format === "f32") {
          audioData.copyTo(interleaved, { planeIndex: 0 });
        } else if (audioData.numberOfChannels === 2) {
          const left = new Float32Array(frames);
          const right = new Float32Array(frames);
          audioData.copyTo(left, { planeIndex: 0, format: "f32-planar" });
          audioData.copyTo(right, { planeIndex: 1, format: "f32-planar" });
          for (let i = 0; i < frames; i++) {
            interleaved[i * 2] = left[i];
            interleaved[i * 2 + 1] = right[i];
          }
        } else {
          const mono = new Float32Array(frames);
          audioData.copyTo(mono, { planeIndex: 0, format: "f32-planar" });
          for (let i = 0; i < frames; i++) {
            interleaved[i * 2] = mono[i];
            interleaved[i * 2 + 1] = mono[i];
          }
        }
        outputs += 1;
        onPcm(interleaved);
      } finally {
        audioData.close();
      }
    },
    error: (err) => {
      error = err;
    },
  });
  decoder.configure(config);
  return {
    ok: true,
    detail: "codec=opus 48kHz stereo",
    decode(bytes, timestampUs) {
      if (error) throw error;
      decoder.decode(
        new EncodedAudioChunk({
          type: "key",
          timestamp: timestampUs,
          data: bytes,
          transfer: [bytes.buffer],
        })
      );
    },
    outputs: () => outputs,
    close() {
      if (decoder.state !== "closed") decoder.close();
    },
  };
}

/**
 * Drives sealed input, clipboard and audio against an open, ready session.
 * `pump` is the SessionPump; `offlineAudio` selects the smoke audio path.
 */
export async function runInteractionProofs({ pump, offlineAudio = false, timeoutMs = 12_000 }) {
  const bridge = pump.bridge;
  const lines = [];
  const note = (line) => lines.push(line);
  const stats = () => bridge.interactionStats();

  // Load the worklet while the input and clipboard legs run.
  let audioRing = null;
  let ringError = null;
  const ringReady = createAudioRing({
    offline: offlineAudio,
    maxQueuedFrames: bridge.audioRingCeilingFrames,
  }).then(
    (ring) => (audioRing = ring),
    (error) => (ringError = error)
  );

  // Input: a few events, then wait for the host's InputEcho.
  for (const [kind, ...args] of [
    ["pointerMotionAbsolute", 100.5, 200.25],
    ["pointerButton", 272, true],
    ["pointerButton", 272, false],
    ["keyKeycode", evdevKeyForCode("KeyA"), true],
    ["keyKeycode", evdevKeyForCode("KeyA"), false],
  ]) {
    await pump.send(bridge.controlSendInput(kind, nowMicros(), ...args));
  }
  const inputDeadline = Date.now() + timeoutMs;
  while (Date.now() < inputDeadline && !pump.failed && stats().inputEchoes < 3) {
    await pump.turn(10);
  }
  const { inputsSent, inputEchoes } = stats();
  note(
    inputEchoes >= 3 && inputsSent >= 3
      ? `PASS  session-input/echo — sent ${inputsSent} InputEvents, ${inputEchoes} echo tuples (sealed CTRL; peer has no OS inject)`
      : `FAIL  session-input/echo — sent=${inputsSent} echoes=${inputEchoes} want≥3`
  );

  // Clipboard: capability-gated set → the peer's announce.
  const clipText = "lyte-b6-clipboard";
  await pump.send(bridge.controlClipboardSet(clipText, nowMicros()));
  const clipDeadline = Date.now() + timeoutMs;
  while (Date.now() < clipDeadline && !pump.failed && !stats().clipboardReceived) {
    await pump.turn(10);
  }
  const { clipboardReceived, lastClipboardText } = stats();
  note(
    clipboardReceived >= 1 && lastClipboardText
      ? `PASS  clipboard/text-roundtrip — set + announce (${JSON.stringify(lastClipboardText)}) over sealed CTRL (in-memory peer; not Wayland OS clipboard)`
      : `FAIL  clipboard/text-roundtrip — received=${clipboardReceived}`
  );

  // Audio: depacketize sealed Opus → WebCodecs → AudioWorklet. Keep pumping
  // while the worklet loads: unanswered beacons freeze the peer.
  const workletDeadline = Date.now() + 4_000;
  while (Date.now() < workletDeadline && !audioRing && !ringError) {
    await pump.turn(0);
    await Promise.race([ringReady, sleep(15)]);
  }
  let pcmFrames = 0;
  let opus = null;
  if (audioRing) {
    opus = await createOpusDecoder((pcm) => {
      pcmFrames += pcm.length / 2;
      audioRing.pushPcm(pcm);
    });
  } else {
    note(`FAIL  audio-worklet/ring — ${ringError?.message || "AudioWorklet setup timed out"}`);
  }
  const audioDeadline = Date.now() + Math.min(timeoutMs, 8_000);
  while (Date.now() < audioDeadline && !pump.failed) {
    await pump.turn(5);
    for (let packet; opus?.ok && (packet = bridge.audioPopPacket()); ) {
      try {
        opus.decode(packet.bytes, packet.captureMicroseconds);
      } catch (error) {
        note(`FAIL  audio/webcodecs — ${error?.message || error}`);
        opus = null;
      }
    }
    if (stats().audioAssembled >= 8 && (pcmFrames >= 480 || !opus?.ok)) break;
  }
  const { audioAssembled } = stats();
  note(
    audioAssembled >= 8
      ? `PASS  audio/depacketize — ${audioAssembled} Opus packets from sealed chan-1`
      : `FAIL  audio/depacketize — assembled=${audioAssembled} want≥8`
  );
  if (audioRing) {
    note(
      opus?.ok && pcmFrames > 0
        ? `PASS  audio/webcodecs — ${opus.detail} → ${pcmFrames} PCM frames`
        : `FAIL  audio/webcodecs — ${opus?.detail || "decoder produced no PCM"}`
    );
    const played = await Promise.race([
      audioRing.mode === "offline"
        ? audioRing.renderOffline().then(audibleFrames)
        : audioRing.stats().then((stats) => stats.framesPlayed),
      sleep(2_000).then(() => 0),
    ]).catch(() => 0);
    note(
      played > 0
        ? `PASS  audio-worklet/ring — AudioWorklet (${audioRing.mode}) played ${played} ` +
            `non-silent frames of ${audioRing.framesPushed()} pushed`
        : `FAIL  audio-worklet/ring — AudioWorklet (${audioRing.mode}) played nothing ` +
            `of ${audioRing.framesPushed()} pushed`
    );
  }
  opus?.close?.();
  if (audioRing) await Promise.race([audioRing.close(), sleep(500)]).catch(() => {});

  const passed = lines.length > 0 && lines.every((line) => line.startsWith("PASS"));
  return { passed, lines };
}
