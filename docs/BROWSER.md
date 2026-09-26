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
| `LyteClientBrowserCore` | `Browser/Sources/` | Sans-IO browser session composed from the shared client policy in `LyteClientSession` and `LyteClientCore`: handshake, pairing, capabilities, lifecycle and blackout detector, beacon echo and host clock, exempt CTRL, chan-3 feedback, NACK repair and IDR recovery, video assembly and Conductor schedule, audio depacketize, input and clipboard. Built natively and tested (`LyteClientBrowserCoreTests`) against HostWireTestKit's shipping `HostWire.Session` and a scripted `SealedCtrlPeer` far end |
| `LyteClientBrowser` | `Browser/Sources/` | The WASM executable: `globalThis.lyteBrowser`, the JS↔WASM bridge (JavaScriptKit) |
| Page | `Browser/Page/` | `session-pump.js` (WebTransport datagrams ↔ WASM), `video-sink.js` (WebCodecs decode, WebGPU present), `interaction.js` (DOM input, Opus decode, AudioWorklet), `audio-ring-worklet.js`, `session-proof.js` (the scripted proof), `lyte-io.js`, `index.html`, and `vendor/browser_wasi_shim/` (the pinned `@bjorn3/browser_wasi_shim` 0.4.1 build PackageToJS imports; MIT OR Apache-2.0) |
| `lyte-wt-sidecar` | `Browser/Scripts/wt-sidecar.mjs` | Same-box WebTransport ↔ UDP relay (Node, `rwebtransport` from `Browser/Harness/package-lock.json`); opaque bytes only, one UDP socket per WebTransport session, at most eight sessions; loopback unless `--allow-remote`; refuses to relay to 41151 |
| `lyte-control-peer` | `Host/Sources/lyte-control-peer/` | A real `HostWire.Session` and pairing responder over UDP with no Direct Eye; `--emit-corpus` sends `video-corpus-v1` frames 000–009 and an Opus tone; `--sessions 0` serves sessions until killed; `--stream-corpus` loops those frames at 60 fps, unpaired, under `--rate-mbps` and prints every rate move (the live rate-estimator rig, dialed by `lyte-cli wire-view --host-key`); `--quiet-after S` switches it S s in to the corpus's small P-frames at 10 fps, a quiet screen that sends no full delivery train |

The page executes; WASM decides. Every decode, presentation, recovery,
repair and latency verdict below is made by the core; the page decodes
what it is handed, shows what is due, and closes what it is told will
never be.

Behavior the proof exercises today:

- Undecodable, forged, replayed or late datagrams are counted and dropped;
  they never fail the session, nor does a malformed control word (an
  InputEcho included). The connection id is learned only from
  authenticated datagrams.
- Message 1 is retransmitted verbatim on the first-dial schedule
  (5 × 2 s); a rejected message 2 is skipped so a genuine one can still
  complete.
- Every datagram is stamped at its arrival in the page; the core reads
  that arrival for beacon t2, the Conductor and feedback dispersion, and
  its injected `now` for sends and timers.
- Lifecycle: the blackout detector runs at the native 2.5 s baseline and
  tightens to 350 ms on the first audio datagram; the liveness timeout
  closes the session and sends a teardown; a local teardown, and the
  teardown a capability failure or a poisoned ordered stream composes,
  is retransmitted until acknowledged, even after the session failed.
  Pairing and capability failures reach the page log as `FAIL` lines.
- Feedback: a chan-3 report every 40 ms carries per-channel receive
  ledgers (`SeqGapTracker`), arrival dispersion and queued NACK entries,
  so the host's estimator and freeze detector see a browser client as
  they see the native one.
- Repair: past-parity loss is NACKed through `ClientNackPolicy` in an
  immediate report; a live ask holds the frame's IDR for the repair
  window, and a host refusal (0x23) escalates to the IDR episode at once.
- Path: a host PathChallenge is answered at once with the sealed,
  conn-id-tagged PathResponse, so the host can migrate the session.
