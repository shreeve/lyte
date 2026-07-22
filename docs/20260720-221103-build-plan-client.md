# Lyte-UDP Build Plan — CLIENT (2026-07-20)

*The macOS-client half of the Lyte-UDP transition. Companions: the shared
protocol core-package plan (envelope codec, reliable sublayer, Noise/PAKE,
capability negotiation, message types — referenced here as "core:") and the
host plan. Governing docs: the decision record (20260720-215100), the
protocol overview + §6 addendum (20260720-193000), the four pillars
(20260720-19170{1,2,3,4}), the audio spec (20260720-145840). Where this plan
says "core: X", the interface is owned by the core package and consumed here;
this plan never redesigns it.*

## 0. Posture

The client's GameStream stack is frozen scaffolding: zero new work, kept
compiling only as the working Sunshine path during transition, **deleted the
moment Lyte-UDP streams end-to-end** (H0b/H1 target, H2 parity hard
deadline). Every slice below builds the Lyte-UDP path beside it, never
through it. The M5.5–M7 freeze thaws exactly once: the M7 audio receiver
lands inside H2, in its pinned order, against the Lyte-UDP audio channel —
it is the H2 audio deliverable, not a separate front.

## 1. Module map: reuse / delete / stays

**Reuse (proven interiors, new envelope around them):**

| Module | Status |
|---|---|
| `Video/VideoDepacketizer.swift` + `DecodeUnit` | Reuse. Annex-B reassembly, IDR/strict-loss state machine, NAL handling — soak-tested (M3: 310 s, 18,132 frames, zero skipped). Gets a thin input adapter from Lyte envelope entries; the Sunshine 8/24-byte frame-header parse is replaced by the core envelope's `frame` field. |
| `Video/VideoSampleFactory.swift` + `AVSampleBufferDisplayLayer` path (`LyteUI/VideoLayerView`) | Reuse unchanged. Codec-agnostic CMSampleBuffer construction; Rext 4:4:4 extends it (CL-15). |
| `CNanors` (vendored RS) | Reuse. Lyte-UDP FEC is deliberately nanors-compatible; new geometry (one block/frame, per-frame adaptive ratio from the `fec` field) replaces the GameStream 4-block/parity-patch dance. |
| `Audio/OpusDecoder.swift`, `Audio/AudioPlayer.swift` | Reuse as the H2 starting point; `AudioPlayer` is then rebuilt in place by M7 item 1 (SPSC ring); `OpusDecoder` swaps AudioConverter → libopus at M7 item 4. |
| Socket craft in `VideoStream`/`AudioStream` | Reuse the *lessons*, not the files: SO_RCVBUF sizing, `SO_NET_SERVICE_TYPE` VI/VO, `SO_TIMESTAMP`/SCM_TIMESTAMP kernel arrival stamps, ECONNREFUSED tolerance. These move into the new `LyteTransport` receive module. |
| Doctor, `Stats` plumbing, gap probes, AWDL helper (`lyte-helperd`), `HostHeadroom` | Reuse; new telemetry (clock residual, input-to-photon, D trajectory) extends `LyteSession.Stats` the same way. |
| `LyteUI/InputCapture.swift`, `MacKeyMap` | Reuse. AppKit event capture, ⌃⌥ lock chord, ⌘-passthrough list are wire-agnostic; only the packet encoder behind them changes (CL-9). Keymap table format decided with the host sibling; the ~80-entry VK map likely carries. |

**Delete (GameStream scaffolding — the §6 demolition list):** `Session/Rtsp.swift`,
`RtspHandshake.swift`, `Sdp.swift`, `ControlChannel.swift` (ENet),
`UdpPinger.swift`, `LaunchAPI.swift`; `HostAPI/` (NvHTTP, HostClient);
`Pairing/PairingSession.swift`; `Identity/ClientIdentity.swift` (cert
machinery; the Keychain generation lesson carries to Noise statics);
`Support/NvXML.swift`, GameStream halves of `CryptoPrimitives.swift`;
`Video/VideoPacket.swift` + `RtpVideoQueue.swift` (GameStream RTP framing,
streamPacketIndex, parity-header patching); `Audio/RtpAudioQueue.swift` +
AudioStream's AES-CBC/SS_PING halves; `Input/InputPackets.swift` NVCTL
encodings; `Vendor/enet` + the `CEnet` target.

