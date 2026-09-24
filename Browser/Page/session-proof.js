// The end-to-end proof the smoke gate and the harness page run: a control
// session (Noise / PIN / capabilities), the peer's sealed corpus video
// through the Conductor to WebCodecs + WebGPU, then input, clipboard and
// Opus audio, then an orderly teardown.
//
// Video runs the product's loop shape: each turn ingests, decodes, and
// presents whatever the Conductor says is due, so presentation is paced by
// the Conductor's clock. The video proofs assert that: presented PTS sit on
// the beat grid, no frame is shown before its PTS, and frames that decoded
// ahead of their beat were held until it (not merely decoded).

import { runInteractionProofs } from "./interaction.js";
import { nowMicros } from "./lyte-io.js";
import { SessionPump } from "./session-pump.js";
import { VideoSink } from "./video-sink.js";

// The corpus is over after this long without a newly assembled frame.
const QUIET_MICROSECONDS = 250_000;
// Stop waiting for more than a partial corpus after this long.
const GIVE_UP_MICROSECONDS = 2_500_000;
// Every scheduled beat has passed this long ago: stop waiting on the decoder.
const DRAIN_LIMIT_MICROSECONDS = 1_000_000;

const ms = (micros) => `${micros >= 0 ? "+" : ""}${(micros / 1000).toFixed(1)}`;
const pacingEntry = (p) => `${p.frameNumber}:${ms(p.decodedAt - p.pts)}/${ms(p.presentedAt - p.pts)}`;

