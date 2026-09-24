# Architecture

This page describes the current code: packages, targets, dependency
direction, per-role data flow, thread ownership, and where each concept
lives. The rules that keep it this way are in [AGENTS.md](../AGENTS.md);
the wire contract is in [PROTOCOL.md](PROTOCOL.md).

## Packages

Six SwiftPM packages (tools version 6.0). Each one builds and tests on its
own; siblings are referenced by relative path, so a checkout must keep them
side by side.

| Package | Directory | Role |
|---|---|---|
| `LyteCommon` | `Common/` | Shared sans-IO policy, shared OS adapters, pinned Opus, shared test equipment |
| `LyteWire` | `Wire/` | The protocol: codecs, crypto, FEC, ARQ, state machines, frozen vectors |
| `LyteHost` | `Host/` | Host role: pure host policy, session execution, Linux capture/encode/input leaves |
| `Lyte` | `Client/` | Client role: pure client policy, sans-IO initiator, macOS transport, app, CLI, helper |
| `LyteClientBrowser` | `Browser/` | Browser client: sans-IO browser core plus the JavaScriptKit bridge and page |
| `LyteSystemTests` | `SystemTests/` | Tests that compose the real client and host roles; no production code |

Dependency direction (arrows point at what is imported):

```text
Browser ──► Client ──► Wire ──► Common
   │  (tests only)       ▲
   └──► Host ────────────┘
SystemTests ──► Client, Host, Wire, Common      (tests only)
```

Client never depends on Host and Host never depends on Client. Only
`SystemTests` and the Browser test target compose both roles.

## Targets

**Common**

| Target | Kind | Owns |
|---|---|---|
| `LyteCore` | sans-IO | Conductor (`VideoBeatConductor`, `ConductorPrimitives`), renderer-handoff policy, Annex-B/HEVC bit helpers, `Sha256`, `Histogram`, `Deque`/`BoundedRing`, hex, `WireTos` |
| `LyteIO` | adapter | `SystemMonotonicClock` and other shared OS adapters |
| `COpus` | C leaf | Opus 1.6.1, pinned source ([UPSTREAM.md](../Common/Sources/COpus/UPSTREAM.md)) |
| `LyteTestKit` | test kit | `RepositorySourceTree`, `SwiftSourceScanner`, the lints' equipment |

**Wire**

| Target | Kind | Owns |
|---|---|---|
| `LyteWire` | sans-IO | Envelope, channels, CTRL registry, FEC, ARQ, Noise, CPace pairing, retry cookie, capabilities, lifecycle, beacon/feedback, video packetizer/assembler, audio framer/depacketizer, bulk and clipboard engines |
| `CNanorsWire` | C leaf | Reed-Solomon GF(2⁸) (nanors), reached only through `Fec/NanorsBackend.swift` |
| `LyteWireTestKit` | test kit | Vector loaders, `SimNet`, `SplitMix64`, `SealedCtrlPeer`, transfer harnesses |
| `LyteWireVectorGen` / `LyteWireVectorGenTool` | builders / CLI | Every `Wire/Vectors/*.json` builder; the `lyte-wire-vectorgen` product |

**Host** (targets marked Linux build only on Linux)

| Target | Kind | Owns |
|---|---|---|
| `HostCore` | sans-IO | HEVC parameter-set and slice-header writers ("pens"), `Pacer`, kernel-pressure governor, `HostServiceLoop`, audio tripwire, quiet-video pacer, screen sampling cadence |
| `HostSession` | sans-IO | Responder policy: `HandshakeGate` (rate limit, retry cookies), lifecycle lane, path validation |
| `HostWire` | sans-IO | `Session` (Noise responder, sealing, ARQ lanes, beacons), `VideoChannel` (packetize, FEC, repair store), `RateEstimator`, `SocketOutbox`, `VideoAdmissionGate`, encoder VBV/HRD policy, pairing responder, client keystore |
| `HostWireTestKit` | test kit | `HostSessionHarness`: a shipping `Session` in virtual time for the gate tests |
| `HostIO` | adapter | `HostPaths` (XDG layout, legacy identity adoption), `SecretFile`, `BulkFileStore` |
| `HostAudio` | policy | 5 ms hard-CBR Opus over `COpus` |
| `HostEye` | Linux | Direct Eye: DRM scanout import, GPU pixel fingerprint, NV12/AYUV EGL blit, VAAPI encoder seat, cursor plane |
| `CDRM` `CGBM` `CEGL` `CVA` `CPipeWire` `CDBus` `CNvEnc` `CCuda` | Linux module maps | System libraries; `CNvEnc` vendors `nvEncodeAPI.h` |
| `CPipeWireAudio` `CNetIO` `CInputUinput` | Linux C leaves | Default-sink monitor capture; UDP sockets (`sendmmsg`/`recvmmsg`, TOS, timestamps); uinput devices |
| `lyte-host` | Linux exe | The host composition root (`HostApplication`) |
| `lyte-control-peer` | exe (macOS + Linux) | DRM-free `HostWire.Session` peer for the browser proof |
| `lyte-eye`, `lyte-nvenc` | Linux exe | Direct Eye probe; banked NVENC probe |
| `lyte-netio-check`, `lyte-pace-check`, `lyte-audio-check`, `lyte-uinput-check` | Linux exe | On-host verification harnesses |

