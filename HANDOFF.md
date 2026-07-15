# Lyte — Session Handoff

*Written 2026-07-15 to survive a model restart (back to Claude Fable); updated
same day after M2 verified on the wire.*

## TL;DR of where we are

- **M0 (scaffold), M1 (pairing), and M2 (session: RTSP + control channel) are DONE
  and verified against the live Sunshine host `pop` (formerly `ice`) (10.0.0.249).** The M2 blocker
  was a one-liner: `RtspHandshake` wasn't passing `riKey` into `RtspClient`, so the
  encrypted-RTSP envelope was silently disabled. With that fixed, the full
  OPTIONS→DESCRIBE→SETUP×3→ANNOUNCE→PLAY handshake succeeds, the control channel
  connects (control-v2 GCM), pings run, and teardown is clean.
- **M3 first pixels: WORKING (2026-07-15).** `lyte-cli stream <host> Desktop`
  renders the remote desktop at ~60fps: RTP → nanors FEC → depacketize →
  AVSampleBufferDisplayLayer (HEVC). Files: `Sources/LyteKit/Video/`,
  `Sources/lyte-cli/StreamCommand.swift`, `Vendor/nanors/`.
  **The hard-won lesson:** a CLI showing AppKit UI must run `NSApplication.run()`
  on the raw C main thread — NOT inside an AsyncParsableCommand's `run()`
  (a MainActor job). Doing so starves the main dispatch queue: events flow and
  windows appear, but `DispatchQueue.main` work (incl. AVSampleBufferDisplayLayer
  frame attachment) never executes → perfect stats, black window. A manual
  nextEvent pump with `await` sleeps is NOT a fix (async-main runtime exits after
  one iteration). See the custom `@main enum Main` in `CLI.swift`: parse sync,
  run command as a Task, give main thread to `app.run()` / `dispatchMain()`.
- **M3 acceptance MET (2026-07-15):** 310s soak at 2048×1280@60 — 18,132 frames
  (~58.5fps), 143,865 pkts, 0 skipped, 10 lost (all pre-first-IDR at startup),
  screenshots pixel-clean. Loss test via `LYTE_DROP_PCT=5` (client-side drop
  hook in `VideoStream.receiveLoop`): 90s, 35,107 pkts, **1,087 FEC-recovered**,
  10 unrecoverable frames all healed by IDR re-request, picture stayed clean.
- **M4 DONE, approved by Steve (2026-07-15).** Input: Moonlight packets
  (`LyteKit/Input/InputPackets.swift`, wire format from Input.h) ride the
  already-encrypted control stream as NVCTL 0x0206 on per-device ENet channels
  (kbd 0x02, mouse 0x03, UTF-8 0x06) — NO separate input cipher on Sunshine
  Gen7Enc. NSEvent capture in `lyte-cli/InputCapture.swift`: absolute mouse
  (Work), ⌃⌥-toggled locked relative mouse (Play; CGAssociate + NSCursor.hide,
  modifier-ups on release), ~85-key kVK→VK map, hi-res scroll (trackpad ×4,
  wheel ×40). Audio: `LyteKit/Audio/` — RtpAudioQueue port (4+2 RS FEC, Nvidia
  parity `77 40 38 0e c7 a7 0d 6c` patched into nanors `rs->p`), AES-128-CBC
  (IV = BE32(riKeyId+seq)), Opus via system AudioConverter (stereo; libopus
  only needed for surround later), AVAudioEngine + ring buffer with ~50ms
  policy depth cap. Audio FEC verified: 187 pkts recovered @ 5% drop.
  App identity: menu bar name needs the private `_LSSetApplicationInformationItem`
  (see `ProcessName.swift`) — ProcessInfo.processName is NOT enough; programmatic
  icon in `AppIcon.swift`; minimal two-menu design (Lyte + Actions).
  **Beep gotcha:** the stream view must accept first responder and no-op
  keyDown/keyUp/flagsChanged or every keystroke funks (NSBeep on unhandled keys).
