# Browser client direction

*Living direction for the peer **browser client platform**. Commissioning
start and frozen naming/carrier/ladder:
[`20260807-021425-browser-client-platform-slice.md`](20260807-021425-browser-client-platform-slice.md).
Not a protocol amendment.*

Lyte should make a host reachable from an ordinary browser without forking
the product into a second client. The browser is another platform shell —
beside Mac, Windows, and Linux — around the same independently owned wire
contracts, Noise security, session policy, and Conductor that native clients
use. The platform adapter target is `LyteClientBrowser` (package
`Browser/`); product composition lands later as `LyteBrowserApp` under
`Applications/`.

## What is proven

`LyteWire` is already a real WebAssembly target. Its complete suite passes
under wasmtime on `wasm32-unknown-wasip1` (`Wire/Scripts/wasm-test.sh`),
including the frozen vectors, Noise, pairing, FEC, ARQ, and media contracts.
That proves protocol portability; it is **not** the browser client.

**B-1 is green in Chrome:** `Browser/` builds `LyteClientBrowser` with the
official Swift 6.3.3 Wasm SDK and JavaScriptKit PackageToJS, loads it in
Google Chrome, and exercises two frozen wire contracts across the
JavaScript boundary:

- `envelope-v1/nominal-video-shard` — decode + re-encode byte match
- `noise-v1/snow-ik-25519-chachapoly-sha256` — IK message 1+2 byte match

**B-2 is green in Chrome:** the same page dials a same-box
`lyte-wt-sidecar` (`Browser/Scripts/wt-sidecar.mjs`, Node
`rwebtransport`) and round-trips **opaque** Lyte-shaped datagrams over
WebTransport:

- frozen envelope framing bytes survive WT↔UDP echo
- frozen Noise IK message-1 **ciphertext** survives as opaque bytes (sidecar
  never unseals)
- full `WireBudget.maxDatagramByteCount` (1152 B) round-trips
- measured usable ceiling **1214 B** ≥ 1152 B (Chrome's reported
  `maxDatagramSize` was 1024 — treat runtime measure as truth)

**B-3 is green in Chrome:** the WASM initiator completes a **control-only**
session against a DRM-free `lyte-control-peer` (real `HostWire.Session`)
through the sidecar in `--udp-peer` mode:

- Noise IK handshake (end-to-end; sidecar stays opaque)
- PIN PAKE pairing (`PairingPakeInitiator` ↔ `PairingResponderService`)
- capability declaration / agreement via `LyteClientSession`
- typed `SessionTeardown`
- peer has no Direct Eye (safe beside standing 41151)

**B-4 is green in Chrome:** one **timestamped** canned HEVC IRAP from the
frozen Wire corpus (`video-corpus-v1/frame-000-idr.annexb`, staged by
`build.sh`) is classified in WASM (`AnnexBCheck`), decoded with **WebCodecs**
(`hev1.1.6.L150.B0`, hardware prefer), and presented with **WebGPU**
(`importExternalTexture` → `<canvas>`). This is **not** live Conductor
video and **not** host-emitted media over WT — those are B-5. The control
plane from B-3 stays in the same proof page.

Logical packets stay transport-independent:

```text
Lyte packet → native: UDP | browser: WebTransport datagram
```

WebTransport is **not** raw UDP. It is the browser-safe QUIC/HTTP3 path
(datagrams ≈ unreliable unordered delivery; TLS and congestion control
built in). QUIC congestion control is less free than raw UDP — do not
pretend otherwise. Native Lyte keeps custom UDP.

Page JavaScript can call back into WASM via
`globalThis.lyteBrowser.runFrozenContracts()`,
`verifyCarrierEcho(...)`, `controlOpen` / `controlBegin` / `controlIngest`
/ `controlTick` / `controlTeardown`, `classifyAnnexBHex(...)`, and related
helpers. Headless gate: `Browser/Scripts/smoke-chrome.sh` (needs GPU —
does not pass `--disable-gpu`).

This does **not** yet prove live Conductor-driven video, FEC reassembly of
host shards over WT, or a Direct Eye session against pup's standing host.