**Stays (shared UI/app):** the whole `Sources/Lyte` SwiftUI shell
(ConnectView, ConnectionModel rewired at CL-7, ConnectionWindow, StreamView,
AgentMenu, DoctorPill, LyteCommands), `lyte-cli` (gains the H0b debug mode),
`Policy/`, `Store/ClientStore` (schema migrates: drop cert fields, keep
host/recents), `Discovery/` (service type changes), Scripts + signing
workflow.

## 2. Slice plan

Each slice is one commit-sized unit with a measurable gate. Effort: S ≈ a
session, M ≈ a day or two, L ≈ several days. "Deps" name core-package or
host deliverables.

| # | Era | Slice | Gate | Effort | Deps |
|---|---|---|---|---|---|
| CL-1 | H0b | `LyteTransport` receive skeleton: UDP socket (kernel stamps, big rcvbuf, VI class), envelope decode, (chan, u16 seq) demux with serial arithmetic, per-channel counters; `lyte-cli` debug subcommand | Decodes core test vectors byte-exact; counts live host datagrams on LAN | S | core: envelope codec + vectors |
| CL-2 | H0b | Video channel: `LyteVideoAssembler` (per-frame RS block from `fec` field, nanors decode) → adapter → existing depacketizer → factory → window | Renders canned datagram corpus, then live host video; 5% synthetic drop recovers via FEC | M | CL-1; host video sender |
| CL-3 | H0b | Minimal feedback: chan=3 per-packet arrival reports at 25–50 ms, NACK on FEC-impossible (immediate, geometry-triggered), 1 Hz beacon echo | Host estimator shows dispersion samples; forced loss produces NACKs the host honors | S | core: feedback/NACK/beacon formats |
| CL-4 | H0b | **Joint gate with host**: live host desktop rendered over LAN via pure Lyte-UDP | Glass-to-glass measured (capture-ts→photon via rough clock offset, cross-checked with a phone-camera ms-clock photo); soak ≥ 5 min clean | S | CL-1..3; host H0b complete |
| CL-5 | H1 | Discovery: `_lyte._udp` NWBrowser (TXT: identity hash, version, port); dual-browse with `_nvstream._tcp` until demolition | Lyte host appears in ConnectView beside Sunshine hosts; manual host:port still works | S | host advertises (Avahi) |
| CL-6 | H1 | Pairing: PIN SwiftUI flow rewired to PAKE; pinned static Noise keys in Keychain (`SecKeyCreateRandomKey(kSecAttrIsPermanent)` lesson; signed builds only) | Pair once, reconnect authenticates via Noise IK with zero UI; unpair works | M | core: PAKE + Noise |
| CL-7 | H1 | Session lifecycle: `LyteUdpSession` replaces `LyteSession` behind ConnectionModel; CTRL on reliable sublayer; capabilities exchange; connect/reconnect/takeover UX (`session-busy` → takeover-request sheet) | App streams Lyte-UDP end-to-end from click; reconnect after client sleep; takeover verified with two clients | M | core: reliable sublayer, session messages |
| CL-8 | H1 | Idle-silence + FROZEN/RECOVERY surfacing: no post-first-frame video watchdog (designed in, not patched in); status pill shows FROZEN subtly, never modal | LYTE_GAP_SIM-equivalent passes on the new path; pulled-cable shows pill, restores silently | S | CL-7 |
| CL-9 | H2 | Input over CTRL: client-timestamped, sequenced events; host echo tuples (seq, rx, inject); lastInputSeq closes per-keystroke input-to-photon into Stats/doctor | Typing on the host via Lyte-UDP; input-to-photon histogram live in doctor | M | core: input messages; host inject |
| CL-10 | H2 | `HostClockModel`: min-filtered offset + regression skew over 30 s window from beacon echoes; single instance, two consumers | Residual < 1 ms after 30 s (T gate) | S | CL-3 beacon |
| CL-11 | H2 | **M7 audio receiver** against the Lyte-UDP audio channel, pinned order (§3) | M7 acceptance envelope (§3) | L | core: audio channel; host audio sender |
| CL-12 | H2 | Work/Play presentation: Work = present-ASAP (decode all, display newest); Play = schedule at `map(captureTs) + D` on the 120 Hz vsync grid via CADisplayLink, percentile D, A/V sync bias [−100, +30] ms | Play-mode pacing ≥ 99% scheduled-slot hits at LAN 60 fps; wake-from-idle presents frame 1 without display-link wait | M | CL-10 |
| CL-13 | H2 | 4:4:4 decode: HEVC Rext through VideoToolbox, pixel-exact (device-pixel identity) rendering mode, color-range fixtures (0/255/primaries byte-exact round-trip; VUI == negotiated asserted) | Fixture harness green on synthetic bitstreams before any host 4:4:4 exists; full Q-gates run at H4 with the host | M | none (client-local; host lands H4) |
| CL-14 | H2 | **Parity gate + demolition** (§6): Sunshine retired, daily driving on Lyte | One week daily-driven; then the §6 checklist executes in one commit series | M | everything above |
| CL-15 | H3 | Clipboard UX over the feature channel (§5) | Bidirectional text copy/paste with loop prevention; toggle visible in-session | M | core: feature channel |
| CL-16 | H5 | File-drop (phase 1 of drag-and-drop, §5) | Drop file on stream window → appears on host desktop | L | core: file channel |
| CL-17 | H5 | Printing, client side (§5) | Host print job renders in the local print dialog | M | host IPP intercept |

