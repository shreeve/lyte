// The browser's VideoSink: WebCodecs HEVC decode and WebGPU present of what
// the WASM Conductor schedules. Platform mechanism only — decode order,
// presentation times and recovery policy come from WASM.
//
// Decode takes every assembled frame in order (late and handoff-refused
// frames included: later P-frames reference them). Presentation pops only
// what the Conductor says is due. Decoded VideoFrames are GPU-pool objects:
// each is closed when overwritten, when presented, or once a newer frame
// has been presented.

import { pickHevcConfig } from "./lyte-io.js";

const MAX_QUEUED_DECODES = 2;
// Decoded-but-unpresented frames held at once; the decoder's output pool
// stalls if the page keeps more.
const MAX_HELD_FRAMES = 8;

const WGSL = `
struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}
@vertex
fn vsMain(@builtin(vertex_index) vi: u32) -> VSOut {
  var pos = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var uv = array<vec2f, 3>(vec2f(0.0, 1.0), vec2f(2.0, 1.0), vec2f(0.0, -1.0));
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
`;

async function createPresenter(canvas) {
  if (!navigator.gpu) throw new Error("WebGPU (navigator.gpu) unavailable");
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) throw new Error("WebGPU adapter request returned null");
  const device = await adapter.requestDevice();
  const context = canvas.getContext("webgpu");
  if (!context) throw new Error("canvas.getContext('webgpu') failed");
  const format = navigator.gpu.getPreferredCanvasFormat();
  const module = device.createShaderModule({ code: WGSL });
  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module, entryPoint: "vsMain" },
    fragment: { module, entryPoint: "fsMain", targets: [{ format }] },
    primitive: { topology: "triangle-list" },
  });
  const sampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  let configured = false;

  return {
    adapter: adapter.info?.description || adapter.info?.vendor || "webgpu",
    format,
    // Synchronous submit: awaiting the GPU would stall the datagram pump.
    present(frame) {
      const width = Math.max(1, frame.displayWidth || frame.codedWidth);
      const height = Math.max(1, frame.displayHeight || frame.codedHeight);
      const presentW = Math.min(960, width);
      const presentH = Math.round((presentW * height) / width);
      if (!configured || canvas.width !== presentW || canvas.height !== presentH) {
        canvas.width = presentW;
        canvas.height = presentH;
        context.configure({ device, format, alphaMode: "opaque" });
        configured = true;
      }
      const bindGroup = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: sampler },
          { binding: 1, resource: device.importExternalTexture({ source: frame }) },
        ],
      });
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: context.getCurrentTexture().createView(),
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
    destroy() {
      try {
        context.unconfigure();
      } catch {
        /* never configured */
      }
      device.destroy();
    },
  };
}

export class VideoSink {
  /**
   * @param bridge globalThis.lyteBrowser
   * @param canvas the video surface
   * @param geometry decoder hint until the first decoded frame reports its own
   */
  static async open(bridge, canvas, geometry = { width: 2048, height: 1280 }) {
    const picked = await pickHevcConfig(geometry.width, geometry.height);
    if (!picked.ok) throw new Error(`webcodecs: ${picked.detail}`);
    const presenter = await createPresenter(canvas);
    return new VideoSink(bridge, picked, presenter);
  }

  constructor(bridge, picked, presenter) {
    this.bridge = bridge;
    this.codecDetail = picked.detail;
    this.codec = picked.config.codec;
    this.presenter = presenter;
    this.queue = []; // scheduled-frame metadata in decode order
    this.decoded = new Map(); // presentation µs → VideoFrame
    this.pendingDue = null;
    this.awaitingKeyFrame = false;
    this.error = null;
    this.frameSize = null;
    this.stats = { decoded: 0, presented: 0, missing: 0, skippedForKey: 0, closedStale: 0 };
    this.presentedPts = [];
    this.firstDecodedPts = null;
    this.onFirstKeyFrame = null;
    this.decoder = new VideoDecoder({
      output: (frame) => this.accept(frame),
      error: (error) => {
        this.error = error;
      },
    });
    this.decoder.configure(picked.config);
  }

  /** Metadata for frames the Conductor scheduled (from a session step). */
  enqueue(scheduled) {
    for (const meta of scheduled) this.queue.push(meta);
  }

  accept(frame) {
    this.stats.decoded += 1;
    this.frameSize = { width: frame.displayWidth, height: frame.displayHeight };
    const previous = this.decoded.get(frame.timestamp);
    if (previous) previous.close();
    this.decoded.set(frame.timestamp, frame);
    const due = this.pendingDue?.presentationMicroseconds;
    while (this.decoded.size > MAX_HELD_FRAMES) {
      // Never evict the frame the Conductor is waiting to present.
      const oldest = Math.min(...[...this.decoded.keys()].filter((t) => t !== due));
      this.decoded.get(oldest).close();
      this.decoded.delete(oldest);
      this.stats.closedStale += 1;
    }
  }

  /** Feeds the decoder in Conductor order without flooding it. */
  pumpDecode() {
    while (!this.error && this.queue.length && this.decoder.decodeQueueSize < MAX_QUEUED_DECODES) {
      const meta = this.queue.shift();
      const bytes = this.bridge.mediaTakeAnnexB(meta.frameNumber);
      if (!bytes) {
        // Evicted before decode: the reference chain is broken until the
        // next IRAP (WASM has already asked the host for one).
        this.stats.missing += 1;
        this.bridge.mediaNoteDropped(meta.frameNumber);
        this.awaitingKeyFrame = true;
        continue;
      }
      if (this.awaitingKeyFrame && !meta.isRandomAccess) {
        this.stats.skippedForKey += 1;
        this.bridge.mediaNoteDropped(meta.frameNumber);
        continue;
      }
      this.awaitingKeyFrame = false;
      if (meta.isRandomAccess && this.onFirstKeyFrame) {
        this.onFirstKeyFrame(bytes);
        this.onFirstKeyFrame = null;
      }
      try {
        this.decoder.decode(
          new EncodedVideoChunk({
            type: meta.isRandomAccess ? "key" : "delta",
            timestamp: meta.presentationMicroseconds,
            data: bytes,
          })
        );
        if (this.firstDecodedPts == null) this.firstDecodedPts = meta.presentationMicroseconds;
      } catch (error) {
        this.error = error;
      }
    }
  }

  /** Presents the Conductor's due frame once it has decoded. */
  pumpPresent(now) {
    if (!this.pendingDue) {
      this.pendingDue = this.bridge.mediaPopDue(now);
      if (!this.pendingDue) return false;
    }
    const pts = this.pendingDue.presentationMicroseconds;
    const frame = this.decoded.get(pts);
    if (!frame) return false;
    const due = this.pendingDue;
    this.pendingDue = null;
    this.decoded.delete(pts);
    try {
      const shown = this.presenter.present(frame);
      this.bridge.mediaNotePresented(due.frameNumber);
      this.stats.presented += 1;
      this.presentedPts.push(pts);
      this.lastPresent = shown;
    } finally {
      frame.close();
    }
    this.closeOlderThan(pts);
    return true;
  }

  /** Frames behind the presented one will never be shown. */
  closeOlderThan(pts) {
    for (const [timestamp, frame] of this.decoded) {
      if (timestamp < pts) {
        frame.close();
        this.decoded.delete(timestamp);
        this.stats.closedStale += 1;
      }
    }
  }

  close() {
    try {
      if (this.decoder.state !== "closed") this.decoder.close();
    } catch {
      /* already closed by an error */
    }
    for (const frame of this.decoded.values()) frame.close();
    this.decoded.clear();
    this.presenter.destroy();
  }
}