- Clock: closed beacon samples feed `ClientHostClock`; capture times map
  through its fit (a first-frame anchor covers only the time before the
  first sample), so clock skew does not read as path delay.
- Video: FEC assembly, `VideoBeatConductor` schedule, WebCodecs HEVC
  (`hev1.1.6.L150.B0`, hardware preferred), WebGPU `importExternalTexture`
  to a canvas backed at device pixels. The page presents on
  `requestAnimationFrame` when the Conductor says a frame is due: frames
  decoded ahead of their beat are held until it, and none is shown before
  its PTS. While an IDR episode is open only random-access frames are
  handed out for decode or marked presentable, a frame evicted from the
  decode backlog takes its dependents with it, and frames the handoff
  drops after being promised are reported so the page closes them.
  Decode is throttled (at most 8 decoded or in-decoder frames); the decode
  backlog is bounded at 120 frames and the handoff at 12.
- Audio: WASM depacketizes Opus and keeps the newest 20 packets (100 ms);
  WebCodecs decodes; an AudioWorklet ring plays it, bounded at the 200 ms
  ceiling WASM names. The smoke renders offline and requires non-silent
  frames in the rendered buffer.
- Input: DOM keyboard (`KeyboardEvent.code` → evdev, JIS Kana/Eisu to the
  native client's codes), pointer, buttons and wheel go out as sealed
  `InputEvent`s. Motion and mid-gesture scroll coalesce to the newest per
  pump beat; key and button edges leave at once and wait, in order,
  through a full reliable queue rather than being dropped; non-finite
  coordinates are refused. Ctrl, Alt and Shift are forwarded; Meta stays
  local, and volume keys are not forwarded (as in the native client). A drag that leaves the canvas is clamped to the stream's edge,
  chorded buttons are reconciled from `PointerEvent.buttons`, and held
  keys and buttons are released on blur. The peer echoes input but
  injects nothing.
- Clipboard text round-trips through capability key 10; the peer's
  clipboard is in memory, not an OS clipboard.

## Run it

Toolchain: swiftly with Swift 6.3.3 and the `swift-6.3.3-RELEASE_wasm` SDK
(pins and install commands: `Scripts/lib/wasm-toolchain.sh`), Google
Chrome with a GPU, Node 24 or 26, and `openssl`.

```sh
Browser/Scripts/build.sh     # WASM + page + corpus staged in Browser/.serve/
node Browser/Scripts/smoke.mjs --serve  # http://127.0.0.1:8765/ with control peer + sidecar
# open the URL in Chrome; Connect and Re-run work repeatedly

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Browser/Scripts/smoke-chrome.sh   # headless proof; rebuilds first
```

`smoke.mjs` builds `lyte-control-peer`, starts it on a fresh loopback UDP
port (`LYTE_CONTROL_PEER_PORT`, never 41151), starts the sidecar with
`--udp-peer`, and serves `.serve/`; with `--serve` the peer serves
sessions until Ctrl-C, the page listens on `LYTE_BROWSER_PORT` (8765) and
no Chrome starts. Nothing is fetched at page run time:
`build.sh` stages the vendored WASI shim and the page's import map
resolves it. The sidecar installs `rwebtransport` under `Browser/Harness/`
with `npm ci` on first run. The module is about 77 MB without binaryen's
`wasm-opt` and behaves the same.

The smoke's PASS lines and what each asserts are listed in
[TESTING.md](TESTING.md#browser-smoke--browserscriptssmoke-chromesh). The
Browser package's native tests run in the macOS and pup gates (off macOS
the manifest keeps only `LyteClientBrowserCore` and its suite, so Linux
never resolves JavaScriptKit); the WASM build runs in the macOS gate when
the toolchain is installed. Neither needs Chrome.

The harness always starts its own local peer. Pointing the page
at a peer on pup (a fresh 41xxx port, never 41151) needs a serve mode that
skips the local peer, which does not exist yet.

## Bridge API

`globalThis.lyteBrowser` exposes: `classifyAnnexBBytes`, `controlOpen`,
`controlBegin`, `controlIngestBatch` (one packed `Uint8Array` per burst,
each record carrying its datagram's age), `controlTick` (`null` when
quiet), `controlTeardown`, `controlSendInput`, `controlClipboardSet`,
`controlFacts`, `mediaTakeAnnexB` (`null`: skip the frame),
`mediaPopDue`, `mediaTakeAbandoned`, `mediaNotePresented`,
`mediaNoteDropped`, `mediaStats`, `audioPopPacket`, `interactionStats`,
plus the constants `conductorBeatMicroseconds` and
`audioRingCeilingFrames`. A burst crosses the boundary as one copy into
WASM memory and is sliced there.

## Carrier

Browsers cannot open raw UDP. WebTransport datagrams over HTTP/3 are the
browser carrier: unreliable and unordered, with no TCP head-of-line
blocking, but with QUIC's own congestion control and TLS underneath, so
the path is less free than native UDP. Lyte envelopes cross it unchanged:

```text
Lyte packet → native: UDP datagram | browser: WebTransport datagram
```

Noise and pairing run end to end between the WASM client and the host; the
relay sees only ciphertext, and every sealed datagram that crosses proves
the carrier opaque (its AEAD would fail otherwise). The page requires an
unreliable transport (no HTTP/2 fallback) and sets 100 ms incoming and
outgoing datagram max-age; the relay drops what its writer refuses and
anything that waited past 50 ms. The session keeps Lyte's 1152 B budget;
Chrome reports `maxDatagramSize` 1024 and the smoke carries near-budget
video shards inbound; a per-session ceiling measurement does not exist.

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
path, as are Pointer Lock and Opus loss concealment. The canvas is a GPU
presentation surface: no CPU decode or per-frame copy through JavaScript
on the normal path. The Conductor stays the only playout authority;
browser queues execute its schedule and never become a hidden latency
buffer.

## Codec posture

HEVC 4:2:0 is the only registered codec, so the browser declares
`.wireDefault` and opens a session only after
`VideoDecoder.isConfigSupported()` accepts hardware-preferred HEVC. Lyte
never substitutes a slow software decoder; another browser codec would be
a separate capability and frozen-vector decision.

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
| B-1 | Lyte WASM runs in Chrome; wire bytes match across platforms | smoke: every `control-session/*` line (Noise IK in Chrome's WASM); `Wire/Scripts/wasm-test.sh` (the whole Wire suite, vector files included, as WASM) |
| B-2 | Opaque datagrams cross the WebTransport relay | smoke: every sealed datagram of the session (AEAD-verified), near-budget video shards included |
| B-3 | Noise, PIN pairing, capabilities, feedback, teardown against a real `HostWire.Session` | smoke: `control-session/*`; native tests (`BrowserControlSessionTests`, `BrowserFailureTests`, `BrowserMediaPathTests`: feedback keeps the host out of FROZEN, a NACK draws a repair, a refusal escalates, a PathChallenge is answered, the clock map tracks skew) |
| B-4 | One timestamped HEVC IRAP through WebCodecs and WebGPU | smoke: `frame-present/*` |
| B-5 | Sealed corpus video, FEC-assembled and presented on the Conductor's clock | smoke: `conductor-video/*` (paced, none early); native `BrowserPlayoutTests` |
| B-6 | Input, clipboard text, Opus to AudioWorklet | smoke: `session-input/echo`, `clipboard/*`, `audio/*`, `audio-worklet/ring` (samples played); native `BrowserInputTests`; DOM input rules in `page.test.mjs`, not driven by the headless smoke |

Next, toward a usable client ([TODO.md](../TODO.md)): a relay to a real
host (or WebTransport on the host), live Direct Eye in Chrome, a persistent
interactive session, Safari, and product composition (`LyteBrowserApp`).

The original research, measurements and rejected alternatives are in the
[bridge consult](history/20260720-184200-browser-client-caddy-bridge.md)
and the [viewer scoping](history/20260728-054139-lyte-browser-viewer-scoping.md).