**Client**

| Target | Kind | Owns |
|---|---|---|
| `LyteClientCore` | sans-IO | Dependency-free client policy: `RoamingPolicy`, `RadioHoldPolicy`, `MacEvdevKeyMap`, `LinkHealthMeter` |
| `LyteClientSession` | sans-IO | The initiator shared by native and browser shells: handshake/retry (`ClientHandshakeInitiator`), pairing, capabilities, lifecycle, IDR recovery, beacon echo, carriage and conn-id books, clipboard/cursor/audio-routing/media-posture sessions |
| `LyteTransport` | macOS IO | `LyteUdpSession` (shell) and `LyteUdpSessionCore` (locked core), UDP endpoint, demux, ARQ endpoints, video pipeline, renderer handoff, audio receiver and player, input, feedback, pairing, discovery, identity, stats formatter |
| `LyteCorpus` | diagnostic | Corpus frames and gates, PSNR/SSIM, readback tap, synthetic motion reference |
| `LyteUI` | AppKit shims | Control-strip policy, pasteboard sync, video layer view |
| `LyteHelperProtocol` / `LyteHelperSecurity` | helper | XPC contract; code-requirement derivation |
| `LyteClientTestKit` | test kit | Client test equipment (`ScriptedHost`, `ClientCoreHarness`) |
| `Lyte` | app | SwiftUI app: `ConnectionModel`, windows, input capture, diagnostics |
| `lyte-cli` | exe | `wire-view`, `wire-pair`, `wire-discover`, corpus and decode probes |
| `lyte-helperd` | exe | Root launchd helper that holds `awdl0` down while streaming |

**Browser**

| Target | Kind | Owns |
|---|---|---|
| `LyteClientBrowserCore` | sans-IO | `BrowserControlSession` over `LyteClientSession`, `BrowserVideoPlayout`, `BrowserAudioPlayout`, frozen-contract checks |
| `LyteClientBrowser` | WASM exe | `BrowserBridge`: the `globalThis.lyteBrowser` JS↔WASM API (JavaScriptKit) |

Page JavaScript (`Browser/Page/`) owns WebTransport IO, WebCodecs decode,
WebGPU present, the AudioWorklet ring and DOM input. `Browser/Scripts/`
holds the build, serve and smoke harness and the WebTransport↔UDP sidecar.

## Data flow

### Host (Linux)

```text
KMS scanout ─► HostEye.EyePipeline ─► VAAPI HEVC (HostCore pens)
   60 Hz beat: import, GPU fingerprint, blit, encode (DirectEyeLeg)
        │ access unit
        ▼
HostWire.Session.sendFrame ─► VideoChannel: packetize + RS-FEC ─► Pacer (seq + seal on release)
        ▲                                                        │
PipeWire monitor ─► HostAudio Opus 5 ms ─► AudioFramer (RS 4+2) ─┤
                                                                 ▼
                                   SocketOutbox ─► CNetIO sendmmsg (per-class TOS)
CNetIO recvmmsg ─► Session.receive: unseal, ARQ, feedback ─► RateEstimator,
                   input ─► uinput, clipboard ─► Mutter RD, files ─► HostIO
```

Capture is change-driven: unchanged pixels encode nothing; a still screen is
kept warm by re-encoding the retained frame about once a second (longer under
an announced quiet video posture). Rate changes are encoder directives
applied on the next frame without a reset or IDR. The encoder's HRD buffer is
bounded so a frame at the rate ceiling fits one FEC group, and pre-encode
admission skips a changed frame while queued video already holds its latency
budget.

Without `--seconds` or `--pair`, `lyte-host --wire-listen` is a service: it
serves sessions in turn in one process. The listening socket, Avahi
advertisement, uinput devices, clipboard leaf and the EGL/DRM context stay
up; each client gets a fresh `SessionWire`, `AudioWire` and encoder stream
(first frame an IDR). A failed session or a display mode change exits the
process and systemd restarts it (`HostServiceLoop`).

### Client (macOS)

```text
UdpReceiveEndpoint (receive thread, SO_TIMESTAMP_MONOTONIC)
  └─► ReceiveDemux: Envelope.openDatagram (decode + unseal)
        ├─ chan 0/8 ─► ReliableCtrlEndpoint (ARQ) ─► LyteClientSession decisions
        ├─ chan 2   ─► LyteVideoPipeline: VideoAssembler ─► NackPolicy / IdrRequester
        │                 └─► sampleQueue: CMSampleBuffer ─► VideoRendererHandoff
        │                       └─► delivery queue: VideoBeatConductor ─► AVSampleBufferVideoRenderer
        └─ chan 1   ─► AudioReceiver (depacketize, jitter buffer)
                          └─► LyteAudioPlayer pump ─► SPSC ring ─► AVAudioEngine
TransportSender ─► feedback (chan 3), beacon echoes, input, IDR requests, ARQ
```