**H0b critical path:** CL-1 → CL-2 → CL-3 → CL-4, strictly serial, nothing
else before it. CL-1/CL-2 can start against core test vectors before the
host sends a single datagram — the corpus-replay gate in CL-2 exists exactly
so client and host halves debug independently before they meet at CL-4.

**Debug mode recommendation: `lyte-cli`, not an app flag.** The CLI is the
M3/M4-proven harness — scriptable soaks, printed stats, window + input
scaffolding already there, and the hard-won AppKit rule (NSApplication.run on
the raw main thread) already obeyed. An app debug flag would thread new code
through ConnectionModel while the frozen path still owns it; the CLI keeps
H0b at arm's length from the scaffolding until CL-7 swaps the app over.

## 3. The audio centerpiece (CL-11, M7 spec in pinned order)

Implemented against the Lyte-UDP audio channel (envelope + Noise AEAD; the
AES-CBC/RTP framing dies with the scaffolding). Order is pinned by the audio
doc §5 — each item lands and is verified independently:

1. **Lock-free SPSC render ring** replacing AudioPlayer's NSLock ring. The
   render callback touches no lock, no allocation, no Swift concurrency.
   Mechanical; first commit. Preserves pre-roll priming and declick ramps.
2. **Accelerate-only WSOLA** compression of queued audio back to target
   after a burst, replacing the trim's content skip. vDSP only. Acceptance:
   a 300 ms stall+burst recovers to target with no skip, no audible seam.
3. **Percentile target-delay controller** replacing +20/−5 ms heuristics:
   smallest depth covering ~p99.9 of recent kernel-stamped gaps; depth
   changes apply via item 2's stretching, never queue jumps.
4. **libopus PLC** — libopus vendored as a C leaf (slot freed by enet's
   departure; the two-leaf doctrine holds: nanors + libopus). Lost packets
   interpolate; `decode_fec` capability banked.
