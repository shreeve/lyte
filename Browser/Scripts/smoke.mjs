#!/usr/bin/env node
// Drive system Chrome against the B-5 proof page: frozen WASM contracts,
// a control session (Noise / pair / capabilities / teardown) through
// lyte-wt-sidecar --udp-peer → lyte-control-peer --emit-corpus, then
// Conductor-scheduled multi-frame WebCodecs + WebGPU present.
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, extname } from "node:path";
import { tmpdir } from "node:os";
import { mkdtemp, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const browserRoot = fileURLToPath(new URL("..", import.meta.url));
const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const serveDir = join(browserRoot, ".serve");
const metaOut = join(serveDir, "wt-sidecar.json");
const peerMetaOut = join(serveDir, "control-peer.json");
const timeoutMs = Number(process.env.LYTE_BROWSER_SMOKE_TIMEOUT_S || 180) * 1000;
const peerPort =
  Number(process.env.LYTE_CONTROL_PEER_PORT || 0) ||
  41200 + Math.floor(Math.random() * 200);

const chrome =
  process.env.LYTE_CHROME ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".json": "application/json",
  ".annexb": "application/octet-stream",
  ".ts": "text/plain",
};

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function ensureWs() {
  try {
    return require("ws");
  } catch {
    const prefix = await mkdtemp(join(tmpdir(), "lyte-b5-npm-"));
    execFileSync(
      "npm",
      ["install", "--silent", "--no-fund", "--no-audit", "--prefix", prefix, "ws@8"],
      { stdio: "inherit" }
    );
    return require(join(prefix, "node_modules", "ws"));
  }
}

function buildControlPeer() {
  const env = {
    ...process.env,
    DEVELOPER_DIR:
      process.env.DEVELOPER_DIR ||
      "/Applications/Xcode.app/Contents/Developer",
  };
  execFileSync(
    "swift",
    ["build", "-c", "release", "--product", "lyte-control-peer"],
    { cwd: join(repoRoot, "Host"), stdio: "inherit", env }
  );
  const bin = join(repoRoot, "Host", ".build", "release", "lyte-control-peer");
  if (!existsSync(bin)) {
    throw new Error(`missing ${bin}`);
  }
  return bin;
}

async function startControlPeer(bin) {
  await mkdir(serveDir, { recursive: true });
  if (existsSync(peerMetaOut)) {
    await rm(peerMetaOut, { force: true });
  }
  if (peerPort === 41151) {
    throw new Error("refusing standing host UDP 41151");
  }
  const logPath = join(serveDir, "control-peer.log");
  const logFd = await import("node:fs").then((fs) =>
    fs.openSync(logPath, "w")
  );
  const corpusDir = join(serveDir, "corpus");
  if (!existsSync(join(corpusDir, "frame-000-idr.annexb"))) {
    throw new Error(
      `missing ${corpusDir}/frame-000-idr.annexb — run Browser/Scripts/build.sh`
    );
  }
  const proc = spawn(
    "stdbuf",
    [
      "-oL",
      "-eL",
      bin,
      "--listen",
      String(peerPort),
      "--bind",
      "127.0.0.1",
      "--meta-out",
      peerMetaOut,
      "--emit-corpus",
      corpusDir,
      "--seconds",
      "180",
    ],
    { stdio: ["ignore", logFd, logFd] }
  );
  for (let i = 0; i < 100; i++) {
    if (existsSync(peerMetaOut)) {
      const meta = JSON.parse(await readFile(peerMetaOut, "utf8"));
      return { proc, meta, logPath };
    }
    if (proc.exitCode != null) {
      const log = await readFile(logPath, "utf8").catch(() => "");
      throw new Error(`control-peer exited early (${proc.exitCode}): ${log}`);
    }
    await sleep(50);
  }
  proc.kill("SIGTERM");
  throw new Error(`timed out waiting for ${peerMetaOut}`);
}

