// AudioWorklet PCM ring for LyteClientBrowser B-6.
// Main thread posts { pcm: Float32Array } interleaved stereo @ 48 kHz.
// Never invents samples — underruns are silence.

class LyteRingProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    /** @type {Float32Array[]} */
    this.chunks = [];
    this.offset = 0;
    this.framesPlayed = 0;
    this.underruns = 0;
    this.port.onmessage = (event) => {
      const pcm = event.data?.pcm;
      if (pcm instanceof Float32Array && pcm.length >= 2) {
        this.chunks.push(pcm);
      } else if (event.data?.type === "stats") {
        this.port.postMessage({
          type: "stats",
          framesPlayed: this.framesPlayed,
          underruns: this.underruns,
          queuedChunks: this.chunks.length,
        });
      }
    };
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output || !output.length) return true;
    const left = output[0];
    const right = output[1] || output[0];
    const frames = left.length;

    for (let i = 0; i < frames; i++) {
      if (!this.chunks.length) {
        left[i] = 0;
        right[i] = 0;
        this.underruns += 1;
        continue;
      }
      const chunk = this.chunks[0];
      left[i] = chunk[this.offset] || 0;
      right[i] = chunk[this.offset + 1] || left[i];
      this.offset += 2;
      this.framesPlayed += 1;
      if (this.offset + 1 >= chunk.length) {
        this.chunks.shift();
        this.offset = 0;
      }
    }
    return true;
  }
}

registerProcessor("lyte-audio-ring", LyteRingProcessor);