5. **Clock-skew correction**: rate term (≤ few hundred ppm) folded into
   item 2's resampler, fed by `HostClockModel` — measure first, implement
   only if drift outruns one seam per ~10 min.
6. **10 ms packetDuration experiment**: now a negotiated session parameter
   (capability, not `Sdp.swift`). Decide from measurement.

Acceptance envelope (audio doc §5): no arrival pattern inside target is
audible; bursts ≤ ~2× target recover by compression; healthy-LAN underruns
trend to zero; equilibrium sits at the percentile output, not the worst gap.
The 4+2 RS interleave carries over inside the `fec` field; audio is never
NACKed, never retransmitted.

## 4. What H1 verifies rather than builds

The client already tolerates arbitrary video silence after the first
complete frame (idle-video acceptance: 45 s gap, one lost frame, IDR heal) —
but that behavior lives in the *old* receive path. CL-8's job is to carry
the assumptions forward deliberately: startup-only watchdogs, control-borne
liveness, contiguous-frame idle needing no recovery, IDLE→ACTIVE arriving as
a fresh IDR. On Lyte-UDP the sparse idle frames arrive on the reliable
sublayer (core-owned), so the assembler must accept a reliable-channel frame
into the same depacketizer chain — that seam is designed in CL-2, exercised
in CL-8.

## 5. H3+ sketch (feature-channel UX)

- **Clipboard (CL-15).** NSPasteboard has no change notification: poll
  `changeCount` at ~200 ms while the session is active. Discipline per
  LYTE-PLAN §5: origin IDs + content hashes (suppress the local change we
  caused; dedupe identical payloads), 256 KiB v1 ceiling, session-scoped
  state, never log payloads. Consent: `Off / Text only / Text + images`,
  visible during the session (clipboards carry passwords).
- **Drag-and-drop — the hardest item, honestly phased.** Phase 1 (CL-16):
  file *drop* onto the stream window → file channel push → host desktop; no
  gesture continuity, plain and shippable. Phase 2: host→client via
  `NSFilePromiseProvider` (content fetched over the channel on drop-commit).
  The full cross-machine gesture — drag out of a remote app, live under the
  cursor, into a local app — needs mid-gesture protocol traffic and pasteboard
  promises on both ends; it is much later and stays out of every earlier
  gate. Do not let phase 3 ambitions complicate phase 1's wire format.
- **Printing (CL-17).** Client side of IPP forwarding: receive the job as
  PDF on the feature channel, hand it to `NSPrintOperation`/PMPrinter with
  the local print dialog. Client work is small; the host intercept is the
  project.

## 6. Demolition checklist (trigger: Lyte-UDP daily-drivable; deadline: H2 parity)

Executed as one reviewed commit series, not a slow bleed:

1. Delete `Sources/LyteKit/`: `Session/` (Rtsp, RtspHandshake, Sdp,
   ControlChannel, UdpPinger, LaunchAPI, old LyteSession), `HostAPI/`,
   `Pairing/`, `Identity/ClientIdentity.swift`, `Support/NvXML.swift` +
   GameStream crypto in `CryptoPrimitives.swift`, `Video/VideoPacket.swift`,
   `Video/RtpVideoQueue.swift`, `Audio/RtpAudioQueue.swift`, GameStream
   halves of `AudioStream`/`VideoStream`, NVCTL `InputPackets` encodings.
2. Remove `Vendor/enet` and the `CEnet` target + its cSettings from
   `Package.swift` (frees the vendored-C slot libopus now occupies; nanors
   stays). Drop `swift-certificates`/`swift-asn1` if nothing else uses them.
3. Retire tests: `PairingCryptoTests` and any RTSP/SDP/control transcripts.
   **Preserve as goldens**: distilled interior-format vectors under `Tests/`
   — HEVC depacketization corpus, RS-FEC recovery vectors, Opus framing —
   re-pointed at the Lyte-UDP assembler (the golden pcap stays gitignored
   historical reference).