async function startSidecar(peer) {
  if (existsSync(metaOut)) {
    await rm(metaOut, { force: true });
  }
  const proc = spawn(
    process.execPath,
    [
      join(browserRoot, "Scripts", "wt-sidecar.mjs"),
      "--meta-out",
      metaOut,
      "--udp-peer",
      `${peer.bindHost || "127.0.0.1"}:${peer.listenPort}`,
    ],
    { stdio: ["ignore", "pipe", "pipe"] }
  );
  let stderr = "";
  proc.stderr.on("data", (chunk) => {
    stderr += String(chunk);
  });
  proc.stdout.on("data", () => {});
  for (let i = 0; i < 100; i++) {
    if (existsSync(metaOut)) {
      const meta = JSON.parse(await readFile(metaOut, "utf8"));
      return { proc, meta, stderr: () => stderr };
    }
    if (proc.exitCode != null) {
      throw new Error(`wt-sidecar exited early (${proc.exitCode}): ${stderr}`);
    }
    await sleep(50);
  }
  proc.kill("SIGTERM");
  throw new Error(`timed out waiting for ${metaOut}: ${stderr}`);
}

async function startStaticServer() {
  const server = createServer(async (req, res) => {
    try {
      let rel = decodeURIComponent((req.url || "/").split("?")[0] || "/");
      if (rel === "/") rel = "/index.html";
      const path = join(serveDir, rel);
      if (!path.startsWith(serveDir)) {
        res.writeHead(403);
        res.end("forbidden");
        return;
      }
      const body = await readFile(path);
      const type = mime[extname(path)] || "application/octet-stream";
      res.writeHead(200, { "Content-Type": type });
      res.end(body);
    } catch {
      res.writeHead(404);
      res.end("not found");
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return { server, port };
}

async function cdp(wsUrl, WebSocket) {
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
  let nextId = 0;
  const pending = new Map();
  ws.on("message", (raw) => {
    const msg = JSON.parse(String(raw));
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  return { ws, send };
}

const requiredLogSnippets = [
  "envelope-v1/nominal-video-shard",
  "noise-v1/snow-ik-25519-chachapoly-sha256",
  "control-session/noise-pair-caps",
  "control-session/teardown",
  "frame-present/classify",
  "frame-present/webcodecs",
  "frame-present/webgpu",
  "conductor-video/assemble",
  "conductor-video/schedule",
  "conductor-video/present",
];

if (
  !existsSync(join(serveDir, "LyteClientBrowser.wasm")) ||
  !existsSync(join(serveDir, "control-session.js")) ||
  !existsSync(join(serveDir, "conductor-video.js")) ||
  !existsSync(join(serveDir, "corpus", "frame-000-idr.annexb"))
) {
  console.log("browser-smoke: building Browser package first…");
  execFileSync(join(browserRoot, "Scripts", "build.sh"), {
    stdio: "inherit",
  });
}

const WebSocket = await ensureWs();
console.log("browser-smoke: building lyte-control-peer…");
const peerBin = buildControlPeer();
const { proc: peerProc, meta: peerMeta } = await startControlPeer(peerBin);
const { proc: sidecar, meta: sidecarMeta } = await startSidecar(peerMeta);
const { server, port } = await startStaticServer();
const userData = await mkdtemp(join(tmpdir(), "lyte-browser-smoke-"));
const debugPort = 9200 + Math.floor(Math.random() * 200);
const pageUrl = `http://127.0.0.1:${port}/index.html`;

console.log(
  `browser-smoke: sidecar ${sidecarMeta.url} → UDP ${peerMeta.listenPort} ` +
    `(pin ${peerMeta.pin})`
);

// WebGPU + WebCodecs HEVC need a real GPU path — do not pass --disable-gpu.
const chromeProc = spawn(
  chrome,
  [
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    `--user-data-dir=${userData}`,
    `--remote-debugging-port=${debugPort}`,
    "--remote-allow-origins=*",
    "--enable-features=WebTransport,WebTransportDraft07,WebGPU",
    "--enable-unsafe-webgpu",
    "about:blank",
  ],
  { stdio: "ignore" }
);

let failed = false;
try {
  let version;
  for (let i = 0; i < 50; i++) {
    try {
      version = await fetch(`http://127.0.0.1:${debugPort}/json/version`).then(
        (r) => r.json()
      );
      break;
    } catch {
      await sleep(100);
    }
  }
  if (!version) throw new Error("Chrome DevTools did not come up");

  const created = await fetch(
    `http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(pageUrl)}`,
    { method: "PUT" }
  ).then((r) => r.json());
  const { send, ws } = await cdp(created.webSocketDebuggerUrl, WebSocket);
  await send("Runtime.enable");
  await send("Page.enable");

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await send("Runtime.evaluate", {
      expression: `(() => {
        if (typeof lyteB5Passed === 'boolean') {
          return JSON.stringify({
            ready: true,
            passed: lyteB5Passed,
            b1: typeof lyteB1Passed === 'boolean' ? lyteB1Passed : null,
            b3: typeof lyteB3Passed === 'boolean' ? lyteB3Passed : null,
            status: document.getElementById('status')?.textContent || '',
            log: document.getElementById('log')?.textContent || '',
            meta: document.getElementById('meta')?.textContent || ''
          });
        }
        return JSON.stringify({
          ready: false,
          status: document.getElementById('status')?.textContent || '',
          log: document.getElementById('log')?.textContent || ''
        });
      })()`,
      returnByValue: true,
    });
    const payload = JSON.parse(result.result.value);
    if (payload.ready) {
      if (!payload.passed) {
        console.error("browser-smoke: FAIL");
        console.error(payload.log);
        if (payload.meta) console.error(payload.meta);
        try {
          const peerLog = await readFile(join(serveDir, "control-peer.log"), "utf8");
          if (peerLog.trim()) {
            console.error("--- control-peer.log ---");
            console.error(peerLog.trim().split("\n").slice(-40).join("\n"));
          }
        } catch {
          /* ignore */
        }
        try {
          const wtLog = sidecar.stderr?.() || "";
          if (wtLog.trim()) {
            console.error("--- wt-sidecar stderr ---");
            console.error(wtLog.trim().split("\n").slice(-40).join("\n"));
          }
        } catch {
          /* ignore */
        }
        failed = true;
        break;
      }
      for (const snippet of requiredLogSnippets) {
        if (!payload.log.includes(snippet)) {
          console.error(
            `browser-smoke: missing expected line containing ${snippet}`
          );
          console.error(payload.log);
          failed = true;
          break;
        }
      }
      if (failed) break;
      for (const mustPass of [
        "PASS  control-session/noise-pair-caps",
        "PASS  frame-present/webcodecs",
        "PASS  frame-present/webgpu",
        "PASS  conductor-video/assemble",
        "PASS  conductor-video/schedule",
        "PASS  conductor-video/present",
      ]) {
        if (!payload.log.includes(mustPass)) {
          console.error(`browser-smoke: missing ${mustPass}`);
          console.error(payload.log);
          failed = true;
          break;
        }
      }
      if (failed) break;
      console.log(
        "browser-smoke: PASS — Chrome reported B-1 + B-3 control + B-5 Conductor video green"
      );
      console.log(payload.log);
      if (payload.meta) console.log(payload.meta);
      try {
        await writeFile(
          join(serveDir, "conductor-video-measure.json"),
          JSON.stringify(
            {
              passed: true,
              adapter: sidecarMeta.adapter,
              shape: sidecarMeta.shape,
              url: sidecarMeta.url,
              controlPeerPort: peerMeta.listenPort,
              log: payload.log,
              metaText: payload.meta,
            },
            null,
            2
          ) + "\n"
        );
      } catch {
        /* non-fatal */
      }
      break;
    }
    if (
      (payload.status || "").includes("FAIL") &&
      payload.log &&
      !payload.log.includes("Instantiating") &&
      !payload.log.includes("Dialing") &&
      !payload.log.includes("Opening control") &&
      !payload.log.includes("Decoding canned")
    ) {
      console.error("browser-smoke: page reported FAIL while loading");
      console.error(payload.log);
      failed = true;
      break;
    }
    await sleep(250);
  }
  if (!failed && Date.now() >= deadline) {
    console.error("browser-smoke: timeout waiting for lyteB5Passed");
    failed = true;
  }
  ws.close();
} catch (error) {
  console.error("browser-smoke:", error);
  failed = true;
} finally {
  chromeProc.kill("SIGTERM");
  sidecar.kill("SIGTERM");
  peerProc.kill("SIGTERM");
  server.close();
  try {
    await rm(userData, { recursive: true, force: true });
  } catch {
    /* Chrome sometimes leaves Default/ busy; non-fatal */
  }
}

process.exit(failed ? 1 : 0);
