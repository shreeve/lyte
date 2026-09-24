# Browser client

The browser is meant to become another client platform beside macOS,
Windows and Linux: the same wire contracts, Noise security, session policy
and Conductor, reached through WebTransport instead of raw UDP. Naming,
carrier and ownership are fixed by the
[B-0 decision](decisions/20260807-021425-browser-client-platform-slice.md);
this page owns the current state.

**Status: a proof harness, not a product.** Chrome runs Lyte's Swift
WebAssembly client through a complete control, video, audio, input and
clipboard session, but only against `lyte-control-peer`, a DRM-free test
peer that replays the frozen video corpus and an Opus tone. No browser
session has streamed a real desktop from a host's Direct Eye yet.

## What exists

| Piece | Where | What it does |
|---|---|---|
| `LyteClientBrowserCore` | `Browser/Sources/` | Sans-IO browser session over `LyteClientSession`: handshake and msg1 retransmit, pairing, capabilities, lifecycle (liveness close, teardown retransmit), sealed CTRL, video assembly and Conductor schedule, IDR requests, audio depacketize, input and clipboard. Built natively and tested (`LyteClientBrowserCoreTests`, against an in-process `HostWire.Session`) |
| `LyteClientBrowser` | `Browser/Sources/` | The WASM executable: `globalThis.lyteBrowser`, the JS↔WASM bridge (JavaScriptKit) |
| Page | `Browser/Page/` | `session-pump.js` (WebTransport datagrams ↔ WASM), `video-sink.js` (WebCodecs decode, WebGPU present), `interaction.js` (DOM input, Opus decode, AudioWorklet), `audio-ring-worklet.js`, `session-proof.js` (the scripted proof), `webtransport-carrier.js`, `lyte-io.js`, `index.html` |
| `lyte-wt-sidecar` | `Browser/Scripts/wt-sidecar.mjs` | Same-box WebTransport ↔ UDP relay (Node, `rwebtransport`); opaque bytes only, one UDP socket per WebTransport session; refuses 41151 |
| `lyte-control-peer` | `Host/Sources/lyte-control-peer/` | A real `HostWire.Session` and pairing responder over UDP with no Direct Eye; `--emit-corpus` sends `video-corpus-v1` frames 000–009 and an Opus tone; `--sessions 0` serves sessions until killed |

Behavior the proof exercises today:

- Undecodable, forged, replayed or late datagrams are counted and dropped;
  they never fail the session. The connection id is learned only from
  authenticated datagrams.
- Message 1 is retransmitted verbatim (5 × 1 s); a rejected message 2 is
  skipped so a genuine one can still complete.
- The liveness timeout closes the session and sends a teardown; a local
  teardown is retransmitted until acknowledged.
- Video: FEC assembly, `VideoBeatConductor` schedule, WebCodecs HEVC
  (`hev1.1.6.L150.B0`, hardware preferred), WebGPU `importExternalTexture`
  to a canvas. Presentation is paced by the Conductor: frames decoded ahead
  of their beat are held until it, and none is shown before its PTS.
  Decode is throttled (at most 8 decoded or in-decoder frames); the decode
  backlog is bounded at 120 frames and the handoff at 12. Handoff overflow
  or backlog loss requests an IDR over sealed CTRL.
- Audio: WASM depacketizes Opus, WebCodecs decodes it, an AudioWorklet ring
  plays it in real time (the smoke renders offline). The WASM audio queue
  keeps the newest 20 packets (100 ms).
- Input: DOM keyboard (`KeyboardEvent.code` → evdev), pointer, buttons and
  wheel go out as sealed `InputEvent`s. Ctrl, Alt and Shift are forwarded;
  Meta stays local. A release of anything the host holds always crosses,
  chorded buttons are reconciled from `PointerEvent.buttons`, and held keys
  and buttons are released on blur. The peer echoes input but injects
  nothing.
- Clipboard text round-trips through capability key 10; the peer's
  clipboard is in memory, not an OS clipboard.

## Run it

Toolchain: swiftly with Swift 6.3.3 and the `swift-6.3.3-RELEASE_wasm` SDK
(pins and install commands: `Scripts/lib/wasm-toolchain.sh`), Google
Chrome with a GPU, Node 24 or 26, and `openssl`.

```sh
Browser/Scripts/build.sh     # WASM + page + corpus staged in Browser/.serve/
Browser/Scripts/serve.sh     # http://127.0.0.1:8765/ with control peer + sidecar
# open the URL in Chrome; Connect and Re-run work repeatedly

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Browser/Scripts/smoke-chrome.sh   # headless proof; rebuilds first
```

`serve.sh` builds `lyte-control-peer`, starts it on loopback UDP 41234
(`LYTE_CONTROL_PEER_PORT`, never 41151), starts the sidecar in
`--udp-peer` mode, and serves `.serve/`. `build.sh` uses PackageToJS with
`--use-cdn`, so the page loads the WASI shim from jsDelivr; the sidecar
installs `rwebtransport` under `Browser/Harness/` on first run. The module
is about 77 MB without binaryen's `wasm-opt` and behaves the same.

