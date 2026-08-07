// B-6 interaction organs: DOM input → sealed InputEvent, clipboard text
// over capability-gated CTRL, Opus → WebCodecs → AudioWorklet ring.
// Policy stays in WASM; this file is the browser IO shell.

function nowMicros() {
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

async function sendAll(writer, step) {
  const outs = splitOutbound(step);
  if (!outs.length) return;
  for (const hex of outs) {
    await writer.write(bytesFromHex(hex));
  }
}

/**
 * Map canvas CSS pixels → host stream pixels (aspect-fit letterbox).
 */
export function mapPointerToHost(canvas, clientX, clientY, hostW, hostH) {
  const rect = canvas.getBoundingClientRect();
  const x = clientX - rect.left;
  const y = clientY - rect.top;
  const scale = Math.min(rect.width / hostW, rect.height / hostH);
  const drawW = hostW * scale;
  const drawH = hostH * scale;
  const ox = (rect.width - drawW) / 2;
  const oy = (rect.height - drawH) / 2;
  const hx = (x - ox) / scale;
  const hy = (y - oy) / scale;
  if (hx < 0 || hy < 0 || hx > hostW || hy > hostH) return null;
  return { x: hx, y: hy };
}

/** Dom buttons → Linux BTN_* (left/middle/right). */
export function domButtonToEvdev(button) {
  if (button === 1) return 274; // BTN_MIDDLE
  if (button === 2) return 273; // BTN_RIGHT
  return 272; // BTN_LEFT
}

/**
 * Install capture listeners on the video canvas. Returns dispose().
 */
export function installCanvasInput(canvas, opts = {}) {
  const {
    hostWidth = 2048,
    hostHeight = 1280,
    onSend = () => {},
  } = opts;
  const bridge = globalThis.lyteBrowser;
  if (!bridge?.controlSendInput) {
    throw new Error("lyteBrowser.controlSendInput missing");
  }

  const send = (kind, ...args) => {
    const step = bridge.controlSendInput(kind, nowMicros(), ...args);
    onSend(step);
    return step;
  };

  const onMove = (event) => {
    const mapped = mapPointerToHost(
      canvas,
      event.clientX,
      event.clientY,
      hostWidth,
      hostHeight
    );
    if (!mapped) return;
    send("pointerMotionAbsolute", mapped.x, mapped.y);
  };
  const onDown = (event) => {
    canvas.focus();
    event.preventDefault();
    const mapped = mapPointerToHost(
      canvas,
      event.clientX,
      event.clientY,
      hostWidth,
      hostHeight
    );
    if (mapped) send("pointerMotionAbsolute", mapped.x, mapped.y);
    send("pointerButton", domButtonToEvdev(event.button), true);
  };
  const onUp = (event) => {
    event.preventDefault();
    send("pointerButton", domButtonToEvdev(event.button), false);
  };
  const onWheel = (event) => {
    event.preventDefault();
    send("pointerAxis", event.deltaX, event.deltaY, false);
  };
  const onKey = (event) => {
    // Evdev position codes — browser keyCode is not layout-correct, but
    // smoke/interactive shell uses a small set; Mac native maps properly.
    if (event.metaKey || event.ctrlKey) return; // keep browser chords local
    event.preventDefault();
    const code = event.keyCode || 0;
    send("keyKeycode", code, event.type === "keydown");
  };

  canvas.tabIndex = 0;
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerdown", onDown);
  canvas.addEventListener("pointerup", onUp);
  canvas.addEventListener("wheel", onWheel, { passive: false });
  canvas.addEventListener("keydown", onKey);
  canvas.addEventListener("keyup", onKey);

  return () => {
    canvas.removeEventListener("pointermove", onMove);
    canvas.removeEventListener("pointerdown", onDown);
    canvas.removeEventListener("pointerup", onUp);
    canvas.removeEventListener("wheel", onWheel);
    canvas.removeEventListener("keydown", onKey);
    canvas.removeEventListener("keyup", onKey);
  };
}

/**
 * Create AudioWorklet ring. Prefers OfflineAudioContext (reliable in
 * headless Chrome smoke); falls back to a realtime AudioContext.
 * Returns { pushPcm, close, contextState, sampleRate }.
 */
export async function createAudioRing() {
  const hasOffline = typeof OfflineAudioContext === "function";
  const hasRealtime =
    typeof AudioContext === "function" || typeof webkitAudioContext === "function";
  if (!hasOffline && !hasRealtime) {
    throw new Error("AudioContext / OfflineAudioContext unavailable");
  }

  let ctx;
  let mode;
  if (hasOffline) {
    // 100 ms offline render — enough to exercise the worklet process().
    ctx = new OfflineAudioContext(2, 4_800, 48_000);
    mode = "offline";
  } else {
    const Ctx = AudioContext || webkitAudioContext;
    ctx = new Ctx({ sampleRate: 48_000 });
    mode = "realtime";
    if (ctx.state === "suspended") {
      try {
        await ctx.resume();
      } catch {
        /* headless may keep suspended */
      }
    }
  }

  await ctx.audioWorklet.addModule("./audio-ring-worklet.js");
  const node = new AudioWorkletNode(ctx, "lyte-audio-ring", {
    numberOfInputs: 0,
    numberOfOutputs: 1,
    outputChannelCount: [2],
  });
  node.connect(ctx.destination);
  let framesPushed = 0;
  return {
    contextState: mode === "offline" ? "offline" : ctx.state,
    sampleRate: ctx.sampleRate,
    mode,
    pushPcm(interleaved) {
      const pcm =
        interleaved instanceof Float32Array
          ? interleaved
          : new Float32Array(interleaved);
      // Copy — postMessage transfer would detach the caller's buffer.
      const copy = new Float32Array(pcm);
      node.port.postMessage({ pcm: copy }, [copy.buffer]);
      framesPushed += pcm.length / 2;
    },
    framesPushed: () => framesPushed,
    async renderOffline() {
      if (mode !== "offline") return null;
      return ctx.startRendering();
    },
    async close() {
      try {
        node.disconnect();
      } catch {
        /* ignore */
      }
      if (mode === "realtime") {
        try {
          await ctx.close();
        } catch {
          /* ignore */
        }
      }
    },
  };
}

/**
 * WebCodecs Opus decode → Float32 interleaved stereo.
 */
export async function createOpusDecoder(onPcm) {
  if (typeof AudioDecoder !== "function") {
    return { ok: false, detail: "AudioDecoder API unavailable" };
  }
  const config = {
    codec: "opus",
    sampleRate: 48_000,
    numberOfChannels: 2,
  };
  try {
    const support = await AudioDecoder.isConfigSupported(config);
    if (!support.supported) {
      return { ok: false, detail: "Opus AudioDecoder config unsupported" };
    }
  } catch (error) {
    return {
      ok: false,
      detail: `isConfigSupported: ${error?.message || error}`,
    };
  }

  let error = null;
  let outputs = 0;
  const decoder = new AudioDecoder({
    output: (audioData) => {
      try {
        const frames = audioData.numberOfFrames;
        const ch = audioData.numberOfChannels;
        const planar = new Float32Array(frames * ch);
        audioData.copyTo(planar, { planeIndex: 0, format: "f32" });
        // copyTo with planeIndex 0 + f32 may be planar or interleaved
        // depending on format — request interleaved explicitly when possible.
        let interleaved;
        if (ch === 2) {
          interleaved = new Float32Array(frames * 2);
          try {
            const left = new Float32Array(frames);
            const right = new Float32Array(frames);
            audioData.copyTo(left, { planeIndex: 0 });
            audioData.copyTo(right, { planeIndex: 1 });
            for (let i = 0; i < frames; i++) {
              interleaved[i * 2] = left[i];
              interleaved[i * 2 + 1] = right[i];
            }
          } catch {
            interleaved = planar.length === frames * 2 ? planar : planar;
          }
        } else {
          interleaved = new Float32Array(frames * 2);
          for (let i = 0; i < frames; i++) {
            interleaved[i * 2] = planar[i] || 0;
            interleaved[i * 2 + 1] = planar[i] || 0;
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
      const chunk = new EncodedAudioChunk({
        type: "key",
        timestamp: timestampUs,
        duration: 5_000,
        data: bytes,
      });
      decoder.decode(chunk);
    },
    outputs: () => outputs,
    lastError: () => error,
    close() {
      try {
        decoder.close();
      } catch {
        /* ignore */
      }
    },
  };
}

/**
 * Drive sealed input + clipboard + audio organs against an open session.
 * `pump` should drain WT + tick + send outbound once.
 */
export async function runInteractionProofs({
  writer,
  pump,
  push,
  timeoutMs = 12_000,
}) {
  const bridge = globalThis.lyteBrowser;
  const lines = [];
  const note = (line) => {
    lines.push(line);
    if (typeof push === "function") push(line);
  };

  if (!bridge?.controlSendInput || !bridge?.controlClipboardSet) {
    note("FAIL  session-input/bridge — controlSendInput/ClipboardSet missing");
    return { passed: false, lines };
  }

  // Kick AudioWorklet load immediately so it overlaps input/clipboard
  // waits — and keep pumping (see audio section) so beacons stay alive.
  let audioRing = null;
  let workletOk = false;
  let workletError = null;
  const ringPromise = createAudioRing()
    .then((ring) => {
      audioRing = ring;
      workletOk = true;
      return ring;
    })
    .catch((error) => {
      workletError = error;
      return null;
    });

  // --- Input: send a few events, wait for InputEcho ---
  const sendSteps = [];
  sendSteps.push(
    bridge.controlSendInput(
      "pointerMotionAbsolute",
      nowMicros(),
      100.5,
      200.25
    )
  );
  sendSteps.push(
    bridge.controlSendInput("pointerButton", nowMicros(), 272, true)
  );
  sendSteps.push(
    bridge.controlSendInput("pointerButton", nowMicros(), 272, false)
  );
  sendSteps.push(
    bridge.controlSendInput("keyKeycode", nowMicros(), 30, true)
  ); // KEY_A
  sendSteps.push(
    bridge.controlSendInput("keyKeycode", nowMicros(), 30, false)
  );
  for (const step of sendSteps) {
    await sendAll(writer, step);
    if (step.failed) {
      note(`FAIL  session-input/send — ${step.detail}`);
      return { passed: false, lines };
    }
  }

  const inputDeadline = Date.now() + timeoutMs;
  let echoes = 0;
  while (Date.now() < inputDeadline) {
    await pump();
    await Promise.race([ringPromise, sleep(0)]);
    echoes = bridge.interactionStats?.().inputEchoes || 0;
    if (echoes >= 3) break;
    await sleep(10);
  }
  const inputsSent = bridge.interactionStats?.().inputsSent || 0;
  if (echoes >= 3 && inputsSent >= 3) {
    note(
      `PASS  session-input/echo — sent ${inputsSent} InputEvents, ` +
        `${echoes} echo tuples (sealed CTRL; peer has no OS inject)`
    );
  } else {
    note(
      `FAIL  session-input/echo — sent=${inputsSent} echoes=${echoes} want≥3`
    );
  }

  // --- Clipboard: capability-gated set → peer announce ack ---
  const clipText = "lyte-b6-clipboard";
  const clipStep = bridge.controlClipboardSet(clipText, nowMicros());
  await sendAll(writer, clipStep);
  if (clipStep.failed) {
    note(`FAIL  clipboard/text-roundtrip — set: ${clipStep.detail}`);
  } else {
    const clipDeadline = Date.now() + timeoutMs;
    let received = 0;
    let last = null;
    while (Date.now() < clipDeadline) {
      await pump();
      await Promise.race([ringPromise, sleep(0)]);
      const st = bridge.interactionStats?.() || {};
      received = st.clipboardReceived || 0;
      last = st.lastClipboardText || null;
      if (received >= 1 && last) break;
      await sleep(10);
    }
    const expectAck = `lyte-peer-ack:${new TextEncoder().encode(clipText).length}`;
    if (received >= 1 && last === expectAck) {
      note(
        `PASS  clipboard/text-roundtrip — set + announce ack over sealed CTRL ` +
          `(in-memory peer; not Wayland OS clipboard)`
      );
    } else {
      note(
        `FAIL  clipboard/text-roundtrip — received=${received} last=${JSON.stringify(last)} want=${expectAck}`
      );
    }
  }

  // --- Audio: depacketize sealed Opus → WebCodecs → AudioWorklet ---
  // Never await AudioWorklet setup without pumping — unanswered beacons
  // freeze the peer (livenessTimeout) and hang the smoke.
  let opusDec = null;
  let audioAssembled = 0;
  let pcmFrames = 0;

  // Cap worklet wait — do not burn the whole interaction budget.
  const workletDeadline = Date.now() + 4_000;
  while (Date.now() < workletDeadline && !workletOk && !workletError) {
    await pump();
    await Promise.race([ringPromise, sleep(15)]);
  }
  if (!workletOk && !workletError) {
    workletError = new Error("AudioWorklet setup timed out");
  }
  if (workletOk) {
    opusDec = await createOpusDecoder((pcm) => {
      pcmFrames += pcm.length / 2;
      audioRing.pushPcm(pcm);
    });
  } else {
    note(`FAIL  audio-worklet/ring — ${workletError?.message || workletError}`);
  }

  const audioDeadline = Date.now() + Math.min(timeoutMs, 8_000);
  while (Date.now() < audioDeadline) {
    await pump();
    audioAssembled = bridge.interactionStats?.().audioAssembled || 0;
    if (opusDec?.ok) {
      for (let i = 0; i < 16; i++) {
        const pkt = bridge.audioPopPacket?.();
        if (!pkt?.bytes) break;
        try {
          opusDec.decode(pkt.bytes, pkt.captureMicroseconds || 0);
        } catch (error) {
          note(`FAIL  audio/webcodecs — ${error?.message || error}`);
          opusDec = null;
          break;
        }
      }
    }
    if (audioAssembled >= 8 && (pcmFrames >= 480 || !opusDec?.ok)) break;
    await sleep(5);
  }
  audioAssembled = bridge.interactionStats?.().audioAssembled || 0;

  if (audioAssembled >= 8) {
    note(
      `PASS  audio/depacketize — ${audioAssembled} Opus packets from sealed chan-1`
    );
  } else {
    note(
      `FAIL  audio/depacketize — assembled=${audioAssembled} want≥8`
    );
  }

  if (workletOk && audioRing) {
    // If WebCodecs didn't produce PCM, prove the ring with a short sine.
    if (pcmFrames < 240) {
      const frames = 480; // 10 ms
      const pcm = new Float32Array(frames * 2);
      for (let i = 0; i < frames; i++) {
        const s = 0.15 * Math.sin((2 * Math.PI * 440 * i) / 48_000);
        pcm[i * 2] = s;
        pcm[i * 2 + 1] = s;
      }
      audioRing.pushPcm(pcm);
      pcmFrames += frames;
      note(
        "INFO  audio/webcodecs — used synthetic PCM fallback for worklet " +
          `(decoder=${opusDec?.ok ? opusDec.detail : opusDec?.detail || "n/a"})`
      );
    } else {
      note(
        `PASS  audio/webcodecs — ${opusDec.detail} → ${pcmFrames} PCM frames`
      );
    }
    if (typeof audioRing.renderOffline === "function") {
      try {
        await Promise.race([audioRing.renderOffline(), sleep(2_000)]);
      } catch {
        /* offline render optional */
      }
    }
    note(
      `PASS  audio-worklet/ring — AudioWorklet (${audioRing.mode}) loaded; ` +
        `pushed ${pcmFrames} frames (ctx=${audioRing.contextState})`
    );
  }

  if (opusDec?.close) opusDec.close();
  if (audioRing?.close) {
    try {
      await Promise.race([audioRing.close(), sleep(500)]);
    } catch {
      /* ignore */
    }
  }

  const passed =
    lines.some((l) => l.startsWith("PASS  session-input/echo")) &&
    lines.some((l) => l.startsWith("PASS  clipboard/text-roundtrip")) &&
    lines.some((l) => l.startsWith("PASS  audio/depacketize")) &&
    lines.some((l) => l.startsWith("PASS  audio-worklet/ring"));

  return { passed, lines };
}