export async function runSessionProof({
  sidecar,
  hostStaticPublicKeyHex,
  pin,
  canvas,
  offlineAudio = false,
  timeoutMs = 90_000,
  minPresent = 5,
  // Frames that must show decode-ahead-then-wait; a slow decoder may make
  // the rest late, which the Conductor still shows, never early.
  minHeld = 3,
  minAssemble = 8,
  onOpen = () => {},
}) {
  const bridge = globalThis.lyteBrowser;
  const lines = [];
  const push = (line) => lines.push(line);
  let pump = null;
  let sink = null;
  let classified = false;
  let interaction = { passed: false, lines: [] };
  let teardownOk = false;
  let lastScheduledPts = 0;
  const beat = bridge.conductorBeatMicroseconds;

  try {
    sink = await VideoSink.open(bridge, canvas);
    sink.onFirstKeyFrame = (bytes) => {
      const c = bridge.classifyAnnexBBytes(bytes);
      if (c?.ok && c.frameShaped && c.containsIrap) {
        classified = true;
        push(`PASS  frame-present/classify — ${c.summary} (${c.byteCount} B)`);
      }
    };
    pump = await SessionPump.open(bridge, sidecar, { hostStaticPublicKeyHex, pin });
    pump.onScheduled = (scheduled) => {
      for (const meta of scheduled) {
        lastScheduledPts = Math.max(lastScheduledPts, meta.presentationMicroseconds);
      }
      sink.enqueue(scheduled);
    };
    onOpen(pump, sink);
    await pump.begin();
    const deadline = Date.now() + timeoutMs;

    // One loop, as a product client runs it: ingest, decode, and present
    // each frame when its Conductor beat comes due.
    let lastAssembled = 0;
    let lastProgressAt = nowMicros();
    while (Date.now() < deadline && !pump.failed && !pump.closed) {
      await pump.turn(2);
      const now = nowMicros();
      const assembled = bridge.mediaStats().assembled;
      if (assembled > lastAssembled) {
        lastAssembled = assembled;
        lastProgressAt = now;
      }
      sink.pumpDecode();
      if (sink.firstDecodedPts != null && !lines.some((l) => l.includes("frame-present/webcodecs"))) {
        push(`PASS  frame-present/webcodecs — ${sink.codecDetail} ts=${sink.firstDecodedPts}µs (Conductor PTS)`);
      }
      if (sink.pumpPresent(now) && sink.stats.presented === 1) {
        push(
          `PASS  frame-present/webgpu — importExternalTexture → canvas ` +
            `${sink.lastPresent.presentWidth}x${sink.lastPresent.presentHeight} (${sink.presenter.format})`
        );
      }
      if (sink.error) {
        push(`FAIL  conductor-video/webcodecs — ${sink.error?.message || sink.error}`);
        break;
      }
      // The corpus is over once it has assembled and gone quiet; the loop
      // then runs until every scheduled beat has passed and the sink has
      // nothing outstanding, bounded in case the decoder withholds output.
      const quietFor = now - lastProgressAt;
      const streamDone =
        pump.ready &&
        ((assembled >= minAssemble && quietFor >= QUIET_MICROSECONDS) ||
          (assembled > 0 && quietFor >= GIVE_UP_MICROSECONDS));
      if (streamDone && now > lastScheduledPts + beat && !sink.busy) break;
      if (streamDone && now > lastScheduledPts + DRAIN_LIMIT_MICROSECONDS) break;
    }

    if (pump.ready) {
      interaction = await runInteractionProofs({ pump, offlineAudio });
    }

    if (pump.ready) {
      await pump.send(bridge.controlTeardown(nowMicros()));
      teardownOk = pump.closed;
      // Linger until the host acknowledged the teardown.
      for (let i = 0; i < 40 && !pump.facts().reliableQuiescent; i++) {
        await pump.turn(15);
      }
    }
  } catch (error) {
    push(`FAIL  session-proof — ${error?.message || error}`);
  } finally {
    sink?.close();
    await pump?.close("proof-done");
  }

  const facts = bridge.controlFacts();
  const stats = bridge.mediaStats();
  const shown = sink?.presentations || [];
  const presentedPts = shown.map((p) => p.pts);
  // Successive presented PTS differ by whole Conductor beats (±1 µs bump).
  let beatOk = presentedPts.length >= 2;
  for (let i = 1; i < presentedPts.length; i++) {
    const rem = (presentedPts[i] - presentedPts[i - 1]) % beat;
    if (!(rem === 0 || rem === 1 || rem === beat - 1)) beatOk = false;
  }
  const early = shown.filter((p) => p.presentedAt < p.pts).length;
  // Paced: decoded before its beat, then held and shown once it came.
  const held = shown.filter((p) => p.decodedAt < p.pts && p.presentedAt >= p.pts).length;
  const lateMs = shown.map((p) => (p.presentedAt - p.pts) / 1000);
  const maxLateMs = lateMs.length ? Math.max(...lateMs) : 0;
  const readyOk = facts.handshakeCompleted && facts.paired && facts.capabilitiesAgreed;

  push(
    readyOk
      ? "PASS  control-session/noise-pair-caps — Noise IK + PIN PAKE + capabilities"
      : `FAIL  control-session/noise-pair-caps — status=${facts.status} ${pump?.failure || ""}`
  );
  push(
    facts.clipboardNegotiated
      ? "PASS  control-session/clipboard-cap — clipboardText negotiated"
      : "FAIL  control-session/clipboard-cap — clipboardText missing from agreement"
  );
  push(
    teardownOk
      ? `PASS  control-session/teardown — typed SessionTeardown sent${facts.reliableQuiescent ? " and acknowledged" : ""}`
      : "FAIL  control-session/teardown — not closed"
  );
  push(
    stats.assembled >= minAssemble
      ? `PASS  conductor-video/assemble — ${stats.assembled} frames from sealed WT shards`
      : `FAIL  conductor-video/assemble — assembled=${stats.assembled} want≥${minAssemble}`
  );
  push(
    beatOk && early === 0
      ? `PASS  conductor-video/schedule — ${shown.length} presented on the Conductor beat grid, none before its PTS`
      : `FAIL  conductor-video/schedule — beatGrid=${beatOk} early=${early} (n=${shown.length})`
  );
  push(
    shown.length >= minPresent && held >= minHeld
      ? `PASS  conductor-video/present — ${shown.length} frames WebGPU at their Conductor PTS ` +
          `(${held} decoded early and held for their beat; latest ${maxLateMs.toFixed(1)} ms past PTS)`
      : `FAIL  conductor-video/present — presented=${shown.length} want≥${minPresent}, ` +
          `heldForBeat=${held} want≥${minHeld}`
  );
  if (!classified) push("FAIL  frame-present/classify — no IRAP classified from wire");
  for (const line of interaction.lines) push(line);
  push(
    interaction.passed
      ? "PASS  interaction-shell/b6 — input + clipboard + audio organs green"
      : "FAIL  interaction-shell/b6 — see session-input/clipboard/audio lines"
  );

  const passed = lines.every((line) => !line.startsWith("FAIL"));
  const ix = bridge.interactionStats();
  const meta =
    `assembled=${stats.assembled} presented=${presentedPts.length} ` +
    `skippedLate=${stats.skippedLate} ingestedDatagrams=${pump?.ingested || 0} ` +
    `ingestBatches=${pump?.batches || 0} ` +
    `unsealFailures=${facts.unsealFailures} idrRequests=${facts.idrRequestsSent}\n` +
    `pts=[${presentedPts.slice(0, 6).join(",")},…]\n` +
    `inputsSent=${ix.inputsSent} inputEchoes=${ix.inputEchoes} ` +
    `clipboardSent=${ix.clipboardSent} audioAssembled=${ix.audioAssembled} ` +
    `audioDroppedStale=${ix.audioDroppedStale}\n` +
    `codec=${sink?.codec || "?"} adapter=${sink?.presenter.adapter || "?"}\n` +
    `sink=${JSON.stringify(sink?.stats || {})}\n` +
    `pacing frame:decoded/presented ms vs PTS=${shown.map(pacingEntry).join(" ")}`;

  return {
    passed,
    lines: [...(pump?.notes || []).map((l) => (l.startsWith("FAIL") ? l : `INFO  ${l}`)), ...lines].join("\n"),
    meta,
    clientStaticPublicKeyHex: pump?.clientStaticPublicKeyHex,
  };
}
