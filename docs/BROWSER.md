# Browser client

The browser is meant to become another client platform beside macOS,
Windows and Linux: the same wire contracts, Noise security, session policy
and Conductor, reached through WebTransport instead of raw UDP. Naming,
carrier and ownership are fixed by the
[B-0 decision](decisions/20260807-021425-browser-client-platform-slice.md);
this page owns the current state.

**Status: a proof harness and a first viewer.** Chrome runs Lyte's Swift
WebAssembly client through a complete control, video, audio, input and
clipboard session against `lyte-control-peer`, a DRM-free test peer that
replays the frozen video corpus and an Opus tone. The [viewer](#viewer)
(`viewer.html`) holds a standing session through a same-origin
WebTransport relay and re-dials when it ends; it has not yet streamed a
real desktop from a host's Direct Eye.

## What exists

| Piece | Where | What it does |
|---|---|---|
| `LyteClientBrowserCore` | `Browser/Sources/` | Sans-IO browser session composed from the shared client policy in `LyteClientSession` and `LyteClientCore`: handshake, pairing, capabilities, lifecycle and blackout detector, beacon echo and host clock, exempt CTRL, chan-3 feedback, NACK repair and IDR recovery, video assembly and Conductor schedule, audio depacketize, input and clipboard. Built natively and tested (`LyteClientBrowserCoreTests`) against HostWireTestKit's shipping `HostWire.Session` and a scripted `SealedCtrlPeer` far end |
| `LyteClientBrowser` | `Browser/Sources/` | The WASM executable: `globalThis.lyteBrowser`, the JS↔WASM bridge (JavaScriptKit) |
| Page | `Browser/Page/` | `session-pump.js` (WebTransport datagrams ↔ WASM), `video-sink.js` (WebCodecs decode, WebGPU present), `interaction.js` (DOM input), `audio-playout.js` (Opus decode in the jitter buffer's pull order, AudioWorklet ring) and `audio-ring-worklet.js`, `session-proof.js` and `index.html` (the scripted proof harness), `viewer.js` and `viewer.html` (the [viewer](#viewer)), `lyte-io.js`, and `vendor/browser_wasi_shim/` (the pinned `@bjorn3/browser_wasi_shim` 0.4.1 build PackageToJS imports; MIT OR Apache-2.0) |
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
- Audio: WASM depacketizes Opus (FEC recovery included) into the native
  client's adaptive `AudioJitterBuffer`: reordered packets play in order,
  late ones drop and raise the target, a gap is waited out while audio
  still plays and concealed the moment the page would run dry, and a
  stall's burst re-centers. The page pulls verdicts under the shared
  `AudioRingFill` rule, reporting the audio it holds (the AudioWorklet
  ring's depth from its consumption reports plus packets still decoding);
  WebCodecs decodes, and the ring plays PCM in pull order, bounded at the
  200 ms ceiling WASM names. WebCodecs has no Opus loss concealment, so a
  concealed packet is the last sample decayed to silence over 2 ms. Until
  the page first pulls the buffer keeps only the newest target's worth.
  There is no WSOLA accelerate: depth above the target drains only through
  the jitter buffer's re-center at its hard cap. The smoke renders offline
  and requires non-silent frames in the rendered buffer.
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
- Audio posture: the browser declares key 9 and, as the native app does,
  asks for `hostMuted` when the host's first routing status differs, so
  the host's own speakers go quiet while the stream plays in the browser.
  It declares key 15, so an announced audio quiet is silence by contract:
  a dry page is not concealed, the blackout detector relaxes to its 2.5 s
  baseline, and the packet that wakes the track re-primes playout (native
  `BrowserAudioPostureTests`). Keys 13, 14, 16 and 17 are not declared:
  the browser does not execute them.

## Run it

Toolchain: swiftly with Swift 6.3.3 and the `swift-6.3.3-RELEASE_wasm` SDK
(pins and install commands: `Scripts/lib/wasm-toolchain.sh`), Google
Chrome with a GPU, Node 24 or 26, and `openssl`.

```sh
Browser/Scripts/build.sh     # WASM + page + corpus staged in Browser/.serve/
node Browser/Scripts/smoke.mjs --serve  # http://127.0.0.1:8765/ with control peer + sidecar
# open the URL in Chrome; Connect and Re-run work repeatedly;
# /viewer.html runs the viewer against the same peer

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

With `--serve` the script also writes `lyte-viewer.json` for its own
sidecar and peer, so `http://127.0.0.1:8765/viewer.html` runs the viewer
against the corpus replay. The harness always starts its own local peer;
a real host is reached through the viewer and a relay beside it.

## Viewer

`viewer.html` is the daily-driver entry: on load it fetches
`lyte-viewer.json` from its own origin, dials the relay, and shows the
desktop full-window. It is a separate entry so the smoke keeps its
scripted proof in `index.html`; a server that wants the viewer at `/`
serves `viewer.html` there.

```json
{
  "relayUrl": "https://desk.example.com/lyte",
  "hostStaticPublicKeyHex": "<64 hex digits: the host's Noise static public key>",
  "serverCertificateHashes": ["<SHA-256 of the relay's certificate, hex or base64>"],
  "pin": "246810"
}
```

| Key | Required | Meaning |
|---|---|---|
| `relayUrl` | yes | The WebTransport relay, `https:`; a path (`"/lyte"`) resolves against the page's origin |
| `hostStaticPublicKeyHex` | yes | The host's Noise static public key, 64 hex digits: the `noise: host static public key …` line `lyte-host` logs at start ([OPERATIONS.md](OPERATIONS.md)) |
| `serverCertificateHashes` | no | One string or a list: 64 hex digits (colons allowed) or base64/base64url of 32 bytes. Only for a relay with a self-signed certificate (Chrome caps those at 14 days); omit it for a CA-trusted relay, and the page then omits `serverCertificateHashes` from the WebTransport options |
| `pin` | no | Pair with this PIN; omitted or empty, the viewer connects unpaired, which a host that does not require pairing admits |

Behavior:

- A click or key unlocks audio (the autoplay policy) and focuses the
  canvas; keyboard, pointer and wheel then reach the host as in the
  harness. Until then the jitter buffer keeps only its newest target's
  worth.
- The status pill reads `Connecting…`, fades while live, and reads
  `Reconnecting in N s — <reason>` after a carrier EOF, a failed dial or
  handshake, a session failure (the liveness close included) or a host
  teardown. Each re-dial is a fresh session and Noise handshake. The first
  re-dial is immediate; the next ones climb the native dial ladder
  (`RoamingPolicyConfig`'s 2 s floor doubling to 30 s, read from WASM),
  which restarts after a session that stayed live past the floor.
- A session that ends lingers up to 300 ms so its teardown is
  acknowledged; on `pagehide` the teardown leaves at once and the carrier
  closes.
- Not yet: clipboard sharing, a fullscreen or Keyboard Lock control,
  Pointer Lock, a host-audio toggle, and the stats overlay.

What a relay host (Janus) serves on the page's origin, from
`Browser/.serve/` after `build.sh`:

| Path | Content-Type |
|---|---|
| `/` (or `/viewer.html`) → `viewer.html` | `text/html` |
| `viewer.js`, `audio-playout.js`, `audio-ring-worklet.js`, `interaction.js`, `lyte-io.js`, `session-pump.js`, `video-sink.js` | `text/javascript` |
| `index.js`, `instantiate.js`, `runtime.js`, `platforms/browser.js` (PackageToJS) | `text/javascript` |
| `vendor/browser_wasi_shim/*.js` | `text/javascript` |
| `LyteClientBrowser.wasm` | `application/wasm` (streaming compile needs it) |
| `lyte-viewer.json` | `application/json`, not cached (the relay's own config, not in `.serve/`) |

`corpus/`, `index.html`, `session-proof.js`, the `*.d.ts` and
`package.json` files, and the harness's `control-peer.json` and
`wt-sidecar.json` are not needed. Serving all of `.serve/` except
`corpus/` works too. No cross-origin isolation headers are required. The
relay itself accepts WebTransport over HTTP/3 at `relayUrl`, carries each
datagram opaquely to the host's UDP port and back, one UDP socket per
WebTransport session, as `lyte-wt-sidecar` does.

## Bridge API

`globalThis.lyteBrowser` exposes: `classifyAnnexBBytes`, `controlOpen`,
`controlBegin`, `controlIngestBatch` (one packed `Uint8Array` per burst,
each record carrying its datagram's age), `controlTick` (`null` when
quiet), `controlTeardown`, `controlSendInput`, `controlClipboardSet`,
`controlFacts`, `mediaTakeAnnexB` (`null`: skip the frame),
`mediaPopDue`, `mediaTakeAbandoned`, `mediaNotePresented`,
`mediaNoteDropped`, `mediaStats`, `audioPull` (a packet, a concealment,
or `null`: stop pulling), `interactionStats`, plus the constants
`conductorBeatMicroseconds`, `audioRingCeilingFrames` and
`audioPacketFrames`. A burst crosses the boundary as one copy into
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
| B-6 | Input, clipboard text, Opus to AudioWorklet | smoke: `session-input/echo`, `clipboard/*`, `audio/*`, `audio-worklet/ring` (samples played); native `BrowserInputTests`, `BrowserAudioPostureTests`, the audio cases of `BrowserPlayoutTests`; DOM input rules and audio pull order in `page.test.mjs`, not driven by the headless smoke |
| B-7 | A standing viewer session: config, re-dial ladder, teardown on stop | `page.test.mjs` (config parsing, WebTransport options, the ladder, re-dial after EOF and host close, teardown on stop) against fakes; no gate drives it in Chrome yet |

Next, toward a usable client ([TODO.md](../TODO.md)): the viewer through a
relay to a real host (or WebTransport on the host), live Direct Eye in
Chrome, Safari, and product composition (`LyteBrowserApp`).

The original research, measurements and rejected alternatives are in the
[bridge consult](history/20260720-184200-browser-client-caddy-bridge.md)
and the [viewer scoping](history/20260728-054139-lyte-browser-viewer-scoping.md).
