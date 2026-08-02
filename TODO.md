# TODO — deferred work, deliberately

*Small items we chose not to block on. Each entry says where it lives and why
it was deferred, so the next touch of that code picks it up naturally.
(Slice-level work is tracked in `HANDOFF.md` and the build plan, not here.)*

## Audit-sweep verification caveats (2026-07-30, post-REMAINING.md)

*The 19-PR audit sweep (#1–#19) landed and was verified end to end by a
five-agent read pass plus all four suite legs; REMAINING.md was then
retired. These are the advisory findings that pass surfaced — none are
live bugs; each is armed only by a future change to its seam.*

- **VideoAssembler threshold invariant** (`Wire/Sources/LyteWire/VideoAssembler.swift`,
  walk early-out in `sweepLossPresumption`) — the early-out compares absent
  slots against `reorderThresholdPackets` only, while write-off uses
  `fecImpossibleThresholdPackets`; safe only while
  `fecImpossible >= reorder`. Every in-tree config satisfies it, but
  `VideoAssemblerConfig.init` accepts an inverted pair, which would skip a
  group forever and suppress its `fecImpossible` report. Next touch: use
  `min(reorder, fecImpossible)` in the early-out, or assert the invariant.
  Also: PR #10 shipped source-only — `sweepSettled`, `contiguousPrefix`,
  and the `seqAdvanced || openedGroup` gate have no dedicated pins.

- **ARQ PTO sleep-forever guard has no pin**
  (`Sources/LyteTransport/ReliableCtrlEndpoint.swift`, `timerFired()`
  clearing `armedDeadlineMicros` before service) — the only sweep change
  whose correctness invariant is held by code + comment alone. Worth a
  virtual-time pin next time that file is open.

- **Residual under-lock prints** (`Host/Sources/lyte-host/SessionWire.swift`) —
  PR #8 buffered the 48 event-log lines, but a few rare paths still print
  while the session lock is held: the `flushOutbox` path-challenge lines,
  `notePeerGone`, `driveBulkShell`'s bulk-send failure, and `awaitClient`'s
  connect-failed line. A wedged stdout can still block the wire through
  those; route them through `emit` on the next touch.

- **FROZEN exit one-beat deferral** (`Sources/LyteTransport/LyteUdpSession.swift`) —
  a datagram landing inside the exact `applyMachine` critical section that
  enters FROZEN reads `machineFrozen == false`, skips the immediate exit,
  and is delivered by the next beat instead (≤100 ms in production;
  lossless — the atomic stamp retains it). Bounded and by design, but
  "datagram-immediate FROZEN exit" carries that one caveat.

*(Two caveats from this pass retired 2026-08-02 with the E5 demolition:
the Sink's encode() `-2` resend trap died with the Sink, and
quality-probe.sh's grep contract died with the script.)*

*Still owed live (not code): watch #6's `rate: fall purge` line and #16's
`hole-recused` count on the next evening-air session; optional rtprio
grant on the host machine (`Host/README.md` prerequisites item 3); ⌘W a
live stream window (PR #25) and watch for the host's peer-goodbye line +
awdl0 release; a live monitor-mode change mid-session (PR #24) should now
end in a typed teardown, not a crash — worth one deliberate flip.*

## ANALYSIS ledger — the live remainder (moved 2026-08-02)

*The 2026-07-30 six-territory review's ledger (ANALYSIS.md, with
ANALYSIS-DETAILED.md and ANALYSIS-FULL.md as raw material) was retired
per owner directive after the E5 demolition; the full record — Tier 1's
landed entries, the Tier 3 performance ranking, the architecture/clarity
essay, and the strengths inventory — lives in git history (last at
`860369a`, `git show 860369a:ANALYSIS.md`). Below are the still-open
numbered items, re-verified against the post-E5 tree. Retired as moot:
#11 (`--no-idle-floor` signal swallow — flag and Sink deleted; the
direct leg polls the termination flag itself since #72), #17 (mute on
fresh connect — since fixed; `setAudioMuted` now rides both connect and
roam paths), #21/#22 (quality-probe.sh / corpus-harness.sh deleted),
#19's capture half and #26's linebuf residue (demolished / fixed
in #72).*

- **T2-7 Unauthenticated peer retarget** (client) —
  `Sources/LyteTransport/UdpReceiveEndpoint.swift`: any datagram whose
  source parses as AF_INET overwrites `peerAddress` *before* the AEAD
  sees the bytes; an off-path trickle at ~50 Hz steals the return leg
  (ACKs, input, feedback). The host has PathValidator for the mirror
  case; the client has nothing. Fix: adopt the source only on
  `.accepted` — strictly better for roaming too.

- **T2-8 NACK-driven IDR arming has no throttle** (host) —
  `Host/Sources/HostWire/Session.swift` arms the coalesced keyframe
  latch on every unknown-frame NACK, unbounded. An authenticated client
  naming one garbage frame per 25–50 ms report forces continuous IDR
  re-encodes. The other demand sources are host-armed and self-limiting;
  only this one is peer-driven at wire cadence. Fix: per-interval cap on
  `.unavailable` arms.

- **T2-9 ARQ receive groups never reclaimed** (Wire) —
  `Wire/Sources/LyteWire/ArqEndpoint.swift`: removal happens only on
  complete one-shot delivery; abandoned/poisoned groups live forever. 63
  never-completed one-shot groups pin the 64-group table; thereafter
  every new one-shot is refused *without an ACK* — and since idle-frame
  acknowledgment drives ACTIVE→IDLE, the session can permanently lose
  its idle flip while accumulating retransmitting send-groups.

- **T2-10 Audio retention horizon read off the wire** (Wire) —
  `Wire/Sources/LyteWire/AudioDepacketizer.swift`: staleness gate and
  eviction derive `k` from the *arriving shard's* declared FEC geometry,
  not the stream's. One legal `k=1` shard shrinks the horizon ~4× and
  flushes groups still awaiting parity; a `k=255` shard widens admission
  ~1000×. The horizon is local policy — pin it in the depacketizer's
  config.

- **T2-12 Receive-loop `EINTR` deafness + unsynchronized fd close**
  (client) — `Sources/LyteTransport/UdpReceiveEndpoint.swift`: one
  `SIGPROF`-class signal permanently deafens the session (treated as
  "closed by stop()"); `stop()` closes the fd without joining while a
  roaming re-dial can reuse the fd number within the race window.

- **T2-13 Post-handshake config published unlocked to the drain thread**
  (host) — `Host/Sources/lyte-host/main.swift` writes
  `inputInjector`/clipboard closures/`bulkShell` while the drain thread
  may already read them; `noteMonitorExtent` mutates the injector from
  the video thread unlocked (now called from DirectEyeLeg since #72).
  All cold paths — route through `lock`.

- **T2-14 Unbounded send retry under the session lock** (host) —
  `Host/Sources/lyte-host/SessionWire.swift`: `sent == 0` →
  `usleep(200); continue` with no bound, holding the lock everything
  needs — a wedged interface hangs the process silently. Cap and throw
  into the existing `drainFailed` path.

- **T2-15 Helper XPC: interruption unhandled** (app) —
  `Sources/Lyte/HelperClient.swift` installs only `invalidationHandler`;
  a *crashed* daemon produces an interruption, `engaged` stays true, and
  AgentMenu's documented re-engage never fires — awdl0 comes back up and
  stays LOOSE for the session.

- **T2-16 Held keys never flushed** (app) —
  `Sources/Lyte/LyteInputCapture.swift`: no all-keys-up on
  resign-key/stop/teardown anywhere in client or host. ⌘Tab away with a
  modifier down leaves the host with Super/Alt latched; a held key
  across app-switch → host-side auto-repeat storm.

- **A-18 `applyIdrPacing` leaves belief and probe cadence stale across
  RECOVERY/migration** — `Host/Sources/HostWire/RateEstimator.swift`:
  the one place the estimator *knows* its evidence is stale halves only
  `rateBitsPerSecond`; `beliefBits` (which never ages), the cadence
  hold, and the band floor all survive the path change. Migrate from
  90 Mbps Wi-Fi to a 5 Mbps tether and the probe ceiling is still
  ~99 Mbps; symmetric: a stale band floor can hold rises for 10 s.

- **A-19 (audio half) shutdown `roundtrip` with no timeout** —
  `Host/Sources/lyte-host/audio.c` (`lyte_pw_audio_restore`): a wedged
  wireplumber hangs exit with the desktop's default sink still pointed
  at "Lyte Audio". Wants the bounded timer source the old capture leaf
  demonstrated. (The capture half of this finding died with
  CPipeWireCapture.)

- **A-20 Delivery trains are segmented channel-blind** —
  `Host/Sources/HostWire/RateEstimator.swift`: trains mix fast-lane
  audio (131 B) with video (1152 B) under DSCP, skewing the measured
  rate that drives the honest/censored trichotomy — and at the 500 kbps
  floor the rate-scaled gap (~55 ms) chains audio's 5 ms cadence into
  every train. Consider single-channel trains or per-channel
  classification.

- **A-23 `SessionWire.init` late throw double-frees and orphans the
  drain thread** — `Host/Sources/lyte-host/SessionWire.swift` init +
  deinit: a throw after the allocations and thread start repeats
  `scratch.deallocate()`/`lyte_netio_free` and leaves the drain thread
  on a freed object. Unreachable today (the `--insecure` validation runs
  first) — armed by any new throw added to `init`. Move validation above
  the allocations.

- **A-24 `lyte_pw_audio_quit` races the loop's exit reason** —
  `Host/Sources/lyte-host/audio.c`: plain-`int` cross-thread store can
  overwrite a concurrent stream-error reason, silently suppressing the
  `run error` line. Make it `_Atomic` (companion: a possibly-NULL
  `spa_dict_lookup` passed to `%s`).

- **A-25 The arrival-stamp decoy parameter** —
  `LyteUdpSession.handleDatagram(_:arrivalMicroseconds:)` never reads
  the parameter (deliberately), but `UdpReceiveEndpoint`'s doc still
  promises it's "the same arrival stamp the demux got"; a future reader
  wiring t2 from it corrupts every RTT sample. Drop or annotate it.

- **A-26 (residue) duplications + missing host-side seams** —
  `LatencyHistogram` ≡ `HostCore.Histogram` and `AnnexBCheck` ≡
  `HostCore.AnnexB` are documented-in-code duplications; the host's
  crypto and ARQ carriage are inlined switches where the client has
  named seams (`TransportCrypto`, `ReliableCtrlEndpoint`) — the missing
  host-side seam is why the ARQ repack duplication exists.

- **A-27 (test gap) `HostClockModel.estimate`** picks `anchor` by max
  timestamp but `offset0` by array position; out-of-order `ingest` has
  no pin.

## Browser client + Caddy bridge (`docs/20260720-184200-browser-client-caddy-bridge.md`)

- **Post-H6 plan of record, deliberately parked.** Same Swift client protocol
  layer compiled to WASM (WebCodecs decode), reaching lyte-host through a
  Caddy module — simplified by the 2026-07-20 Lyte-UDP decision to a **dumb
  WebTransport-datagram ↔ UDP-packet relay** (CONNECT-UDP / RFC 9298 shape);
  the host-side protocol is Lyte-UDP, not GameStream, and E2E Noise keeps the
  bridge untrusted. Pick up only after the native path runs flawlessly.
  (Design consult 2026-07-20; amended per
  `docs/20260720-215100-lyte-udp-decision.md`.)

## `lyte sniff` — the key-joined decrypt half (future)

- **Mostly done.** `lyte-host sniff` (HS-5, `Host/Sources/lyte-host/Sniff.swift`)
  has pretty-printed envelopes/channels for waves. What remains is the half
  its header explicitly defers: joining a session key so payloads decrypt —
  today it dissects headers only, with Noise blinding the cargo. Pick up if
  a debugging season ever needs plaintext on the wire.
  (`docs/20260720-215100-lyte-udp-decision.md` §7.)

## Capture-organ replacement (2026-08-01, owner-initiated)

The compositor capture seam (portal → Mutter ScreenCast → PipeWire) is
the proven weak organ: damage-driven cadence, 1 fps static keepalives,
portal wedges (twice at the owner's glass today), and the benchmark rig
already distrusts it (SyntheticMotionSource exists to bypass it).
**KMS capture is FEASIBLE on pup**: `ffmpeg -f kmsgrab -device
/dev/dri/card1` pulled the live scanout at 60 fps, compositor not
consulted (hybrid laptop: panel scans out on the Intel iGPU = card1;
nvidia-drm modeset=Y already). The v2 capture design panel should weigh:
(A) KMS pull-based capture → dmabuf → NVENC (Sunshine's proven Linux
path; costs: CAP_SYS_ADMIN, own consent model, uinput input, clipboard
channel), (B) X11+NvFBC, (C) wlroots/KDE screencopy, (D) harden current
stack only. Near-term regardless: an auto-heal seam — on a capture-
starvation episode, tear down and recreate the screencast session
in-place instead of freezing forever.

Owner decisions (2026-08-01 session):
- **Sequencing**: capture-organ replacement FIRST; AV1 only after the
  new capture path is landed and stable. "Get it all running, then add
  AV1 — at that point it's easy."
- **AV1 end-to-end is hardware-viable when we get there**: owner's Mac
  is an M5 (VideoToolbox AV1 decode); pup has TWO hardware AV1 encoders
  (Meteor Lake Arc media engine + Ada NVENC). The four HEVC-shaped
  seams to unwind, inventoried: (1) vendored ffmpeg builds ONLY
  hevc_nvenc (Host/Scripts/vendor-ffmpeg.sh — one-line-ish, but the
  no-reset patch needs re-verification against the AV1 wrapper), (2)
  AnnexB.swift parses NALs — AV1 is OBU framing (keyframe detect,
  packetizer boundaries need a twin), (3) wire needs a negotiated codec
  field (host offers, client picks — the "doctor" decides), (4) client
  pipeline constructs HEVC-style format descriptions. Caveats recorded:
  hardware AV1 is 4:2:0-only both ends — the 4:4:4 text ambition stays
  HEVC-rext; AV1's screen-content tools + WAN bitrate savings are the
  prize.
- **Encoder/GPU policy by topology** (host auto-detects, "doctor"
  rules): desktop with panel on NVIDIA → NVENC zero-copy; pup
  (VERIFIED: IdeaPad Pro 5 16IMH9, NO MUX — Notebookcheck: "Only
  Optimus 1.0", all connectors incl. HDMI hang off card1/Intel; the
  card0 eDP-2 is a phantom) → Arc media engine (Meteor Lake QuickSync:
  first-class HEVC + AV1 encode) on the die that owns the scanout;
  Intel→NVIDIA→NVENC copy path rejected (keeps dGPU awake, wonky
  cross-adapter dmabuf, no quality win vs Arc).
- **Pacing model for KMS capture** (replaces Mutter damage): poll the
  scanout plane's framebuffer ID at display rate — compositor didn't
  repaint ⇒ same FB ID ⇒ send NOTHING (idle silence preserved without
  Mutter's cooperation); ID changed ⇒ grab ticket, encode, send.
  Change-driven cadence scales 0 fps (blank) → ~1 fps (caret blink
  repaints) → 60 fps (video) automatically. Encoder skip-frames are the
  backstop detector; client already proven to tolerate ≤1 fps idle and
  45 s blackout (2026-07-20 verification). Hardware cursor moves on its
  own KMS plane — cursor position is metadata, not repaints.

PROTOTYPE RESULTS (2026-08-01, owner said PROCEED; all three links
proven individually on pup, live GNOME session, unharmed):
1. **Doorbell** (`fbid-poll.c`, scratchpad → /tmp/fbid-poll on pup):
   polls primary-plane FB_ID via drmModeGetPlane — UNPRIVILEGED (only
   pixel access needs privileges). Idle desktop: exactly 1.00 flips/s
   (gap 998–1002 ms — some 1 Hz repaint); 60 fps ffplay window: 61.00
   flips/s sustained; cursor plane: 0 flips both legs (hardware cursor
   confirmed separate). Poll cost 4–32 µs at 1 ms cadence. Damage
   detection recovered from below, wedge-proof.
2. **Encoders**: pup's SYSTEM ffmpeg has hevc_vaapi + av1_vaapi; iHD
   26.1.2 (intel-media-va-driver-non-free) drives the MTL Arc engine.
   Both emitted real bytes from kmsgrab input.
3. **The format bridge** — the one real finding: MTL scans out XR30
   (10-bit RGB) with CCS compression modifier 0x10000000000000f in a
   3-plane fb (main + aux + clear-color). The media engine's VPP
   (scale_vaapi) CANNOT ingest it ("Failed to start picture
   processing"; p010 output fails identically ⇒ modifier, not bit
   depth ⇒ stock-ffmpeg one-liner is NOT the production path). The 3D
   engine CAN: `ccs-import-probe.c` (headless EGL via GBM, desktop GL,
   eglCreateImageKHR with per-plane fd/offset/pitch + modifier lo/hi)
   imported it in **0.04 ms** and read back genuine desktop pixels
   (Mesa 26.0.3, "Intel Arc MTL"). Production chain therefore:
   FB-ID doorbell → GETFB2 + drmPrimeHandleToFD → EGL import → shader
   blit RGB→NV12 into an uncompressed surface shared with VAAPI →
   encode → wire. All GPU-side; the probe's 6.8 ms glGetTexImage was
   CPU-proof only, not part of the pipeline. This is Sunshine's exact
   Linux architecture (their egl.cpp), independently re-derived and
   re-verified on Meteor Lake.
   Remaining unproven link: EGL→VAAPI surface sharing + the blit shader
   (known tech, next prototype step), then input (uinput), consent,
   cursor metadata channel, clipboard.