The client policy boundaries are moving in the same direction:
`LyteClientCore` and `LyteClientSession` now compile on Linux with warnings as
errors. A browser shell must consume those IO-free boundaries rather than
reimplementing their policy in JavaScript. B-3 wires `LyteClientSession`
into the WASM control initiator for capabilities / lifecycle. B-4 keeps
HEVC decode/present in page JS (platform ports) and Annex-B classification
in `LyteCore`.

## Run B-1 … B-4 locally (Chrome)

Pins match the Wire wasm leg: swiftly toolchain **6.3.3** + SDK
`swift-6.3.3-RELEASE_wasm` (install commands in
`Wire/Scripts/wasm-test.sh` / `Browser/Scripts/build.sh`).

```sh
# From the repository root
Browser/Scripts/build.sh          # stages Browser/.serve/ (+ corpus IRAP)
Browser/Scripts/serve.sh          # http://127.0.0.1:8765/ + control-peer + wt-sidecar
# Open that URL in Google Chrome — expect PASS for B-1 + control-session/*
# and frame-present/* (WebCodecs + WebGPU).

# Headless gate (system Chrome + node + openssl + Xcode swift; needs GPU)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Browser/Scripts/smoke-chrome.sh
```

`serve.sh` / `smoke-chrome.sh` start:

1. `lyte-control-peer` on a fresh loopback UDP **41xxx** port (never 41151)
2. `lyte-wt-sidecar --udp-peer 127.0.0.1:<that-port>`
3. static file server for `.serve/`

`build.sh` uses PackageToJS `--use-cdn` so the WASI browser shim loads from
jsDelivr; no local `npm install` is required for the served page. It also
copies `Wire/Vectors/video-corpus-v1/frame-000-idr.annexb` into `.serve/`
for the B-4 fixture (not duplicated in `Browser/` git). The B-2 sidecar
installs `rwebtransport` under `Browser/Harness/` on first run
(`node_modules/` is gitignored). The release wasm is large (~76 MB today;
swift-crypto/FoundationEssentials drag — recorded in the scoping doc, not
fought this slice). `wasm-opt` is optional and not required for the gate.

**Echo vs peer sidecar:** B-2 carrier echoes need the sidecar's built-in UDP
echo. B-3/B-4 need `--udp-peer`. The combined page SKIPs `wt-carrier/*` when
the sidecar is in peer mode (B-2 already landed) and runs the control
session plus the canned-frame proof.

**Safari:** deferred. Recent Safari may run the WASM proof page, but Safari
is not a B-1…B-4 gate. Fleet `serverCertificateHashes` constraints remain a
later concern. Do not block Chrome progress on Safari.

### Optional pup qualification (no DRM)

`lyte-control-peer` builds on Linux too. Against pup, bind a fresh 41xxx
port and point the Mac sidecar at it — do **not** displace standing
`lyte-host` on 41151 and do **not** start a second Direct Eye:

```sh
# on pup (after syncing Host/ Wire/ Common/)
cd ~/src/lyte-host
LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat \
  swift build -c release --product lyte-control-peer
./.build/release/lyte-control-peer \
  --listen 41234 --bind 0.0.0.0 --meta-out /tmp/lyte-b3-peer.json --seconds 300
# note PIN + hostStaticPublicKeyHex from the JSON / console

# on Mac — stage page, then sidecar forward to pup
Browser/Scripts/build.sh
# copy peer JSON fields into Browser/.serve/control-peer.json (or edit serve)
node Browser/Scripts/wt-sidecar.mjs --meta-out Browser/.serve/wt-sidecar.json \
  --udp-peer 10.0.0.232:41234
# serve .serve/ and open in Chrome with that meta + peer JSON
```

## Intended shape

```text
WebTransport datagrams
        │
        ▼
dedicated worker: browser IO + Lyte WASM
Noise · FEC · reassembly · session policy · Conductor
        │
        ├── encoded video ──► WebCodecs VideoDecoder
        │                         │
        │                  GPU-backed VideoFrame
        │                         │
        │                         ▼
        │                  WebGPU ──► <canvas>
        │
        ├── encoded audio ──► decoder ──► AudioWorklet ring
        │
        └── control/input ◄── DOM events and Pointer Lock
```

The `<canvas>` is a GPU presentation surface, not a place to decode video or
copy every frame through JavaScript. The preferred video path is WebCodecs to
a GPU-backed `VideoFrame`, imported by WebGPU and rendered into the canvas.
That keeps scaling, color conversion, cursor composition, and overlays on the
GPU. Canvas 2D is acceptable for a diagnostic fallback, not the performance
architecture.

