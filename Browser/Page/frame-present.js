// B-4: one timestamped HEVC access unit → WebCodecs VideoDecoder → WebGPU canvas.
// Uses the frozen Wire video-corpus-v1 IDR (staged by build.sh). Not live
// Conductor video — that is B-5. putImageData is never the present path.

const FIXTURE_URL = "./frame-000-idr.annexb";
const FIXTURE_NAME = "video-corpus-v1/frame-000-idr.annexb";
/** Explicit presentation timestamp (µs). WebCodecs VideoFrame.timestamp unit. */
const PRESENTATION_TIMESTAMP_US = 1_000_000;
const PRESENTATION_DURATION_US = 16_667; // ~60 fps

function hexFromBytes(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function linesPush(lines, line) {
  lines.push(line);
}

/**
 * Probe HEVC WebCodecs configs Chrome may accept for Annex-B (hev1, no
 * description). Main Profile / Level 5.0 matches the corpus VPS/SPS.
 */
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
      // Corpus IDR is 2048×1280 (NVENC capture); probe accepts nearby sizes.
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

async function decodeOneFrame(annexB, config) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      try {
        decoder.close();
      } catch {
        /* ignore */
      }
      fn(value);
    };

    const decoder = new VideoDecoder({
      output: (frame) => finish(resolve, frame),
      error: (err) => finish(reject, err),
    });

    decoder.configure(config);
    const chunk = new EncodedVideoChunk({
      type: "key",
      timestamp: PRESENTATION_TIMESTAMP_US,
      duration: PRESENTATION_DURATION_US,
      data: annexB,
    });
    decoder.decode(chunk);
    decoder.flush().catch((err) => finish(reject, err));

    setTimeout(() => {
      finish(
        reject,
        new Error("WebCodecs decode timed out waiting for VideoFrame")
      );
    }, 15_000);
  });
}

async function presentWithWebGPU(canvas, frame) {
  if (!navigator.gpu) {
    throw new Error("WebGPU (navigator.gpu) unavailable");
  }
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error("WebGPU adapter request returned null");
  }
  const device = await adapter.requestDevice();
  const context = canvas.getContext("webgpu");
  if (!context) {
    throw new Error("canvas.getContext('webgpu') failed");
  }

  const format = navigator.gpu.getPreferredCanvasFormat();
  const width = Math.max(1, frame.displayWidth || frame.codedWidth || 2048);
  const height = Math.max(1, frame.displayHeight || frame.codedHeight || 1280);
  // Present at a readable diagnostic size; GPU still owns the copy/compose.
  const presentW = Math.min(960, width);
  const presentH = Math.round((presentW * height) / width);
  canvas.width = presentW;
  canvas.height = presentH;

  context.configure({
    device,
    format,
    alphaMode: "opaque",
  });

  const shaderModule = device.createShaderModule({
    code: `
struct VSOut {
  @builtin(position) pos: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vsMain(@builtin(vertex_index) vi: u32) -> VSOut {
  // Fullscreen triangle; flip V so HEVC top-left origin matches canvas.
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
  await device.queue.onSubmittedWorkDone();

  return {
    adapter: adapter.info?.description || adapter.info?.vendor || "webgpu",
    format,
    presentWidth: presentW,
    presentHeight: presentH,
    codedWidth: frame.codedWidth,
    codedHeight: frame.codedHeight,
    displayWidth: frame.displayWidth,
    displayHeight: frame.displayHeight,
  };
}

/**
 * Run B-4: classify canned AU in WASM, decode with WebCodecs, present with
 * WebGPU. Resolves with { passed, lines, meta }.
 */
export async function runFramePresentProof(opts = {}) {
  const lines = [];
  const canvas =
    opts.canvas ||
    document.getElementById("frame-canvas") ||
    (() => {
      throw new Error("frame-canvas element missing");
    })();

  const bridge = globalThis.lyteBrowser;
  if (!bridge?.classifyAnnexBHex) {
    linesPush(lines, "FAIL  frame-present/classify — lyteBrowser.classifyAnnexBHex missing");
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  let annexB;
  try {
    const response = await fetch(FIXTURE_URL);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} fetching ${FIXTURE_URL}`);
    }
    annexB = new Uint8Array(await response.arrayBuffer());
  } catch (error) {
    linesPush(
      lines,
      `FAIL  frame-present/fixture — ${error?.message || error}`
    );
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  if (annexB.byteLength < 64) {
    linesPush(lines, "FAIL  frame-present/fixture — access unit too small");
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  const classified = bridge.classifyAnnexBHex(hexFromBytes(annexB));
  if (!classified?.ok || !classified.frameShaped || !classified.containsIrap) {
    linesPush(
      lines,
      `FAIL  frame-present/classify — ${classified?.detail || "not IRAP-shaped"}`
    );
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }
  linesPush(
    lines,
    `PASS  frame-present/classify — ${classified.summary} (${classified.byteCount} B)`
  );

  const picked = await pickHevcConfig();
  if (!picked.ok) {
    linesPush(lines, `FAIL  frame-present/webcodecs — ${picked.detail}`);
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  let frame;
  try {
    frame = await decodeOneFrame(annexB, picked.config);
  } catch (error) {
    linesPush(
      lines,
      `FAIL  frame-present/webcodecs — decode: ${error?.message || error}`
    );
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }

  const ts = frame.timestamp;
  if (ts !== PRESENTATION_TIMESTAMP_US) {
    frame.close();
    linesPush(
      lines,
      `FAIL  frame-present/timestamp — got ${ts}, want ${PRESENTATION_TIMESTAMP_US}`
    );
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }
  linesPush(
    lines,
    `PASS  frame-present/webcodecs — ${picked.detail} ` +
      `${frame.codedWidth}x${frame.codedHeight} ts=${ts}µs`
  );

  let presentMeta;
  try {
    presentMeta = await presentWithWebGPU(canvas, frame);
  } catch (error) {
    frame.close();
    linesPush(
      lines,
      `FAIL  frame-present/webgpu — ${error?.message || error}`
    );
    return { passed: false, lines: lines.join("\n"), meta: "" };
  }
  frame.close();

  linesPush(
    lines,
    `PASS  frame-present/webgpu — importExternalTexture → canvas ` +
      `${presentMeta.presentWidth}x${presentMeta.presentHeight} (${presentMeta.format})`
  );

  const meta =
    `fixture=${FIXTURE_NAME}\n` +
    `codec=${picked.config.codec}\n` +
    `timestampUs=${PRESENTATION_TIMESTAMP_US}\n` +
    `coded=${presentMeta.codedWidth}x${presentMeta.codedHeight} ` +
    `present=${presentMeta.presentWidth}x${presentMeta.presentHeight}\n` +
    `adapter=${presentMeta.adapter}\n` +
    `B-4 = canned IRAP → WebCodecs → WebGPU (not live Conductor / B-5)`;

  return { passed: true, lines: lines.join("\n"), meta };
}