- **M5 DONE (2026-07-15, verified live by Steve).** Lyte.app (SwiftPM target
  `Lyte` + `Scripts/make-app.sh` ad-hoc bundle): D6 window-is-the-app — connect
  empty-state (resolved Bonjour hosts, recents, PIN pairing, gradient launch
  cards), relaunch-reconnect (first window replays most recent connection; ⌥
  skips; ⌘N = fresh picker), Actions via SwiftUI commands + focused-window
  model, policy v1 derives all parameters. Key gotchas: `@Entry` macro needs
  Xcode toolchain (hand-write FocusedValueKey for CLT builds); UNBUNDLED
  SwiftUI apps don't get activation (menu bar doesn't follow clicks) — the
  .app bundle is required, which also obviates the LS rename hack; killing
  the app (vs ⌘Q) corrupts saved-state → phantom restored windows (delete
  ~/Library/Saved Application State/dev.shreeve.lyte.savedState).
- **Audio jitter calibration (doctor gold, measured 2026-07-15):** Wi-Fi↔Wi-Fi,
  both on 6 GHz channel 69 (pop: wlp0s20f3, powersave off; client awdl0 up).
  Fixed 50 ms buffer: ~8 underruns/s of audible chop with near-zero packet
  loss. Adaptive buffer (grow 10 ms/s under underruns to 120 ms ceiling,
  decay 5 ms/10 s clean — AudioPlayer.swift): AWDL up ⇒ equilibrium pegged
  ~120-145 ms; `Scripts/awdl-quiet.sh` (holds awdl0 down) ⇒ ~85-95 ms;
  residual ~0.14 underruns/s floor either way = shared-channel airtime
  (no software fix; ethernet not an option for pop). **AWDL tax ≈ 50 ms.**
- **ONE SESSION PER HOST:** two Lyte clients against the same host = doubled/
  echoed audio (both ping, host sprays both). App auto-connects at launch —
  don't also run a CLI stream. UX guard is an M6 nicety.
- **Jitter research synthesis (3-AI consult, 2026-07-15):** gaps-without-loss =
  AP buffering while the client radio is unavailable; suspects are (1) AWDL
  off-channel, (2) client 802.11 power-save dozing (under-suspected; the
  supported fix is an actively-TRANSMITTING VO-classed socket — shipped:
  SO_NET_SERVICE_TYPE VO on audio / VI on video, our pings keep the uplink
  warm), (3) shared-channel airtime. Remaining playbook: host-side DSCP EF +
  SO_PRIORITY 6 on Sunshine's audio socket (Linux maps skb->priority to the
  EDCA queue; needs Sunshine patch or config); split the two hops across
  bands (host 5 GHz, Mac 6 GHz — AP config, kills double airtime; USER
  ACTION); doctor should fingerprint gap periodicity (AWDL ≈ rhythmic 1-2 s,
  Location scans sparse 50-150 ms, doze correlates with quiet uplink/battery);
  M7 audio: NetEQ-style time-scale playout (accelerate after bursts) beats
  carrying a high buffer; Game Mode plist category shipped (games category —
  CPU/GPU priority; Apple may extend to Wi-Fi, see FB22389467/FB13512447);
  channel-149 trick is 5 GHz-only (AWDL social channels), N/A on 6 GHz.
- **M6 CORE DONE (2026-07-15): helper + doctor both live, Steve-approved
  ("MUCH BETTER").** AWDL helper: SMAppService daemon (lyte-helperd in the
  app bundle), ad-hoc signing IS accepted (register() throws 'Operation not
  permitted' but lands in requiresApproval → one-time Login Items toggle →
  enabled); event-driven PF_ROUTE watchdog; XPC refcounted streamBegan/
  streamEnded with invalidation cleanup; CLI borrows the daemon (honest
  version-probe before claiming engagement — XPC proxies exist even with no
  daemon, never trust them silently). `Lyte --register-helper` = headless
  registration/status. Doctor v1: engine in LyteKit/Doctor (EMA rates,
  loss-vs-stall discrimination, helper-aware fixes), status pill overlay in
  the app, doctor lines in the CLI ticker. Audio polish: declick ramps at
  underrun/trim seams (pops fix), honest underrun counting (skip startup
  spin), kernel-timestamped gap probe (LYTE_GAP_LOG=1 for periodicity).
- **M6 remaining:** preflight check, SSH host probes, Wake-on-LAN,
  one-session-per-host guard, host-side DSCP patch for Sunshine. (Steve's explicit
  priority — ethernet is not an option): SMAppService root daemon in the app
  bundle, XPC (streamBegan/streamEnded), holds awdl0 down during streams,
  restores on end/crash (connection invalidation). Acceptance from the
  calibration: engaging must drop buffer equilibrium ~50 ms. Then the rest
  of the doctor. See `PLAN.md §5.5/§6`.
