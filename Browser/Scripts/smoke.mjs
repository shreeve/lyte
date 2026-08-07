#!/usr/bin/env node
// Drive system Chrome against the B-2 proof page: frozen WASM contracts plus
// opaque WebTransport datagram carriage through lyte-wt-sidecar.
import { spawn } from "node:child_process";
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
const serveDir = join(browserRoot, ".serve");
const metaOut = join(serveDir, "wt-sidecar.json");
const timeoutMs = Number(process.env.LYTE_BROWSER_SMOKE_TIMEOUT_S || 180) * 1000;

const chrome =
  process.env.LYTE_CHROME ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".json": "application/json",
  ".ts": "text/plain",
};

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function ensureWs() {
  try {
    return require("ws");
  } catch {
    const { execFileSync } = await import("node:child_process");
    const prefix = await mkdtemp(join(tmpdir(), "lyte-b2-npm-"));
    execFileSync(
      "npm",
      ["install", "--silent", "--no-fund", "--no-audit", "--prefix", prefix, "ws@8"],
      { stdio: "inherit" }
    );
    return require(join(prefix, "node_modules", "ws"));
  }
}

async function startSidecar() {
  await mkdir(serveDir, { recursive: true });
  if (existsSync(metaOut)) {
    await rm(metaOut, { force: true });
  }
  const proc = spawn(
    process.execPath,
    [join(browserRoot, "Scripts", "wt-sidecar.mjs"), "--meta-out", metaOut],
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
  "wt-carrier/envelope-echo",
  "wt-carrier/noise-msg1-echo",
  "wt-carrier/budget-1152",
  "wt-carrier/ceiling",
];

const WebSocket = await ensureWs();
const { proc: sidecar, meta: sidecarMeta } = await startSidecar();
const { server, port } = await startStaticServer();
const userData = await mkdtemp(join(tmpdir(), "lyte-browser-smoke-"));
const debugPort = 9200 + Math.floor(Math.random() * 200);
const pageUrl = `http://127.0.0.1:${port}/index.html`;

console.log(
  `browser-smoke: sidecar ${sidecarMeta.url} (budget ${sidecarMeta.lyteBudgetBytes} B)`
);

const chromeProc = spawn(
  chrome,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    `--user-data-dir=${userData}`,
    `--remote-debugging-port=${debugPort}`,
    "--remote-allow-origins=*",
    // WebTransport + pinned cert hashes are the B-2 path.
    "--enable-features=WebTransport,WebTransportDraft07",
    "about:blank",
  ],
  { stdio: "ignore" }
);

let failed = false;
try {
  let version;
  for (let i = 0; i < 50; i++) {
    try {
      version = await fetch(`http://127.0.0.1:${debugPort}/json/version`).then((r) =>
        r.json()
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
        if (typeof lyteB2Passed === 'boolean') {
          return JSON.stringify({
            ready: true,
            passed: lyteB2Passed,
            b1: typeof lyteB1Passed === 'boolean' ? lyteB1Passed : null,
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
        failed = true;
        break;
      }
      for (const snippet of requiredLogSnippets) {
        if (!payload.log.includes(snippet)) {
          console.error(`browser-smoke: missing expected line containing ${snippet}`);
          console.error(payload.log);
          failed = true;
          break;
        }
      }
      if (failed) break;
      if (!payload.log.includes("PASS  wt-carrier/ceiling")) {
        console.error("browser-smoke: ceiling check did not PASS");
        console.error(payload.log);
        failed = true;
        break;
      }
      console.log(
        "browser-smoke: PASS — Chrome reported B-1 contracts + B-2 WT carrier green"
      );
      console.log(payload.log);
      if (payload.meta) console.log(payload.meta);
      // Persist measured ceiling next to the staged tree for docs/HANDOFF.
      try {
        const measurePath = join(serveDir, "wt-carrier-measure.json");
        await writeFile(
          measurePath,
          JSON.stringify(
            {
              passed: true,
              adapter: sidecarMeta.adapter,
              url: sidecarMeta.url,
              lyteBudgetBytes: sidecarMeta.lyteBudgetBytes,
              metaText: payload.meta,
              log: payload.log,
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
      !payload.log.includes("Dialing WebTransport")
    ) {
      console.error("browser-smoke: page reported FAIL while loading");
      console.error(payload.log);
      failed = true;
      break;
    }
    await sleep(250);
  }
  if (!failed && Date.now() >= deadline) {
    console.error("browser-smoke: timeout waiting for lyteB2Passed");
    failed = true;
  }
  ws.close();
} catch (error) {
  console.error("browser-smoke:", error);
  failed = true;
} finally {
  chromeProc.kill("SIGTERM");
  sidecar.kill("SIGTERM");
  server.close();
  await rm(userData, { recursive: true, force: true });
}

process.exit(failed ? 1 : 0);
