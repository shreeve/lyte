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

Page JavaScript can call back into WASM via
`globalThis.lyteBrowser.runFrozenContracts()` (and
`verifyEnvelopeHex(...)`). Headless gate:
`Browser/Scripts/smoke-chrome.sh`.

This does **not** yet prove WebTransport, WebCodecs, rendering, or a
session against pup.

The client policy boundaries are moving in the same direction:
`LyteClientCore` and `LyteClientSession` now compile on Linux with warnings as
errors. A browser shell must consume those IO-free boundaries rather than
reimplementing their policy in JavaScript.

## Run B-1 locally (Chrome)

Pins match the Wire wasm leg: swiftly toolchain **6.3.3** + SDK
`swift-6.3.3-RELEASE_wasm` (install commands in
`Wire/Scripts/wasm-test.sh` / `Browser/Scripts/build.sh`).

```sh
# From the repository root
Browser/Scripts/build.sh          # stages Browser/.serve/
Browser/Scripts/serve.sh          # http://127.0.0.1:8765/
# Open that URL in Google Chrome — expect PASS for both contracts.

# Optional headless gate (system Chrome + node)
Browser/Scripts/smoke-chrome.sh
```

`build.sh` uses PackageToJS `--use-cdn` so the WASI browser shim loads from
jsDelivr; no local `npm install` is required for the served page. The
release wasm is large (~72 MB today; swift-crypto/FoundationEssentials drag
— recorded in the scoping doc, not fought this slice). `wasm-opt` is
optional and not required for the B-1 gate.

**Safari:** deferred. Recent Safari may run the WASM proof page, but Safari
is not a B-1 gate. WebTransport / `serverCertificateHashes` fleet constraints
remain a later concern (B-2+). Do not block Chrome progress on Safari.

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

The adapter is not a second protocol endpoint. Pairing and Noise remain
end-to-end between the browser's WASM client and the host; an optional bridge
must see only ciphertext. Whether that adapter is an optional Linux host leaf
or a same-box sidecar remains an explicit B-2 implementation decision. Its
real datagram ceiling must be measured and, if necessary, negotiated downward
per session rather than assumed.

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
| **B-2** | Opaque datagram round-trip through the WebTransport adapter; measure datagram ceiling — **next** |
| **B-3** | Pair, Noise, capabilities, control-only session against pup |
| **B-4** | One timestamped frame through WebCodecs and WebGPU |
| **B-5** | Live Conductor-driven video |
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