The smoke's PASS lines and what each asserts are listed in
[TESTING.md](TESTING.md#browser-smoke--browserscriptssmoke-chromesh). The
Browser package's native tests run in the macOS gate; the WASM build runs
there when the toolchain is installed. Neither needs Chrome.

The `serve.sh` harness always starts its own local peer. Pointing the page
at a peer on pup (a fresh 41xxx port, never 41151) needs a serve mode that
skips the local peer, which does not exist yet.

## Bridge API

`globalThis.lyteBrowser` exposes: `runFrozenContracts`,
`verifyEnvelopeHex`, `verifyCarrierEcho`, `classifyAnnexBBytes`,
`controlOpen`, `controlBegin`, `controlIngestBatch` (one packed
`Uint8Array` per burst), `controlTick` (`null` when quiet),
`controlTeardown`, `controlSendInput`, `controlClipboardSet`,
`controlFacts`, `mediaTakeAnnexB`, `mediaPopDue`, `mediaNotePresented`,
`mediaNoteDropped`, `mediaStats`, `audioPopPacket`, `interactionStats`,
plus the constants `conductorBeatMicroseconds`, `wireBudgetBytes` and the
frozen-contract vectors.

## Carrier

Browsers cannot open raw UDP. WebTransport datagrams over HTTP/3 are the
browser carrier: unreliable and unordered, with no TCP head-of-line
blocking, but with QUIC's own congestion control and TLS underneath, so
the path is less free than native UDP. Lyte envelopes cross it unchanged:

```text
Lyte packet → native: UDP datagram | browser: WebTransport datagram
```

Noise and pairing run end to end between the WASM client and the host; the
relay sees only ciphertext. Chrome measured a usable datagram ceiling of
1214 B (it reported `maxDatagramSize` 1024), above Lyte's 1152 B budget.
Consult the measured ceiling per session; do not trust the reported one
alone.

## Intended shape

```text
WebTransport datagrams
        │
        ▼
dedicated worker: browser IO + Lyte WASM
Noise · FEC · reassembly · session policy · Conductor
        │
        ├── encoded video ──► WebCodecs VideoDecoder ──► GPU VideoFrame ──► WebGPU ──► <canvas>
        ├── encoded audio ──► decoder ──► AudioWorklet ring
        └── control/input ◄── DOM events and Pointer Lock
```

Today everything runs on the page's main thread; moving protocol work and
rendering into a worker (with `OffscreenCanvas`) is part of the product
path. The canvas is a GPU presentation surface: no CPU decode or per-frame
copy through JavaScript on the normal path. The Conductor stays the only
playout authority; browser queues execute its schedule and never become a
hidden latency buffer.

## Codec posture

The browser reports what `VideoDecoder.isConfigSupported()` can decode.
Lyte uses a hardware-backed codec only after a truthful capability
intersection and never substitutes a slow software decoder. HEVC remains
the native path; another browser codec would be a separate capability and
frozen-vector decision.

## Boundaries

The browser client must not:

- copy protocol or Conductor policy into JavaScript;
- add a plaintext or transport-trusted mode;
- make the host speak a second application protocol;
- decode or transform full frames on the CPU as the normal path;
- accumulate an opaque browser buffer and call the latency a cushion; or
- disturb native UDP when browser support is absent or disabled.

## Commissioning ladder

"Landed" means the gate tests the claim. B-4 to B-6 are proven against the
control peer's corpus replay, not against a real desktop.

| Stage | Claim | Evidence |
|---|---|---|
| B-0 | Naming, carrier, capability matrix, ladder | decision record |
| B-1 | Lyte WASM runs in Chrome; frozen envelope and Noise vectors match across the JS boundary | smoke: `envelope-v1/*`, `noise-v1/*` |
| B-2 | Opaque datagrams round-trip through the WebTransport relay; ceiling measured | carrier echo proofs (skipped in peer mode) |
| B-3 | Noise, PIN pairing, capabilities, teardown against a real `HostWire.Session` | smoke: `control-session/*`; native tests |
| B-4 | One timestamped HEVC IRAP through WebCodecs and WebGPU | smoke: `frame-present/*` |
| B-5 | Sealed corpus video, FEC-assembled and presented on the Conductor's clock | smoke: `conductor-video/*` (paced, none early) |
| B-6 | Input, clipboard text, Opus to AudioWorklet | smoke: `session-input/echo`, `clipboard/*`, `audio/*`, `audio-worklet/ring`; DOM input is not driven by the headless smoke |

Next, toward a usable client ([TODO.md](../TODO.md)): live Direct Eye
against a real host, a persistent interactive session, Safari, and product
composition (`LyteBrowserApp`).

The original research, measurements and rejected alternatives are in the
[bridge consult](history/20260720-184200-browser-client-caddy-bridge.md)
and the [viewer scoping](history/20260728-054139-lyte-browser-viewer-scoping.md).
