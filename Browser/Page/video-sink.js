// The browser's VideoSink: WebCodecs HEVC decode and WebGPU present of what
// the WASM Conductor schedules. Platform mechanism only — decode order,
// presentation times and recovery policy come from WASM.
//
// Decode takes every assembled frame in order (late and handoff-refused
// frames included: later P-frames reference them). Presentation pops only
// what the Conductor says is due, and a decoded frame waits for its beat.
//
// The stream has no reordering, so decode order, output order and PTS
// order agree. That makes liveness local: once the Conductor names a due
// PTS, every held frame before it is dead, and if that PTS is neither held,
// in the decoder, nor queued for decode, it never will be. Decoded
// VideoFrames are GPU-pool objects, so decode is throttled by what the page
// holds rather than evicting frames the Conductor has yet to ask for.
import { nowMicros, pickHevcConfig } from "./lyte-io.js";

const MAX_QUEUED_DECODES = 2;
// Decoded-but-unpresented frames held at once, counting frames still inside
// the decoder; the decoder's output pool stalls if the page keeps more.
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
    this.inDecoder = new Map(); // presentation µs → metadata, submitted, not yet output
    this.decoded = new Map(); // presentation µs → { frame, meta, decodedAt }
    this.pendingDue = null;
    this.awaitingKeyFrame = false;
    this.error = null;
    this.frameSize = null;
    this.stats = {
      decoded: 0,
      presented: 0,
      missing: 0,
      skippedForKey: 0,
      closedUnshown: 0,
      dueNeverDecoded: 0,
    };
    // One record per presented frame: when it decoded and when it showed,
    // against the PTS the Conductor gave it (all client-clock µs).
    this.presentations = [];
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

  /** True while decode input or output is still outstanding. */
  get busy() {
    return this.queue.length > 0 || this.inDecoder.size > 0 || this.pendingDue != null;
  }

  accept(frame) {
    this.stats.decoded += 1;
    this.frameSize = { width: frame.displayWidth, height: frame.displayHeight };
    const meta = this.inDecoder.get(frame.timestamp);
    this.inDecoder.delete(frame.timestamp);
    // Late frames were decoded only to keep the reference chain.
    if (!meta?.shouldPresent) {
      frame.close();
      this.stats.closedUnshown += 1;
      return;
    }
    this.decoded.get(frame.timestamp)?.frame.close();
    this.decoded.set(frame.timestamp, { frame, meta, decodedAt: nowMicros() });
  }

  /** Feeds the decoder in Conductor order without flooding it. */
  pumpDecode() {
    while (
      !this.error &&
      this.queue.length &&
      this.decoder.decodeQueueSize < MAX_QUEUED_DECODES &&
      this.decoded.size + this.inDecoder.size < MAX_HELD_FRAMES
    ) {
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
        this.inDecoder.set(meta.presentationMicroseconds, meta);
        this.decoder.decode(
          new EncodedVideoChunk({
            type: meta.isRandomAccess ? "key" : "delta",
            timestamp: meta.presentationMicroseconds,
            data: bytes,
          })
        );
        if (this.firstDecodedPts == null) this.firstDecodedPts = meta.presentationMicroseconds;
      } catch (error) {
        this.inDecoder.delete(meta.presentationMicroseconds);
        this.error = error;
      }
    }
  }

  /**
   * Presents the Conductor's due frame once it has decoded. Returns true
   * when a frame was presented.
   */
  pumpPresent(now) {
    for (;;) {
      if (!this.pendingDue) {
        this.pendingDue = this.bridge.mediaPopDue(now);
        if (!this.pendingDue) {
          // Everything the Conductor will still present is due after
          // `now`, so a held frame at or before it is never shown.
          this.closeHeld((pts) => pts <= now);
          return false;
        }
      }
      const due = this.pendingDue;
      const pts = due.presentationMicroseconds;
      this.closeHeld((held) => held < pts);
      const held = this.decoded.get(pts);
      if (!held) {
        if (this.inDecoder.has(pts) || this.queue.some((m) => m.frameNumber === due.frameNumber)) {
          return false; // still on its way through the decoder
        }
        // Dropped before decode (evicted or skipped for a key frame).
        this.stats.dueNeverDecoded += 1;
        this.pendingDue = null;
        continue;
      }
      this.pendingDue = null;
      this.decoded.delete(pts);
      try {
        const shown = this.presenter.present(held.frame);
        this.bridge.mediaNotePresented(due.frameNumber);
        this.stats.presented += 1;
        this.presentations.push({
          frameNumber: due.frameNumber,
          pts,
          decodedAt: held.decodedAt,
          presentedAt: now,
        });
        this.lastPresent = shown;
      } finally {
        held.frame.close();
      }
      return true;
    }
  }

  /** Closes held frames the Conductor will never present. */
  closeHeld(isDead) {
    for (const [pts, held] of this.decoded) {
      if (isDead(pts)) {
        held.frame.close();
        this.decoded.delete(pts);
        this.stats.closedUnshown += 1;
      }
    }
  }

  close() {
    try {
      if (this.decoder.state !== "closed") this.decoder.close();
    } catch {
      /* already closed by an error */
    }
    for (const held of this.decoded.values()) held.frame.close();
    this.decoded.clear();
    this.presenter.destroy();
  }
}