4. Remove `_nvstream._tcp` from Discovery; `_lyte._udp` only.
5. Migrate `ClientStore` schema: drop cert/uniqueId fields, keep host
   names/recents; users re-pair (PAKE) — acceptable, stated in release notes.
6. Sweep docs: PLAN.md §3 module map, README, doctor strings referencing
   Sunshine. Uninstall Sunshine from the host box in the same breath (host plan).
7. `DEVELOPER_DIR=/Applications/Xcode.app swift test` green; full app
   re-verified live before the series merges.

## 7. Cross-cutting

**SwiftUI purity, honestly.** The shims that stay AppKit stay for cause:
`VideoLayerView` (NSViewRepresentable hosting the display layer),
`InputCapture` (NSEvent monitors, first-responder + key handling — the
NSBeep lesson), CLI `NSApplication.run()` on the raw main thread, mouse-lock
via `CGAssociateMouseAndMouseCursorPosition`. New UX (pairing sheet,
takeover prompt, FROZEN pill) is pure SwiftUI.

**Testing strategy.** Pure-Swift unit-testable (plain `swift test`):
envelope decode, assembler FEC geometry, depacketizer goldens, WSOLA math
(synthetic sine seam detection), percentile controller, HostClockModel
against synthetic offset/skew traces, clipboard loop-prevention. Needs a
live host: render, latency gates, idle/FROZEN behavior, pairing. Anything
touching Keychain must build via `Scripts/build-cli.sh`/`make-app.sh` so the
stable "Lyte Dev" signature preserves authorization (MACOS-SIGNING.md);
tests run with `DEVELOPER_DIR=/Applications/Xcode.app swift test`. Netem
gauntlets (R-gates) run host-side; the client contributes the kernel-stamp
instrumentation and the LYTE_DROP_PCT/GAP_SIM-style hooks, ported to the new
receive module in CL-1.

**Sequencing note on CL-13.** The decision record places full 4:4:4 +
Work/Play at H3+/H4; the client-side decode work is pulled into late H2 here
because it is client-local, fixture-testable without any host support, and
de-risks the H4 Q-gates. It gates on fixtures only; the end-to-end Q-gates
stay at H4 as pinned.

## 8. Risk register

| Risk | Mitigation |
|---|---|
| VideoToolbox Rext 4:4:4 quirks (full-range double-expansion, mid-stream parameter-set changes) | CL-13 fixture harness with byte-exact 0/255 round-trip gates before any live 4:4:4; rebuild format description on VPS/SPS/PPS change (proven M3 behavior) |
| ProMotion pacing (display-link jitter, 120 Hz treated as fixed) | Work mode needs no display link (present-ASAP); Play-mode CL-12 gates on measured slot-hit rate; moonlight-qt's pacer is the studied prior art |
| WSOLA correctness (audible artifacts on music) | Accel-only scope; synthetic seam tests + the 300 ms stall+burst acceptance; item lands alone so regressions bisect to it |
| Bonjour interop with a Linux host (Avahi advertising `_lyte._udp`, TXT parsing via NWBrowser) | CL-5 tested against the real host's advertisement early; manual host:port is the always-working fallback |
| u16 seq wrap / serial-arithmetic bugs in demux and NACK addressing | Property tests around wrap in CL-1; wrap at peak ≈ 3.6 s ≫ gate windows by design |
| Feedback/NACK loop bugs starving the host estimator | CL-3 gates on host-visible samples, not client-side counters; `lyte sniff` (TODO-ledgered) before protocol surface grows past H2 |
| Dual-stack window drags on (two protocol layers to keep compiling) | Deletion is the default with a named trigger and an H2 hard deadline; freeze rule forbids any GameStream work meanwhile |
| Keychain/signing friction breaking pairing tests | Signing workflow is a stated constraint on every slice touching identity; unsigned-binary failure mode documented (HANDOFF lesson 9) |