### Browser

```text
Chrome WebTransport datagrams ◄─► lyte-wt-sidecar (opaque relay) ◄─► UDP peer
page: session-pump.js ─► lyteBrowser.controlIngestBatch ─► BrowserControlSession
      ─► BrowserVideoPlayout (assemble, Conductor) ─► mediaTakeAnnexB ─► WebCodecs ─► WebGPU
      ─► BrowserAudioPlayout ─► audioPopPacket ─► WebCodecs Opus ─► AudioWorklet ring
      DOM input ─► controlSendInput ─► sealed CTRL
```

The sidecar never sees plaintext: Noise and pairing run end to end between
the WASM initiator and the host. See [BROWSER.md](BROWSER.md) for what the
browser path proves today.

## Thread and queue ownership

| Where | Owner | Notes |
|---|---|---|
| Host `SessionWire` | one `NSLock` over `Session` and the outbox | Pacer insertion, release (chan-2 seq and seal) and flush keep one order |
| Host capture | `DirectEyeLeg` capture thread | Calls `sendFrame`; reads one leg snapshot per poll |
| Host audio | 5 ms audio thread (SCHED_RR when granted) | Publishes into a mailbox; never waits on the session lock |
| Host sender | SCHED_RR sender thread | `ppoll` on its eventfd, the sockets and the next session timer |
| Host janitor | 10 ms service thread | Clipboard, bulk files, audio routing, pairing outcomes |
| Client receive | `UdpReceiveEndpoint` thread | Decode, unseal and demux inline |
| Client core | `LyteUdpSessionCore` lock | ARQ, control decisions and books; callbacks run outside it |
| Client video | `sampleQueue`, then the handoff's delivery queue | Sample build off the receive thread; renderer enqueue off the main thread |
| Client audio | pump timer thread + render callback | The render callback only reads the lock-free ring |
| Client UI | `@MainActor` | `ConnectionModel` and views |
| Sans-IO targets | caller | Single-threaded values; time and randomness are injected |

## Where concepts live

| Concept | Owner |
|---|---|
| Wire bytes, registries, limits | `LyteWire` + [`Wire/Vectors/`](../Wire/Vectors/README.md) |
| Playout timing (the Conductor) | `LyteCore/VideoBeatConductor.swift`; decision record [Conductor](decisions/20260803-050422-metronome-playout-design.md) |
| Congestion control | `HostWire/RateEstimator.swift` (host decides; client reports on chan 3) |
| Send priority and pacing | `LyteWire/ChannelId.swift` (`WirePriority`), `HostCore/Pacer.swift` |
| Capture damage truth | `HostEye/EyePipeline.swift` (pixel fingerprint); record [pixel observation](decisions/20260805-084033-direct-eye-pixel-observation.md) |
| Color | BT.709 limited range: `HostEye/EyeGL.swift` blit, VUI in `HostCore/HevcParameterSets.swift` |
| Host session loop | `HostCore/HostServiceLoop.swift`, `lyte-host/HostApplication.swift` |
| Host paths and identity | `HostIO/HostPaths.swift`; runbook in [OPERATIONS.md](OPERATIONS.md) |
| Client initiator | `LyteClientSession` (native and browser) |
| Roaming | `LyteClientCore/RoamingPolicy.swift`, `Lyte/ConnectionModel+Roaming.swift` |
| Input forwarding | `Lyte/InputForwardingPolicy.swift` (held-key release, ⌘ lone-Super suppression) |
| Pairing PIN | `LyteWire` `PairingPin.normalize` (exactly six ASCII digits) |
| Sans-IO law | `Common/Tests/LyteTestKitTests/SansIOArchitectureTests.swift` |

## Hot paths

- **Host per frame:** fingerprint and blit on the GPU, VAAPI encode, one
  Annex-B walk, packetize into ≤ 1112 B shards and RS parity off the lock,
  pacer insertion under it; each pacer release takes the next chan-2 seq
  and seals, one quantum at a time, then `sendmmsg`.
- **Host per datagram in:** `recvmmsg`, open (AEAD with the header as AAD),
  ARQ or feedback ingest, all under the session lock.
- **Client per datagram:** kernel stamp, envelope decode and unseal outside
  the demux lock, assembler insert under the pipeline lock.
- **Client per frame:** sample build on `sampleQueue`, Conductor schedule and
  renderer enqueue on the delivery queue.
- **Browser per burst:** one packed `Uint8Array` into WASM per batch; quiet
  ticks return `null`.
