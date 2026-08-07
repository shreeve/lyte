#!/usr/bin/env node
// Drive system Chrome against the B-1 proof page and assert lyteB1Passed.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname } from "node:path";
import { tmpdir } from "node:os";
import { mkdtemp, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const browserRoot = fileURLToPath(new URL("..", import.meta.url));
const serveDir = join(browserRoot, ".serve");
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
    const prefix = await mkdtemp(join(tmpdir(), "lyte-b1-npm-"));
    execFileSync(
      "npm",
      ["install", "--silent", "--no-fund", "--no-audit", "--prefix", prefix, "ws@8"],
      { stdio: "inherit" }
    );
    return require(join(prefix, "node_modules", "ws"));
  }
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

const WebSocket = await ensureWs();
const { server, port } = await startStaticServer();
const userData = await mkdtemp(join(tmpdir(), "lyte-browser-smoke-"));
const debugPort = 9200 + Math.floor(Math.random() * 200);
const pageUrl = `http://127.0.0.1:${port}/index.html`;

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
        if (typeof lyteB1Passed === 'boolean') {
          return JSON.stringify({
            ready: true,
            passed: lyteB1Passed,
            status: document.getElementById('status')?.textContent || '',
            log: document.getElementById('log')?.textContent || ''
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
        failed = true;
        break;
      }
      if (!payload.log.includes("envelope-v1/nominal-video-shard")) {
        console.error("browser-smoke: missing envelope contract line");
        failed = true;
        break;
      }
      if (!payload.log.includes("noise-v1/snow-ik-25519-chachapoly-sha256")) {
        console.error("browser-smoke: missing noise contract line");
        failed = true;
        break;
      }
      console.log("browser-smoke: PASS — Chrome reported B-1 frozen contracts green");
      console.log(payload.log);
      break;
    }
    if (
      (payload.status || "").includes("FAIL") &&
      payload.log &&
      !payload.log.includes("Instantiating")
    ) {
      console.error("browser-smoke: page reported FAIL while loading");
      console.error(payload.log);
      failed = true;
      break;
    }
    await sleep(250);
  }
  if (!failed && Date.now() >= deadline) {
    console.error("browser-smoke: timeout waiting for lyteB1Passed");
    failed = true;
  }
  ws.close();
} finally {
  chromeProc.kill("SIGTERM");
  server.close();
  await rm(userData, { recursive: true, force: true });
}

process.exit(failed ? 1 : 0);
