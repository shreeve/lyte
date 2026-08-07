# Browser client direction

*Living direction for the peer **browser client platform**. Commissioning
start and frozen naming/carrier/ladder:
[`20260807-021425-browser-client-platform-slice.md`](20260807-021425-browser-client-platform-slice.md).
Not a protocol amendment.*

Lyte should make a host reachable from an ordinary browser without forking
the product into a second client. The browser is another platform shell —
beside Mac, Windows, and Linux — around the same independently owned wire
contracts, Noise security, session policy, and Conductor that native clients
use. The platform adapter target is `LyteClientBrowser`; product composition
lands later as `LyteBrowserApp` under `Applications/`.

## What is proven

`LyteWire` is already a real WebAssembly target. Its complete suite passes 511
tests under wasmtime on `wasm32-unknown-wasip1`, including the frozen vectors,
Noise, pairing, FEC, ARQ, and media contracts. This proves that the bytes and
IO-free protocol machinery are portable; it does **not** yet prove browser
JavaScript interop, a browser event loop, WebTransport, WebCodecs, or rendering.

The client policy boundaries are moving in the same direction:
`LyteClientCore` and `LyteClientSession` now compile on Linux with warnings as
errors. A browser shell must consume those IO-free boundaries rather than
reimplementing their policy in JavaScript.

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
| **B-1** | Load Lyte WASM in an actual browser; exercise a frozen contract through the JavaScript boundary — **next** |
| **B-2** | Opaque datagram round-trip through the WebTransport adapter; measure datagram ceiling |
| **B-3** | Pair, Noise, capabilities, control-only session against pup |
| **B-4** | One timestamped frame through WebCodecs and WebGPU |
| **B-5** | Live Conductor-driven video |
| **B-6** | AudioWorklet, input, clipboard, product UI — browser client “done” |

Every slice keeps the native Mac/Linux gates and the WASM vector suite green.
The first browser proof is an integration of already-owned organs, not
permission to start a parallel implementation. Do not claim a streaming
browser client before B-5.

## Historical detail

The dated [browser bridge consult](20260720-184200-browser-client-caddy-bridge.md)
and [browser viewer scoping](20260728-054139-lyte-browser-viewer-scoping.md)
preserve the original research, measurements, rejected alternatives, and
earlier slice estimates. They are frozen records. This page owns the current
direction when those records describe superseded repository structure or
pre-commissioning status.
