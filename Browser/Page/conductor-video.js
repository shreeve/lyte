// B-5/B-6: sealed corpus video over WT → WASM assemble + Conductor →
// WebCodecs → WebGPU, then sealed input/clipboard + Opus → AudioWorklet.
// Presentation times come only from LyteCore VideoBeatConductor; rAF never
// invents frames. Not live Direct Eye — lyte-control-peer --emit-corpus.

import { loadSidecarMeta } from "./webtransport-carrier.js";
import { loadControlPeerMeta } from "./control-session.js";
import { runInteractionProofs } from "./interaction.js";

const BEAT_US = 16_667;
const MIN_PRESENT = 5;
const MIN_ASSEMBLE = 8;

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

function parseScheduledLines(step) {
  const raw = step?.scheduledLines || "";
  if (!raw) return [];
  return raw.split("\n").filter(Boolean).map((line) => {
    const p = line.split(",");
    return {
      frameNumber: Number(p[0]),
      presentationMicroseconds: Number(p[1]),
      cueMicroseconds: Number(p[2]),
      pathDelayMicroseconds: Number(p[3]),
      reserveMicroseconds: Number(p[4]),
      latenessMicroseconds: Number(p[5]),
      isRandomAccess: p[6] === "1",
      shouldPresent: p[7] === "1",
      annexBByteCount: Number(p[8]),
      sourceCaptureMicroseconds: Number(p[9]),
      arrivalMicroseconds: Number(p[10]),
    };
  });
}

async function sendAll(writer, step) {
  // Hot path: video shards usually have empty outbound. Do not `await` an
  // empty loop — that still yields a microtask and lets FEC shards pile up
  // unread on the WT reader (→ fecImpossible).
  const outs = splitOutbound(step);
  if (!outs.length) return;
  for (const hex of outs) {
    await writer.write(bytesFromHex(hex));
  }
}

async function pickHevcConfig() {
  if (typeof VideoDecoder !== "function") {
    return { ok: false, detail: "VideoDecoder API unavailable" };
  }
  const candidates = [
    { codec: "hev1.1.6.L150.B0" },
    { codec: "hev1.1.6.L120.B0" },
    { codec: "hev1.1.6.L93.B0" },
    { codec: "hvc1.1.6.L150.B0" },
  ];
  for (const partial of candidates) {
    const config = {
      codec: partial.codec,
      codedWidth: 2048,
      codedHeight: 1280,
      hardwareAcceleration: "prefer-hardware",
    };
    try {
      const { supported, config: supportedConfig } =
        await VideoDecoder.isConfigSupported(config);
      if (supported) {
        return {
          ok: true,
          config: supportedConfig || config,
          detail: `codec=${config.codec}`,
        };
      }
    } catch (error) {
      return {
        ok: false,
        detail: `isConfigSupported threw: ${error?.message || error}`,
      };
    }
  }
  return {
    ok: false,
    detail:
      "no HEVC VideoDecoder config supported (Chrome needs hardware HEVC)",
  };
}

