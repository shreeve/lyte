// Browser-edge WebTransport datagram pump for B-2.
// Carrier only: moves opaque bytes. LyteWire / Noise stay in WASM.

const LYTE_BUDGET = 1152;

function hexFromBytes(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function bytesFromHex(hex) {
  const clean = hex.replace(/\s+/g, "").toLowerCase();
  if (clean.length % 2 !== 0) throw new Error("odd hex length");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function echoOnce(writer, reader, payload, attempts = 40, waitMs = 40) {
  const inbound = reader.read().then((r) => r.value);
  let echoed;
  for (let a = 0; a < attempts && !echoed; a++) {
    await writer.write(payload);
    echoed = await Promise.race([
      inbound,
      sleep(waitMs).then(() => undefined),
    ]);
  }
  return echoed;
}

async function measureCeiling(writer, reader, maxProbe = 1600) {
  let lo = 1;
  let hi = maxProbe;
  let best = 0;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const payload = new Uint8Array(mid);
    payload[0] = 0xa5;
    payload[mid - 1] = 0x5a;
    for (let i = 1; i < mid - 1; i++) payload[i] = i & 0xff;
    const echoed = await echoOnce(writer, reader, payload, 20, 50);
    const ok =
      echoed &&
      echoed.length === mid &&
      echoed[0] === 0xa5 &&
      echoed[mid - 1] === 0x5a;
    if (ok) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

function verifyViaWasm(kind, sentHex, recvHex) {
  const fn = globalThis.lyteBrowser?.verifyCarrierEcho;
  if (typeof fn !== "function") {
    return { passed: false, detail: "lyteBrowser.verifyCarrierEcho missing" };
  }
  const result = fn(kind, sentHex, recvHex);
  return {
    passed: !!result?.passed,
    detail: result?.detail || result?.lines || "no detail",
    lines: result?.lines || "",
  };
}

/**
 * Dial the same-box sidecar, round-trip opaque Lyte-shaped datagrams through
 * WebTransport↔UDP, measure the usable ceiling, and ask WASM to verify bytes.
 */
export async function runWebTransportCarrierProof(meta) {
  if (!meta?.url || !meta?.hashHex) {
    throw new Error("wt-sidecar metadata missing url/hashHex");
  }
  if (typeof WebTransport !== "function") {
    throw new Error("WebTransport API unavailable in this browser");
  }

  const hash = bytesFromHex(meta.hashHex);
  const wt = new WebTransport(meta.url, {
    serverCertificateHashes: [{ algorithm: "sha-256", value: hash }],
  });
  await wt.ready;

  const reportedMax = wt.datagrams.maxDatagramSize;
  const writer = wt.datagrams.writable.getWriter();
  const reader = wt.datagrams.readable.getReader();

  const lines = [];
  const checks = [];

  // 1) Frozen envelope framing bytes (opaque to the sidecar).
  const envelopeHex =
    globalThis.lyteBrowser?.envelopeVectorHex ||
    "020034120d0c0b0a080706050403020188776655443322116c797465";
  const envelopeSent = bytesFromHex(envelopeHex);
  const envelopeRecv = await echoOnce(writer, reader, envelopeSent);
  const envelopeHexRecv = envelopeRecv ? hexFromBytes(envelopeRecv) : "";
  const envelopeCheck = verifyViaWasm(
    "envelope",
    envelopeHex,
    envelopeHexRecv
  );
  checks.push(envelopeCheck.passed);
  lines.push(
    envelopeCheck.passed
      ? `PASS  wt-carrier/envelope-echo — ${envelopeCheck.detail}`
      : `FAIL  wt-carrier/envelope-echo — ${envelopeCheck.detail}`
  );

  // 2) Frozen Noise IK message-1 ciphertext (opaque sealed bytes).
  const noiseHex = globalThis.lyteBrowser?.noiseMsg1CiphertextHex;
  if (noiseHex) {
    const noiseSent = bytesFromHex(noiseHex);
    const noiseRecv = await echoOnce(writer, reader, noiseSent);
    const noiseHexRecv = noiseRecv ? hexFromBytes(noiseRecv) : "";
    const noiseCheck = verifyViaWasm("noise-msg1", noiseHex, noiseHexRecv);
    checks.push(noiseCheck.passed);
    lines.push(
      noiseCheck.passed
        ? `PASS  wt-carrier/noise-msg1-echo — ${noiseCheck.detail}`
        : `FAIL  wt-carrier/noise-msg1-echo — ${noiseCheck.detail}`
    );
  } else {
    checks.push(false);
    lines.push("FAIL  wt-carrier/noise-msg1-echo — ciphertext hex missing from WASM bridge");
  }

  // 3) Full Lyte wire budget (1152 B) of opaque patterned bytes.
  const budget = Number(globalThis.lyteBrowser?.wireBudgetBytes) || LYTE_BUDGET;
  const budgetPayload = new Uint8Array(budget);
  for (let i = 0; i < budget; i++) budgetPayload[i] = (i * 7 + 13) & 0xff;
  const budgetRecv = await echoOnce(writer, reader, budgetPayload, 50, 40);
  const budgetOk =
    !!budgetRecv &&
    budgetRecv.length === budget &&
    budgetRecv.every((b, i) => b === budgetPayload[i]);
  checks.push(budgetOk);
  lines.push(
    budgetOk
      ? `PASS  wt-carrier/budget-${budget} — opaque ${budget} B round-tripped via WT↔UDP`
      : `FAIL  wt-carrier/budget-${budget} — echo missing or corrupted (got ${budgetRecv?.length ?? 0} B)`
  );

  // 4) Measure usable ceiling (Chrome's reported maxDatagramSize can be conservative).
  const measuredCeiling = await measureCeiling(writer, reader);
  const ceilingOk = measuredCeiling >= budget;
  checks.push(ceilingOk);
  lines.push(
    ceilingOk
      ? `PASS  wt-carrier/ceiling — measured ${measuredCeiling} B ≥ Lyte budget ${budget} B (reported maxDatagramSize=${reportedMax})`
      : `FAIL  wt-carrier/ceiling — measured ${measuredCeiling} B < Lyte budget ${budget} B (reported maxDatagramSize=${reportedMax})`
  );

  try {
    wt.close({ closeCode: 0, reason: "b2-done" });
  } catch {
    /* ignore */
  }

  const passed = checks.every(Boolean);
  return {
    passed,
    lines: lines.join("\n"),
    reportedMaxDatagramSize: reportedMax,
    measuredCeiling,
    lyteBudgetBytes: budget,
    adapter: meta.adapter || "lyte-wt-sidecar",
    url: meta.url,
  };
}

export async function loadSidecarMeta(url = "./wt-sidecar.json") {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) {
    throw new Error(`wt-sidecar.json HTTP ${res.status}`);
  }
  return res.json();
}