Protocol work, network pumping, and preferably rendering live off the browser's
main thread in a dedicated worker, using `OffscreenCanvas` where the selected
browser permits it. The main thread owns the page, permission gestures, and
input capture. Decoded frames are closed promptly; neither WebCodecs nor the
browser event loop is allowed to become a hidden latency buffer.

The Conductor remains the sole playout authority. It assigns presentation
times, absorbs correctable disturbances, and drops work that has missed the
score. Browser queues execute that policy; they do not replace it.

Audio follows the same rule. Decoded samples feed a small ring consumed by an
`AudioWorklet`, keeping audio callbacks off the main thread and giving the
Conductor an explicit clock boundary. Input maps DOM, wheel, keyboard, and
Pointer Lock events onto the existing typed Lyte messages.

## Carrier and security

Browsers cannot open Lyte's raw UDP socket. **WebTransport datagrams over
HTTP/3 are the frozen browser-edge carrier** (B-0 decision record): they
preserve unreliable, unordered datagram behavior without TCP head-of-line
blocking. A carrier adapter moves opaque Lyte envelopes between WebTransport
and the host's UDP session boundary.

**B-2/B-3 adapter decision: same-box sidecar** (`lyte-wt-sidecar`) for the
Chrome proof and local harness. Echo mode proves the carrier; `--udp-peer
host:port` forwards opaque datagrams to a real Lyte UDP peer (refuses
standing 41151). Pairing and Noise remain end-to-end between the browser's
WASM client and the host; the sidecar sees only ciphertext. An optional
in-process Linux host leaf remains a later packaging choice. Native UDP on
standing 41151 is untouched.

**B-3 host peer:** `lyte-control-peer` (Host package, macOS + Linux) wraps
`HostWire.Session` + `PairingResponderService` over plain UDP with **no**
Direct Eye — safe beside the standing DRM seat. Pup qualification uses the
same binary on a fresh 41xxx port.

Measured datagram ceiling must be consulted (and negotiated downward per
session if a future path falls short). Do not assume 1152 B from the Lyte
budget alone; do not treat Chrome's reported `maxDatagramSize` as the sole
truth without a measure.

## Codec posture

The browser reports what `VideoDecoder.isConfigSupported()` can actually
decode. Lyte uses a hardware-backed codec only after a truthful capability
intersection; it does not silently substitute a high-latency software decoder.
HEVC remains the native shipping path. Adding another browser codec is a
separate capability and frozen-vector decision, not an excuse to weaken or
fork that path.

## Boundaries

The browser client must not:

- invent a JavaScript copy of protocol or Conductor policy;
- add a plaintext or transport-trusted mode;
- make the host speak a second application protocol;
- decode or transform full video frames on the CPU as the normal path;
- accumulate an opaque browser buffer and call the resulting latency a
  cushion; or
- disturb native UDP behavior when browser support is absent or disabled.

## Commissioning ladder

Native harsh-path commissioning has earned this work. Advance through
independently testable slices (full matrix in the B-0 decision record):

| Stage | Proof |
|---|---|
| **B-0** | Naming, WebTransport carrier, capability matrix, ladder — **landed** |
| **B-1** | Load Lyte WASM in Chrome; exercise frozen contracts through the JS boundary — **landed** |
| **B-2** | Opaque datagram round-trip through the WebTransport adapter; measure datagram ceiling — **landed** |
| **B-3** | Pair, Noise, capabilities, control-only session — **landed** (HostWire peer; pup optional) |
| **B-4** | One timestamped frame through WebCodecs and WebGPU — **landed** (canned corpus IRAP) |
| **B-5** | Live Conductor-driven video — **next** |
| **B-6** | AudioWorklet, input, clipboard, product UI — browser client “done” |

Every slice keeps the native Mac/Linux gates and the WASM vector suite green.
Do not claim a streaming browser client before B-5.

## Historical detail

The dated [browser bridge consult](20260720-184200-browser-client-caddy-bridge.md)
and [browser viewer scoping](20260728-054139-lyte-browser-viewer-scoping.md)
preserve the original research, measurements, rejected alternatives, and
earlier slice estimates. They are frozen records. This page owns the current
direction when those records describe superseded repository structure or
pre-commissioning status.