async function createPresenter(canvas) {
  if (!navigator.gpu) {
    throw new Error("WebGPU (navigator.gpu) unavailable");
  }
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error("WebGPU adapter request returned null");
  const device = await adapter.requestDevice();
  const context = canvas.getContext("webgpu");
  if (!context) throw new Error("canvas.getContext('webgpu') failed");
  const format = navigator.gpu.getPreferredCanvasFormat();

  const shaderModule = device.createShaderModule({
    code: `
struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}
@vertex
fn vsMain(@builtin(vertex_index) vi: u32) -> VSOut {
  var pos = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f( 3.0, -1.0),
    vec2f(-1.0,  3.0)
  );
  var uv = array<vec2f, 3>(
    vec2f(0.0, 1.0),
    vec2f(2.0, 1.0),
    vec2f(0.0, -1.0)
  );
  var out: VSOut;
  out.pos = vec4f(pos[vi], 0.0, 1.0);
  out.uv = uv[vi];
  return out;
}
@group(0) @binding(0) var frameSampler: sampler;
@group(0) @binding(1) var frameTex: texture_external;
@fragment
fn fsMain(input: VSOut) -> @location(0) vec4f {
  return textureSampleBaseClampToEdge(frameTex, frameSampler, input.uv);
}
`,
  });
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shaderModule, entryPoint: "vsMain" },
    fragment: {
      module: shaderModule,
      entryPoint: "fsMain",
      targets: [{ format }],
    },
    primitive: { topology: "triangle-list" },
  });
  const sampler = device.createSampler({
    magFilter: "linear",
    minFilter: "linear",
  });
  let configured = false;

  return {
    adapter:
      adapter.info?.description || adapter.info?.vendor || "webgpu",
    format,
    // Sync submit — never await GPU; awaiting stalls the WT FEC drain.
    present(frame) {
      const width = Math.max(1, frame.displayWidth || frame.codedWidth || 2048);
      const height = Math.max(
        1,
        frame.displayHeight || frame.codedHeight || 1280
      );
      const presentW = Math.min(960, width);
      const presentH = Math.round((presentW * height) / width);
      if (!configured || canvas.width !== presentW || canvas.height !== presentH) {
        canvas.width = presentW;
        canvas.height = presentH;
        context.configure({ device, format, alphaMode: "opaque" });
        configured = true;
      }
      const externalTexture = device.importExternalTexture({ source: frame });
      const bindGroup = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: sampler },
          { binding: 1, resource: externalTexture },
        ],
      });
      const colorView = context.getCurrentTexture().createView();
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: colorView,
            clearValue: { r: 0.05, g: 0.05, b: 0.06, a: 1 },
            loadOp: "clear",
            storeOp: "store",
          },
        ],
      });
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, bindGroup);
      pass.draw(3);
      pass.end();
      device.queue.submit([encoder.finish()]);
      return { presentWidth: presentW, presentHeight: presentH };
    },
  };
}

/**
 * Control session + Conductor-driven multi-frame video over the same WT.
 */