- **Repo convention:** NO Claude/AI attribution trailers in commits (Steve's
  explicit request; history was rewritten 2026-07-15 to scrub them).

## The project in one paragraph

Lyte is a GPLv3, SwiftUI-native macOS streaming client for Sunshine hosts speaking
the Moonlight protocol. Pure-Swift protocol layer (LyteKit) with two vendored C leaf
libs (enet now, nanors later). Design: one Work/Play toggle, auto-detected
Local/Remote, telemetry-derived settings, a "network doctor." Read these in order:
`README.md`, `PLAN.md` (the blueprint — milestones in §6), `docs/DESIGN.md`,
`misc/COMMON.md` (protocol bible), `misc/MACOS.md` (macOS client patterns).

## Critical environment facts (easy to trip on)

- **Host `pop` (renamed from `ice`) = 10.0.0.249**, reached via `ssh pop`. Sunshine version 7.1.431.-1
  (the `-1` negative quad = Sunshine). Web UI / PIN entry: `https://10.0.0.249:47990/pin`.
- **The host uses `rtspenc://` (encrypted RTSP).** Our `corever=1` launch param opts
  into this. It is CORRECT given our "encryption on by default" decision.
- **Building/running requires the full Xcode toolchain, not just CLT:**
  - Build: plain `swift build` works (uses CLT clang fine).
  - **Tests: `DEVELOPER_DIR=/Applications/Xcode.app swift test`** (CLT lacks XCTest).
  - **Running `lyte-cli` needs the sandbox DISABLED** (`dangerouslyDisableSandbox: true`
    in Bash tool) because it touches the login Keychain and binds UDP sockets.
- **Keychain quirk (macOS 26):** `SecItemAdd` of a private key is denied to unsigned
  binaries (error -34018). We work around it by generating the key *inside* the
  Keychain via `SecKeyCreateRandomKey(kSecAttrIsPermanent)`. See
  `ClientIdentity.createInKeychain()`. Certs travel in the client store (public);
  the private key is matched by public-key comparison, because macOS rewrites cert
  labels to the CN. Do not "simplify" this back to SecItemAdd — it will break.
- **We ARE already paired with pop** (device name "Linux" on the host; the pairing
  cert + pinned server cert are saved in `~/Library/Application Support/Lyte/client.json`
  and the key is in the login Keychain). `lyte-cli apps 10.0.0.249` works today.
- **Stale sessions:** if the host says `SERVER_BUSY` or resume fails with "Failed to
  initialize video capture," run `lyte-cli quit 10.0.0.249` first, then launch.

## What works right now (verified)

```
./.build/debug/lyte-cli discover              # finds pop via Bonjour
./.build/debug/lyte-cli info 10.0.0.249       # serverinfo (paired, mutual TLS)
./.build/debug/lyte-cli apps 10.0.0.249       # Desktop / Low Res Desktop / Steam Big Picture
./.build/debug/lyte-cli pair 10.0.0.249       # full 5-stage PIN pairing (done once already)
./.build/debug/lyte-cli quit 10.0.0.249       # cancel running app
```

## THE IMMEDIATE NEXT STEP (resume here)

**Start M3 (first pixels).** The working session smoke test is:

```
./.build/debug/lyte-cli quit 10.0.0.249       # ensure host is free first
./.build/debug/lyte-cli launch 10.0.0.249 Desktop --duration 12
```
(Run with sandbox disabled.) Verified output: `launched Desktop`, `rtsp: OPTIONS ok`,
`DESCRIBE ok (hevc:true av1:true encSupported:0x5)`, three `SETUP ok` lines,
`ANNOUNCE ok (codec hevc, enc 0x5)`, `PLAY ok`, `control: connected`, holds the
duration (host sends 0x10e HDR-info on connect), `session closed cleanly`.

### Hard-won implementation notes (keep for reference)
1. **Encrypted RTSP byte layout** (now wire-verified). Seal/unseal in `Rtsp.swift`:
   `[typeAndLength BE32 | 0x80000000][seq BE32][tag 16][ciphertext]`, IV =
   `LE32(seq) ‖ 0*6 ‖ 'C''R'` outbound / `'H''R'` inbound, AES-128-GCM with the
   riKey. Reference: `misc/moonlight-common-c/src/RtspConnection.c`
   `sealRtspMessage` / `unsealRtspMessage`.
