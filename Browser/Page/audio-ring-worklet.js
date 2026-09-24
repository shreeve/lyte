// AudioWorklet PCM ring. The main thread posts { pcm: Float32Array } of
// interleaved stereo at 48 kHz. Underruns play silence; the ring never
// invents samples. The queue is bounded so clock drift between the host's
// capture and this device cannot grow latency without limit: past the bound
// the oldest audio is dropped.

const MAX_QUEUED_FRAMES = 9_600; // 200 ms at 48 kHz

class LyteRingProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    /** @type {Float32Array[]} */
    this.chunks = [];
    this.offset = 0; // sample index into chunks[0]
    this.queuedFrames = 0;
    this.framesPlayed = 0;
    this.underruns = 0;
    this.framesDropped = 0;
    this.port.onmessage = (event) => {
      const pcm = event.data?.pcm;
      if (pcm instanceof Float32Array && pcm.length >= 2) {
        this.chunks.push(pcm);
        this.queuedFrames += pcm.length >> 1;
        this.trim();
      } else if (event.data?.type === "stats") {
        this.port.postMessage({
          type: "stats",
          framesPlayed: this.framesPlayed,
          underruns: this.underruns,
          framesDropped: this.framesDropped,
          queuedFrames: this.queuedFrames,
        });
      }
    };
  }

  trim() {
    while (this.queuedFrames > MAX_QUEUED_FRAMES && this.chunks.length > 1) {
      const dropped = (this.chunks.shift().length - this.offset) >> 1;
      this.offset = 0;
      this.queuedFrames -= dropped;
      this.framesDropped += dropped;
    }
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output || !output.length) return true;
    const left = output[0];
    const right = output[1] || output[0];
    for (let i = 0; i < left.length; i++) {
      const chunk = this.chunks[0];
      if (!chunk) {
        left[i] = 0;
        right[i] = 0;
        this.underruns += 1;
        continue;
      }
      left[i] = chunk[this.offset];
      right[i] = chunk[this.offset + 1];
      this.offset += 2;
      this.framesPlayed += 1;
      this.queuedFrames -= 1;
      if (this.offset + 1 >= chunk.length) {
        this.chunks.shift();
        this.offset = 0;
      }
    }
    return true;
  }
}

registerProcessor("lyte-audio-ring", LyteRingProcessor);