export async function runConductorVideoProof(opts = {}) {
  const {
    sidecar,
    hostStaticPublicKeyHex,
    pin,
    canvas,
    timeoutMs = 90_000,
    minPresent = MIN_PRESENT,
    minAssemble = MIN_ASSEMBLE,
  } = opts;
  const lines = [];
  const push = (line) => lines.push(line);
  const bridge = globalThis.lyteBrowser;
  if (
    !bridge?.controlOpen ||
    !bridge?.mediaPopDue ||
    !(bridge?.mediaAnnexBBytes || bridge?.mediaAnnexBHex)
  ) {
    push("FAIL  conductor-video/bridge — media Conductor APIs missing");
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }
  if (typeof WebTransport !== "function") {
    push("FAIL  conductor-video/carrier — WebTransport unavailable");
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  const opened = bridge.controlOpen(hostStaticPublicKeyHex, pin);
  if (!opened?.ok) {
    push(`FAIL  conductor-video/control — open: ${opened?.error || "?"}`);
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  const picked = await pickHevcConfig();
  if (!picked.ok) {
    push(`FAIL  conductor-video/webcodecs — ${picked.detail}`);
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  let presenter;
  try {
    presenter = await createPresenter(canvas);
  } catch (error) {
    push(`FAIL  conductor-video/webgpu — ${error?.message || error}`);
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  const hash = bytesFromHex(sidecar.hashHex);
  const wt = new WebTransport(sidecar.url, {
    serverCertificateHashes: [{ algorithm: "sha-256", value: hash }],
  });
  await wt.ready;
  const writer = wt.datagrams.writable.getWriter();
  const reader = wt.datagrams.readable.getReader();

  const infoLines = [];
  const pushEvents = (step) => {
    // Bridge drains notes per step — append, don't dedupe-scan (O(n²)).
    for (const line of (step?.events || "").split("\n").filter(Boolean)) {
      infoLines.push(line);
    }
  };

  let begin = bridge.controlBegin(nowMicros());
  pushEvents(begin);
  await sendAll(writer, begin);

  const deadline = Date.now() + timeoutMs;
  let ready = false;
  let failed = false;
  let pendingRead = reader.read();
  const decodeQueue = []; // meta only — pull Annex-B just-in-time
  /** @type {Map<number, VideoFrame>} */
  const decodedByPts = new Map();
  const presentedPts = [];
  let classifyOk = false;
  let firstCodecLine = null;
  let decoderError = null;
  let decodeStopped = false;

  const decoder = new VideoDecoder({
    output: (frame) => {
      decodedByPts.set(frame.timestamp, frame);
    },
    error: (err) => {
      decoderError = err;
      decodeStopped = true;
    },
  });
  decoder.configure(picked.config);

  const loadAnnexB = (frameNumber) => {
    if (typeof bridge.mediaAnnexBBytes === "function") {
      const bytes = bridge.mediaAnnexBBytes(frameNumber);
      if (bytes && bytes.length != null) return new Uint8Array(bytes);
    }
    const hex = bridge.mediaAnnexBHex?.(frameNumber);
    if (!hex) return null;
    return bytesFromHex(hex);
  };

  const ingestScheduled = (step) => {
    for (const meta of parseScheduledLines(step)) {
      decodeQueue.push(meta);
    }
  };

  const pumpDecode = () => {
    // At most one AU per tick so WT ingress stays ahead of hex/copy work.
    if (decodeStopped || !decodeQueue.length) return;
    if (decoder.decodeQueueSize > 2) return;
    const meta = decodeQueue[0];
    const annexB = loadAnnexB(meta.frameNumber);
    if (!annexB) return; // keep meta — Annex-B may still be in WASM
    decodeQueue.shift();
    if (!classifyOk && meta.isRandomAccess) {
      const c = bridge.classifyAnnexBBytes
        ? bridge.classifyAnnexBBytes(annexB)
        : bridge.classifyAnnexBHex?.(hexFromBytes(annexB));
      if (c?.ok && c.frameShaped && c.containsIrap) {
        classifyOk = true;
        push(
          `PASS  frame-present/classify — ${c.summary} (${c.byteCount} B)`
        );
      }
    }
    const chunk = new EncodedVideoChunk({
      type: meta.isRandomAccess ? "key" : "delta",
      timestamp: meta.presentationMicroseconds,
      duration: BEAT_US,
      data: annexB,
    });
    try {
      decoder.decode(chunk);
    } catch (error) {
      decoderError = error;
      decodeStopped = true;
      return;
    }
    if (!firstCodecLine) {
      firstCodecLine =
        `PASS  frame-present/webcodecs — ${picked.detail} ` +
        `ts=${meta.presentationMicroseconds}µs (Conductor PTS)`;
      push(firstCodecLine);
    }
  };

  let pendingDue = null;

  const paintDue = (due, frame) => {
    try {
      const meta = presenter.present(frame);
      bridge.mediaNotePresented(due.frameNumber);
      presentedPts.push(due.presentationMicroseconds);
      if (presentedPts.length === 1) {
        push(
          `PASS  frame-present/webgpu — importExternalTexture → canvas ` +
            `${meta.presentWidth}x${meta.presentHeight} (${presenter.format})`
        );
      }
      return true;
    } finally {
      frame.close();
    }
  };

  const pumpPresent = () => {
    // Never pop a second due frame while one is waiting on decode —
    // popDue is destructive and would drop the held part.
    if (pendingDue) return false;
    const due = bridge.mediaPopDue(nowMicros());
    if (!due) return false;
    const pts = due.presentationMicroseconds;
    const frame = decodedByPts.get(pts);
    if (!frame) {
      pendingDue = due;
      return false;
    }
    decodedByPts.delete(pts);
    return paintDue(due, frame);
  };

  const pumpPendingDue = () => {
    if (!pendingDue) return false;
    const pts = pendingDue.presentationMicroseconds;
    const frame = decodedByPts.get(pts);
    if (!frame) return false;
    decodedByPts.delete(pts);
    const due = pendingDue;
    pendingDue = null;
    return paintDue(due, frame);
  };

  let ingestCount = 0;
  const ingestDatagramSync = (value) => {
    // Binary path — hex copies of video shards starve the WT reader and
    // produce fecImpossible under burst. Sync ingest (no await) so a
    // FEC burst drains before we yield to decode/present.
    const bytes =
      value instanceof Uint8Array ? value : new Uint8Array(value);
    ingestCount += 1;
    if (!bridge.controlIngestBytes) {
      return bridge.controlIngest(hexFromBytes(bytes), nowMicros());
    }
    return bridge.controlIngestBytes(bytes, nowMicros());
  };

  const drainBurst = async () => {
    let drained = 0;
    const pendingOutbound = [];
    while (drained < 1024 && Date.now() < deadline && !failed) {
      const raced = await Promise.race([
        pendingRead.then((r) => ({ kind: "datagram", r })),
        sleep(0).then(() => ({ kind: "empty" })),
      ]);
      if (raced.kind === "empty") break;
      pendingRead = reader.read();
      const { value, done } = raced.r;
      if (done) {
        failed = true;
        break;
      }
      if (!value) continue;
      const step = ingestDatagramSync(value);
      pushEvents(step);
      ingestScheduled(step);
      if (step.failed) failed = true;
      if (step.ready) ready = true;
      const outs = splitOutbound(step);
      if (outs.length) pendingOutbound.push(...outs);
      drained += 1;
    }
    for (const hex of pendingOutbound) {
      await writer.write(bytesFromHex(hex));
    }
    return drained;
  };

  // Phase 1 — FEC ingest only (handoff deadline is effectively infinite so
  // parts survive until phase 2). Any decode/present here drops WT shards.
  let lastAssembled = 0;
  let idleAfterReady = 0;
  while (Date.now() < deadline && !failed) {
    let drained = 0;
    for (let i = 0; i < 8 && !failed; i++) {
      const n = await drainBurst();
      drained += n;
      if (!n) break;
    }
    if (failed) break;
    const tick = bridge.controlTick(nowMicros());
    pushEvents(tick);
    ingestScheduled(tick);
    await sendAll(writer, tick);
    if (tick.failed) {
      failed = true;
      break;
    }
    if (tick.ready) ready = true;
    const assembled = bridge.mediaStats?.().assembled || 0;
    if (assembled > lastAssembled) {
      lastAssembled = assembled;
      idleAfterReady = 0;
    } else if (ready && !drained) {
      idleAfterReady += 1;
    }
    if (assembled >= minAssemble && idleAfterReady >= 20) break;
    // Peer finishes ~10 frames in <2s; stop waiting if progress stalled.
    if (ready && idleAfterReady >= 250 && assembled > 0) break;
    if (!drained) await sleep(1);
  }

  // Phase 2 — decode + Conductor present.
  for (
    let i = 0;
    i < 500 && !failed && presentedPts.length < minPresent;
    i++
  ) {
    await drainBurst();
    const tick = bridge.controlTick(nowMicros());
    ingestScheduled(tick);
    await sendAll(writer, tick);
    if (decoderError && presentedPts.length < minPresent) {
      push(
        `FAIL  conductor-video/webcodecs — ${decoderError?.message || decoderError}`
      );
      failed = true;
      break;
    }
    pumpDecode();
    pumpPendingDue();
    pumpPresent();
    await sleep(2);
  }

  // B-6 interaction organs while the session is still ready.
  let interactionPassed = false;
  let interactionLines = [];
  if (ready && !failed) {
    const interactionPump = async () => {
      await drainBurst();
      const tick = bridge.controlTick(nowMicros());
      pushEvents(tick);
      await sendAll(writer, tick);
      if (tick.failed) failed = true;
    };
    try {
      const ix = await runInteractionProofs({
        writer,
        pump: interactionPump,
        push: (line) => interactionLines.push(line),
      });
      interactionPassed = !!ix.passed;
      interactionLines = ix.lines;
    } catch (error) {
      interactionLines = [
        `FAIL  interaction-shell — ${error?.message || error}`,
      ];
      interactionPassed = false;
    }
  }

  let teardownOk = false;
  if (ready && !failed) {
    const tear = bridge.controlTeardown(nowMicros());
    pushEvents(tear);
    await sendAll(writer, tear);
    teardownOk = !!tear.closed || tear.status === "closed";
    for (let i = 0; i < 20; i++) {
      const tick = bridge.controlTick(nowMicros());
      await sendAll(writer, tick);
      const raced = await Promise.race([
        pendingRead.then((r) => ({ kind: "d", r })),
        sleep(15).then(() => ({ kind: "t" })),
      ]);
      if (raced.kind === "d") {
        pendingRead = reader.read();
        if (raced.r.value) {
          const step = ingestDatagramSync(raced.r.value);
          pushEvents(step);
          await sendAll(writer, step);
        }
      }
    }
  }

  try {
    decoder.close();
  } catch {
    /* ignore */
  }
  for (const frame of decodedByPts.values()) {
    try {
      frame.close();
    } catch {
      /* ignore */
    }
  }
  try {
    wt.close({ closeCode: 0, reason: "b6-done" });
  } catch {
    /* ignore */
  }

  const noiseOk = infoLines.some((l) => l.includes("noise: handshake completed"));
  const pairOk = infoLines.some((l) => l.includes("pairing: PAIRED"));
  const capsOk = infoLines.some((l) => l.includes("capabilities: agreed"));
  const clipboardCapOk = infoLines.some((l) =>
    l.includes("clipboardText=true")
  );
  const readyOk = ready && noiseOk && pairOk && capsOk;
  const stats = bridge.mediaStats?.() || {};
  const assembled = stats.assembled || 0;
  const ixStats = bridge.interactionStats?.() || {};

  // Beat-grid: successive presented PTS differ by whole beats (allow +1µs bump).
  let beatOk = presentedPts.length >= 2;
  for (let i = 1; i < presentedPts.length; i++) {
    const delta = presentedPts[i] - presentedPts[i - 1];
    const rem = delta % BEAT_US;
    if (!(rem === 0 || rem === 1 || rem === BEAT_US - 1)) {
      beatOk = false;
      break;
    }
  }

  push(
    readyOk
      ? "PASS  control-session/noise-pair-caps — Noise IK + PIN PAKE + capabilities"
      : "FAIL  control-session/noise-pair-caps — not ready"
  );
  push(
    clipboardCapOk
      ? "PASS  control-session/clipboard-cap — clipboardText negotiated"
      : "FAIL  control-session/clipboard-cap — clipboardText missing from agreement"
  );
  push(
    teardownOk
      ? "PASS  control-session/teardown — typed SessionTeardown sent"
      : "FAIL  control-session/teardown — not closed"
  );
  push(
    assembled >= minAssemble
      ? `PASS  conductor-video/assemble — ${assembled} frames from sealed WT shards`
      : `FAIL  conductor-video/assemble — assembled=${assembled} want≥${minAssemble}`
  );
  push(
    beatOk
      ? `PASS  conductor-video/schedule — Conductor PTS beat-grid (${presentedPts.length} presented)`
      : `FAIL  conductor-video/schedule — PTS not on beat-grid (n=${presentedPts.length})`
  );
  push(
    presentedPts.length >= minPresent
      ? `PASS  conductor-video/present — ${presentedPts.length} frames WebGPU on Conductor PTS`
      : `FAIL  conductor-video/present — presented=${presentedPts.length} want≥${minPresent}`
  );
  if (!classifyOk) {
    push("FAIL  frame-present/classify — no IRAP classified from wire");
  }
  for (const line of interactionLines) push(line);
  push(
    interactionPassed
      ? "PASS  interaction-shell/b6 — input + clipboard + audio organs green"
      : "FAIL  interaction-shell/b6 — see session-input/clipboard/audio lines"
  );

  const passed =
    readyOk &&
    clipboardCapOk &&
    teardownOk &&
    classifyOk &&
    assembled >= minAssemble &&
    beatOk &&
    presentedPts.length >= minPresent &&
    interactionPassed &&
    !failed;

  const meta =
    `B-6 = interactive shell on B-3…B-5 (corpus video + sealed CTRL + Opus tone)\n` +
    `assembled=${assembled} presented=${presentedPts.length} ` +
    `ingestedDatagrams=${ingestCount} ` +
    `pts=[${presentedPts.slice(0, 6).join(",")},…]\n` +
    `inputsSent=${ixStats.inputsSent || 0} inputEchoes=${ixStats.inputEchoes || 0} ` +
    `clipboardSent=${ixStats.clipboardSent || 0} ` +
    `audioAssembled=${ixStats.audioAssembled || 0}\n` +
    `codec=${picked.config.codec} adapter=${presenter.adapter}\n` +
    `deferred: live Direct Eye, OS Wayland clipboard, Safari, daily-driver RD`;

  return {
    passed,
    lines: [
      ...infoLines.map((l) => (l.startsWith("FAIL") ? l : `INFO  ${l}`)),
      ...lines,
    ].join("\n"),
    meta,
    clientStaticPublicKeyHex: opened.clientStaticPublicKeyHex,
    assembled,
    presented: presentedPts.length,
  };
}

export { loadControlPeerMeta, loadSidecarMeta };