2. **encSeq monotonicity across transactions.** Each RTSP message opens a NEW TCP
   connection but the encryption sequence number keeps incrementing across the
   whole handshake (OPTIONS=1, DESCRIBE=2, …): one `SeqCounter(start:0)`.
3. **SDP exactness.** `Sdp.swift` `ClientSdp.payload()` — the **trailing space
   before each `\r\n`** and the **double space in `m=video <port>  \r\n`** are
   load-bearing (ported from `SdpGenerator.c`).
4. **Control channel encryption.** `ControlChannel.swift` uses control-v2 GCM
   (12-byte IV, `'C''C'`/`'H''C'`). Sunshine 7.1.431 supports it (encSupported 0x5).

## M2 files written this session (all under Sources/LyteKit/Session/)

| File | Role | Status |
|------|------|--------|
| `LaunchAPI.swift` | `/launch`, `/resume`, `/cancel`; generates riKey/riKeyID; `StreamContext` | ✅ verified |
| `Rtsp.swift` | RTSP-over-TCP transaction, response parser, **encrypted-RTSP AES-GCM envelope** | ✅ verified on wire |
| `Sdp.swift` | `HostSdpInfo` (DESCRIBE parse), `ClientSdp` (ANNOUNCE builder), codec/enc enums | ✅ verified on wire |
| `RtspHandshake.swift` | Orchestrates OPTIONS→DESCRIBE→SETUP×3→ANNOUNCE→PLAY; codec + encryption negotiation; `onPortsKnown` hook to start pings pre-PLAY | ✅ verified (fix: must pass `riKey` into `RtspClient`) |
| `ControlChannel.swift` | ENet control (UDP 47999): connect, Start A/B, 100ms ping, encrypted NVCTL send/recv, termination decode | ✅ verified |
| `UdpPinger.swift` | SS_PING (16-byte token + BE32 seq) every 500ms on audio/video UDP ports | ✅ verified (host accepts; session stays alive) |

Vendored C: `Vendor/enet/` (cgutman fork copied from `misc/moonlight-common-c/enet`,
win32.c removed). Needs the explicit `Vendor/enet/include/module.modulemap` (umbrella
= `enet/enet.h` only) — SwiftPM's auto umbrella breaks because enet headers must be
included through enet.h. `CEnet` target in `Package.swift` sets the HAS_* defines.

## Architecture decisions locked (don't re-litigate)

- License **GPLv3** (chosen after an MIT clean-room experiment was abandoned — we
  read the GPL reference freely now). macOS **15+**. Encryption **ON by default, all
  cells**. Bundle id **`dev.shreeve.lyte`** (lowercase), display name **Lyte**.
- **Sunshine-only** (GFE generations dropped) — this is why the code has no ENet-RTSP,
  no TCP-47995 control, no SHA-1 pairing. Keep it that way.
- Two vendored C libs only (enet, nanors-later). Everything else is Swift. No OpenSSL
  (CryptoKit + CommonCrypto + swift-certificates).

## Roadmap position

M0 ✅ · M1 ✅ · M2 ✅ · **M3 ◀ HERE (first pixels: RTP→FEC→VideoToolbox→CAMetalLayer)** ·
M4 input+audio · M5 SwiftUI app ·
M6 network doctor · M7 polish/Metal/HDR · M8 deep HID. Full detail in `PLAN.md §6`.

## Housekeeping loose ends

- Old GitHub repos `shreeve/lyte-foo` (abandoned MIT) and `shreeve/lyte-ORIG` (first
  GPL scaffold) still exist — `gh` token lacks `delete_repo` scope. Delete via GitHub
  UI or `gh auth refresh -h github.com -s delete_repo`. Local dirs `~/Data/Code/lyte-foo`
  and `~/Data/Code/lyte-ORIG` can also be removed.
- ~~When M2 verifies on the wire: commit, mark M2 ✅, update memory.~~ Done 2026-07-15.

## The origin story (why this project exists)

Started as a debugging session: Sunshine on `ice` (host since renamed `pop`) looked terrible in Moonlight on an
M5 MacBook Pro. Root causes (all now folded into the design as policy inputs / doctor
signatures): ~7 Mbps auto-bitrate, resolution rescale blur, NVENC-on-hybrid-graphics
fallback to VAAPI, and choppy audio from jitter (host Wi-Fi power-save + client AWDL
radio-sharing spikes + shared 6 GHz channel). See `docs/DESIGN.md` case study. That
session is why the "network doctor" is the signature feature.
