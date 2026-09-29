// Audio playout: WASM's jitter buffer decides what plays next — a packet,
// one packet's concealment, or nothing yet — against the audio this file
// still holds; this file decodes Opus with WebCodecs, keeps the ring in
// the order WASM chose, and feeds the AudioWorklet ring.

import { nowMicros } from "./lyte-io.js";

// The ring reports what it consumed; between reports it drains in real time.
const FRAMES_PER_MS = 48;
// A concealment fills its packet by decaying the last sample to zero over
// 2 ms, as the native ring declicks an underrun: WebCodecs exposes no Opus
// packet-loss concealment.
const DECLICK_FRAMES = 96;

/**
 * Frames the ring still holds: what it held at its last report drains in
 * real time; frames pushed since count whole (at most one report period
 * high, never low, so a refill after an underrun is not mistaken for
 * audio already played).
 */
export function estimateRingDepth(heldAtReport, pushedSinceReport, msSinceReport) {
  const drained = msSinceReport * FRAMES_PER_MS;
  return Math.round(Math.max(0, heldAtReport - drained) + pushedSinceReport);
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
  // The ring's last report: what it held then (pushed minus consumed,
  // played or dropped), what had been pushed by then, and when it arrived.
  // Only what it held then drains in real time; later pushes count whole.
  let heldAtReport = 0;
  let pushedAtReport = 0;
  let reportedAt = null;
  let statsWaiters = [];
  node.port.onmessage = (event) => {
    const data = event.data;
    if (data?.type === "depth") {
      heldAtReport = Math.max(0, framesPushed - data.consumedFrames);
      pushedAtReport = framesPushed;
      reportedAt = performance.now();
    } else if (data?.type === "stats") {
      const waiters = statsWaiters;
      statsWaiters = [];
      for (const resolve of waiters) resolve(data);
    }
  };
  return {
    mode: offline ? "offline" : "realtime",
    context: ctx,
    /** Takes ownership of an interleaved stereo Float32Array (transferred). */
    pushPcm(interleaved) {
      framesPushed += interleaved.length / 2;
      node.port.postMessage({ pcm: interleaved }, [interleaved.buffer]);
    },
    framesPushed: () => framesPushed,
    /** Frames pushed and not yet played, as of the ring's last report. */
    depthFrames() {
      return estimateRingDepth(
        heldAtReport,
        framesPushed - pushedAtReport,
        reportedAt == null ? 0 : performance.now() - reportedAt
      );
    },
    /** Resumes a context the autoplay policy held; call from a user gesture. */
    resume: () => (offline ? Promise.resolve() : ctx.resume()),
    renderOffline: () => (offline ? ctx.startRendering() : Promise.resolve(null)),
    /** The ring's own counters (realtime only: an offline one has ended). */
    stats: () =>
      new Promise((resolve) => {
        statsWaiters.push(resolve);
        node.port.postMessage({ type: "stats" });
      }),
    async close() {
      node.disconnect();
      if (!offline) await ctx.close().catch(() => {});
    },
  };
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
    get error() {
      return error;
    },
    outputs: () => outputs,
    close() {
      if (decoder.state !== "closed") decoder.close();
    },
  };
}

/** One packet's concealment: the last sample decays to zero, then silence. */
export function concealmentPcm(frames, lastLeft, lastRight) {
  const pcm = new Float32Array(frames * 2);
  for (let i = 0; i < Math.min(frames, DECLICK_FRAMES); i++) {
    const gain = (DECLICK_FRAMES - 1 - i) / DECLICK_FRAMES;
    pcm[i * 2] = lastLeft * gain;
    pcm[i * 2 + 1] = lastRight * gain;
  }
  return pcm;
}

/**
 * Executes WASM's audio verdicts. `pump(now)` pulls while WASM wants more,
 * reporting the audio already held (ring plus slots still decoding);
 * decoded PCM and concealments reach the ring strictly in pull order.
 */
export class AudioPlayout {
  /** A realtime ring needs a user gesture before it sounds (`resume`). */
  static async open(bridge, { offline = false, decoderFactory = createOpusDecoder } = {}) {
    const ring = await createAudioRing({
      offline,
      maxQueuedFrames: bridge.audioRingCeilingFrames,
    });
    const playout = new AudioPlayout(bridge, ring, decoderFactory);
    await playout.resetStream();
    return playout;
  }

  constructor(bridge, ring, decoderFactory = createOpusDecoder) {
    this.bridge = bridge;
    this.ring = ring;
    this.decoderFactory = decoderFactory;
    this.packetFrames = bridge.audioPacketFrames;
    this.decoder = null;
    this.detail = "no decoder";
    this.generation = 0;
    // Pulled verdicts not yet in the ring, oldest first: { pcm } once
    // ready, { conceal: true } to synthesize at the head, { pcm: null }
    // while decoding.
    this.slots = [];
    this.lastLeft = 0;
    this.lastRight = 0;
    this.error = null;
    this.stats = { packets: 0, concealed: 0, framesDecoded: 0, decoderResets: 0 };
  }

  /** Audio pulled and not yet played, in frames. */
  pipelineFrames() {
    return this.ring.depthFrames() + this.slots.length * this.packetFrames;
  }

  /**
   * A new session's stream: a fresh decoder, and nothing still decoding
   * from the last one reaches the ring. What the ring holds plays out.
   */
  async resetStream() {
    const generation = ++this.generation;
    this.decoder?.close();
    this.decoder = null;
    this.slots = [];
    const decoder = await this.decoderFactory((pcm) => {
      if (generation === this.generation) this.accept(pcm);
    });
    if (generation !== this.generation) {
      decoder.close?.();
      return;
    }
    this.detail = decoder.detail;
    if (decoder.ok) this.decoder = decoder;
    else this.error = new Error(decoder.detail);
  }

  accept(pcm) {
    this.stats.framesDecoded += pcm.length / 2;
    const slot = this.slots.find((s) => s.pcm === null && !s.conceal);
    if (slot) slot.pcm = pcm;
    this.flush();
  }

  /** Pulls and executes verdicts until WASM says stop. */
  pump(now = nowMicros()) {
    if (!this.decoder) return 0;
    let pulled = 0;
    for (;;) {
      const verdict = this.bridge.audioPull(now, this.pipelineFrames());
      if (!verdict) break;
      pulled += 1;
      if (verdict.conceal) {
        this.stats.concealed += 1;
        this.slots.push({ conceal: true });
        continue;
      }
      this.stats.packets += 1;
      this.slots.push({ pcm: null });
      try {
        this.decoder.decode(verdict.bytes, verdict.captureMicroseconds);
      } catch (error) {
        // A failed decoder fills none of its slots: start a fresh one.
        this.error = error;
        this.stats.decoderResets += 1;
        this.resetStream();
        return pulled;
      }
    }
    this.flush();
    return pulled;
  }

  /** Moves every ready slot at the head into the ring. */
  flush() {
    while (this.slots.length) {
      const head = this.slots[0];
      let pcm = head.pcm;
      if (head.conceal) pcm = concealmentPcm(this.packetFrames, this.lastLeft, this.lastRight);
      if (!pcm) return;
      this.slots.shift();
      if (pcm.length >= 2) {
        this.lastLeft = head.conceal ? 0 : pcm[pcm.length - 2];
        this.lastRight = head.conceal ? 0 : pcm[pcm.length - 1];
        this.ring.pushPcm(pcm);
      }
    }
  }

  async close() {
    this.generation += 1;
    this.decoder?.close();
    this.decoder = null;
    this.slots = [];
    await this.ring.close();
  }
}
