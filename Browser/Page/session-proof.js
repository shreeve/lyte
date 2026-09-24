// The end-to-end proof the smoke gate and the harness page run: a control
// session (Noise / PIN / capabilities), the peer's sealed corpus video
// through the Conductor to WebCodecs + WebGPU, then input, clipboard and
// Opus audio, then an orderly teardown.
//
// This is a proof harness, not the product loop: it ingests the whole
// corpus before decoding (phase 1), then decodes and presents (phase 2), so
// every frame is already due when it is presented. The schedule assertion
// checks Conductor PTS arithmetic, not paced presentation.

import { runInteractionProofs } from "./interaction.js";
import { nowMicros, sleep } from "./lyte-io.js";
import { SessionPump } from "./session-pump.js";
import { VideoSink } from "./video-sink.js";

export async function runSessionProof({
  sidecar,
  hostStaticPublicKeyHex,
  pin,
  canvas,
  offlineAudio = false,
  timeoutMs = 90_000,
  minPresent = 5,
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
    pump.onScheduled = (scheduled) => sink.enqueue(scheduled);
    onOpen(pump, sink);
    await pump.begin();
    const deadline = Date.now() + timeoutMs;

    // Phase 1: ingest the corpus until it has assembled and gone quiet.
    let lastAssembled = 0;
    let quietTurns = 0;
    while (Date.now() < deadline && !pump.failed) {
      const ingested = await pump.turn(2);
      const assembled = bridge.mediaStats().assembled;
      if (assembled > lastAssembled) {
        lastAssembled = assembled;
        quietTurns = 0;
      } else if (pump.ready && !ingested) {
        quietTurns += 1;
      }
      if (assembled >= minAssemble && quietTurns >= 40) break;
      if (pump.ready && assembled > 0 && quietTurns >= 500) break;
    }

    // Phase 2: decode in order, present what the Conductor says is due.
    for (let i = 0; i < 500 && !pump.failed && sink.stats.presented < minPresent; i++) {
      await pump.turn(0);
      sink.pumpDecode();
      if (sink.firstDecodedPts != null && !lines.some((l) => l.includes("frame-present/webcodecs"))) {
        push(`PASS  frame-present/webcodecs — ${sink.codecDetail} ts=${sink.firstDecodedPts}µs (Conductor PTS)`);
      }
      if (sink.pumpPresent(nowMicros()) && sink.stats.presented === 1) {
        push(
          `PASS  frame-present/webgpu — importExternalTexture → canvas ` +
            `${sink.lastPresent.presentWidth}x${sink.lastPresent.presentHeight} (${sink.presenter.format})`
        );
      }
      if (sink.error) {
        push(`FAIL  conductor-video/webcodecs — ${sink.error?.message || sink.error}`);
        break;
      }
      await sleep(2);
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
  const presentedPts = sink?.presentedPts || [];
  const beat = bridge.conductorBeatMicroseconds;
  // Successive presented PTS differ by whole Conductor beats (±1 µs bump).
  let beatOk = presentedPts.length >= 2;
  for (let i = 1; i < presentedPts.length; i++) {
    const rem = (presentedPts[i] - presentedPts[i - 1]) % beat;
    if (!(rem === 0 || rem === 1 || rem === beat - 1)) beatOk = false;
  }
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
    beatOk
      ? `PASS  conductor-video/schedule — Conductor PTS beat-grid (${presentedPts.length} presented)`
      : `FAIL  conductor-video/schedule — PTS not on beat-grid (n=${presentedPts.length})`
  );
  push(
    presentedPts.length >= minPresent
      ? `PASS  conductor-video/present — ${presentedPts.length} frames WebGPU on Conductor PTS`
      : `FAIL  conductor-video/present — presented=${presentedPts.length} want≥${minPresent}`
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
    `unsealFailures=${facts.unsealFailures} idrRequests=${facts.idrRequestsSent}\n` +
    `pts=[${presentedPts.slice(0, 6).join(",")},…]\n` +
    `inputsSent=${ix.inputsSent} inputEchoes=${ix.inputEchoes} ` +
    `clipboardSent=${ix.clipboardSent} audioAssembled=${ix.audioAssembled} ` +
    `audioDroppedStale=${ix.audioDroppedStale}\n` +
    `codec=${sink?.codec || "?"} adapter=${sink?.presenter.adapter || "?"}`;

  return {
    passed,
    lines: [...(pump?.notes || []).map((l) => (l.startsWith("FAIL") ? l : `INFO  ${l}`)), ...lines].join("\n"),
    meta,
    clientStaticPublicKeyHex: pump?.clientStaticPublicKeyHex,
  };
}
