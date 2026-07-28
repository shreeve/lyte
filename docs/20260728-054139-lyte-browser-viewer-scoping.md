# Browser Viewer Scoping — the WASM promise is cashed: LyteWire builds and passes 400/400 under wasm32 today (2026-07-28)

*Commissioned by the H3 §0 owner decisions (HANDOFF, 2026-07-27 ~21:22):
answer 3 pulled the WASM browser viewer INTO H3, against the H3 plan's own
recommendation; answer 4 holds LAN-first — no rendezvous, no relay fleet,
the browser talks DIRECTLY to the host on the LAN. This doc is the scoping
scout that decision commissioned: compile probe run for real in /tmp
against committed HEAD `7517b78`, transport/codec/crypto surveyed against
mid-2026 browser reality, a slice ladder proposed with its cut line.
Nothing in Wire/, Host/, or root was touched; every experiment lived
outside the repo. Authorities unchanged: the pillar docs + overview are
the spec, `20260720-215100-lyte-udp-decision.md` governs, the H3 plan
(`20260723-051223-lyte-h3-plan.md`) is the wave of record. The old bridge
consult (`20260720-184200-browser-client-caddy-bridge.md`) is superseded
in one load-bearing way: LAN-direct kills the hosted-relay premise — the
HOST end must terminate whatever the browser speaks.*

## 0. Verdicts, up front

- **Compile probe: PASS, emphatically.** The whole Wire package — LyteWire,
  the CNanorsWire C leaf, swift-crypto's vendored BoringSSL, TestKit, even
  vectorgen — cross-compiles to `wasm32-unknown-wasip1` with ZERO source
  changes, first try, 22 s. With one two-line `#if !os(WASI)` guard around
  the Process-based lint test, **400/400 tests pass under wasmtime,
  including byte-exact verification of all 13 frozen vector files**. The
  sans-IO, no-Foundation lint discipline was the work; wasm32 is now a
  *third attested platform* waiting for a CI leg. §1 has the real commands
  and the two real caveats (binary size; the macOS `/tmp` symlink).
- **Transport: WebTransport over HTTP/3, datagrams.** Baseline across all
  three engines since 2026-03-24 (Chrome 97+, Firefox 114+, Safari 26.4+),
  `serverCertificateHashes` included everywhere — the LAN self-signed
  story is real. The host terminates it as a new `#if os(Linux)` C leaf
  behind a flag (lsquic first choice — it ships a first-class WebTransport
  API; ngtcp2+nghttp3 the assemble-it-yourself fallback). WebRTC and
  WebSocket rejected for v1 (§2). One measured risk: the 1152-byte
  datagram ceiling vs QUIC's per-datagram capacity — B-2's gate settles it.
- **Codec: the host offers `[av1, hevc]` for browser sessions and the
  capability intersection — which already exists for exactly this — picks
  per session.** WebCodecs HEVC is Safari-universal but hardware-roulette
  everywhere else (absent entirely on Linux Chrome); WebCodecs AV1 is
  universal on Chrome/Edge/Firefox and weak on Safari. Together they cover
  effectively every current browser. The RTX 4050 (Ada) encodes AV1 in
  hardware; `Capabilities` reserved the new codec id on purpose. WASM
  software decode (dav1d) rejected for v1 (§3).
- **Noise: nothing to do.** The crypto path imports only `Crypto`
  (swift-crypto 3.15.1 as resolved — WASI-supported upstream since 2023),
  entropy and clocks are injected per doctrine, and the handshake +
  AEAD + PAKE all compiled and passed their vector tests under wasm in the
  probe. §4.
- **Ladder: B-1…B-6, with the cut line after B-4.** The J-G3 browser bar
  this doc proposes: **B-3 (wire-view in a browser: handshake + CTRL +
  stats, live against pup) is the H3 MUST; B-4 (video) is the target;
  B-5/B-6 (audio+input, clipboard+UI) are declared H4 spill unless the
  wave runs ahead.** §5 and §6 carry the slices and the owner decisions.

## 1. The compile probe — run for real, against committed HEAD

### 1.1 What was run, exactly

Environment: this Mac's Xcode toolchain reports Swift 6.3.3
(`arm64-apple-macosx26.0`), and **Xcode's toolchain cannot target wasm**
(Apple builds LLVM without the WebAssembly backend). The supported path is
the swift.org toolchain via swiftly plus the official Wasm Swift SDK —
both shipped for exactly 6.3.3. Everything below is user-local
(`~/.swiftly`, `~/.wasmtime`) and repo-untouched:

```
# swiftly + swift.org 6.3.3 toolchain
curl -sLO https://download.swift.org/swiftly/darwin/swiftly.pkg
installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
~/.swiftly/bin/swiftly init --assume-yes --skip-install --no-modify-profile
. ~/.swiftly/env.sh && swiftly install 6.3.3 --use

# the official Wasm SDK matching the toolchain (swift.org, checksum pinned)
swift sdk install \
  https://download.swift.org/swift-6.3.3-release/wasm-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7
# installs: swift-6.3.3-RELEASE_wasm  +  swift-6.3.3-RELEASE_wasm-embedded

# the probe: committed HEAD only (the working tree belongs to the F-2 worker)
git archive 7517b78 Wire | tar -x -C /tmp/lyte-wasm-probe/WireHEAD
cd /tmp/lyte-wasm-probe/WireHEAD/Wire
swift build --swift-sdk swift-6.3.3-RELEASE_wasm          # library + tools
swift build --swift-sdk swift-6.3.3-RELEASE_wasm --build-tests
wasmtime run --dir . --dir "$PWD::$PWD" \
  .build/wasm32-unknown-wasip1/debug/LyteWirePackageTests.xctest
```

### 1.2 What happened

- **The library build: clean, zero changes.** All 571 build steps
  including `CNanorsWire` — nanors' `rs.c`/`oblas_lite.c` compile under
  the wasm triple as plain portable C, no flags, no Swift fallback needed.
  swift-crypto's vendored BoringSSL likewise: upstream has excluded the
  socket-dependent files and set `OPENSSL_NO_ASM` under `Platform.wasi`
  since 2023 (PR #145). The FEC question mark this scoping was told to
  chase **does not exist**.
- **The test build: ONE failure, the expected one.**
  `Tests/LyteWireTests/NoFoundationLintTests.swift:20: error: cannot find
  'Process' in scope` — WASI has no processes, so the lint test (which
  shells out to `lint-no-foundation.sh`) cannot compile. A two-line
  `#if !os(WASI) … #endif` around that one file is the ONLY repo change
  the wasm target needs, and it is honest: the lint checks source text and
  keeps running on the native platforms where CI already executes it.
- **The test run: 400 executed, 0 failures, 23 s** under wasmtime on
  `wasm32-unknown-wasip1` — every codec, FEC, Noise, PAKE, ARQ, video,
  session, clipboard suite, and **all 13 frozen vector files verified
  byte-exact**. The freeze policy's "byte-exact on macOS AND Linux" gate
  extends to a third platform the moment we choose to pin it.
- **Two mechanical footnotes.** (i) XCTest under WASI runs by invoking the
  built `.xctest` wasm module directly under wasmtime — `swift test`'s
  in-process runner only drives swift-testing there and reports "0 tests"
  (SwiftPM limitation, not ours; the B-1 CI leg scripts the wasmtime
  invocation). (ii) On macOS, `/tmp` is a symlink to `/private/tmp`; the
  WASI preopen must map the *resolved* absolute path or the
  `#filePath`-derived vector paths miss (49 spurious file-not-found
  failures until mapped). Linux CI has no such wrinkle.

### 1.3 The honest caveats

- **Binary size.** A minimal LyteWire-importing executable, release +
  `--strip-all`: **53 MB wasm, 19.4 MB gzipped** (`-Osize` changes
  nothing). The culprit is not LyteWire — it is that swift-crypto's
  `CryptoBoringWrapper` imports Foundation, which statically drags
  FoundationEssentials into every wasm link despite LyteWire's own
  Foundation-free discipline. On a LAN a 19 MB one-time fetch is seconds
  and cacheable, so this does NOT block the viewer — but it offends the
  doctrine's spirit, and the fix is upstream (or a WebCrypto-backed
  provider swap later). Recorded, not fought this wave.
- **Embedded Swift is out, same culprit**: the `-embedded` SDK fails
  immediately on `CryptoBoringWrapper`'s `import Foundation` (embedded has
  no Foundation). Revisit only if size ever matters beyond LAN.
- The probe covered `LyteWire` + `LyteWireTestKit` + tests. It did NOT
  probe JavaScriptKit interop or a browser event loop — that is B-3's
  first hour, not a compile question.

## 2. The transport — WebTransport, terminated by the host

Browsers cannot touch raw UDP; Lyte-UDP as a carrier is unreachable from
a page. LAN-direct (owner answer 4) means no hosted relay — whatever the
browser speaks, the HOST end terminates. Three candidates, weighed against
what Lyte-UDP actually needs (unreliable unordered datagrams, ~1152 B,
with the reliable sublayer riding inside):

- **WebTransport over HTTP/3 — the pick.** Datagram semantics are a
  near-exact match: unreliable, unordered, no head-of-line blocking —
  LyteWire's envelope/FEC/ARQ ride through as opaque bytes and the
  end-to-end Noise layer stays exactly as it is (the transport's TLS is
  ceremony; our security model never depended on it). Support reached
  Baseline 2026-03-24: Chrome 97+, Firefox 114+, **Safari 26.4+** (recent
  — a real client-fleet constraint worth naming), and
  `serverCertificateHashes` ships in all three (Chrome 100+, Firefox
  125+, Safari 26.4+), which is what makes a LAN host without a CA
  viable. Constraints that come with that option, verbatim from the spec:
  the certificate must be ECDSA P-256, X.509v3, **validity ≤ 14 days** —
  so the host mints and rotates its own short-lived cert and publishes
  the SHA-256 hash out-of-band (§6, decision C).
- **WebRTC data channels — rejected.** Unreliable/unordered mode exists
  (`maxRetransmits: 0, ordered: false`), but the price is the entire
  ICE/SDP/DTLS/SCTP machine on both ends plus a signaling channel we'd
  have to invent anyway. On a LAN with a known host address, ICE solves a
  NAT problem we do not have, and the host-side dependency (a full
  libwebrtc or a datachannel library) is strictly heavier than a QUIC
  stack. Its one advantage — Safari support back to ~15 — does not buy
  enough to carry that bill.
- **WebSocket — degraded fallback only, not v1.** TCP head-of-line
  blocking is the direct negation of the damage-driven model: one lost
  segment stalls EVERY shard behind it, repair traffic queues behind the
  damage it repairs, and the estimator learns TCP's dynamics instead of
  the path's. Acceptable someday as an explicit "compatibility, expect
  mush" mode; building it first would teach us nothing about the real
  system.

**Host termination — the one real doctrine question.** The Lyte-UDP
decision record rejected QUIC *as the core transport dependency*; a
browser listener re-poses the question as an optional leaf. Two honest
shapes:

1. **In-process C leaf (recommended):** a `CWebTransport` system-library
   module + thin Swift wiring, `#if os(Linux)`, compiled only into
   `lyte-host`, enabled only by `--browser`. **lsquic** is the first
   candidate — C, ships first-class WebTransport-over-H3 (public
   `lsquic_wt.h`: sessions, streams, datagrams, Extended CONNECT
   handled); **ngtcp2 + nghttp3** is the fallback (both plain C,
   datagram + capsule support present, but Extended CONNECT/WT session
   plumbing is ours to write, ~1000 lines by published example). This
   fits "C only at OS/hardware leaves" mechanically — the browser edge
   IS a boundary — but it does amend the decision record's QUIC stance,
   so it is written up as owner decision A, not taken silently.
2. **Same-box sidecar relay:** the amended bridge doc's dumb
   WebTransport↔UDP datagram relay, now living ON the host box (LAN-direct
   holds — the browser still talks straight to the host machine), keeping
   `lyte-host` QUIC-free. Purer; costs a second deployment artifact, a
   process-supervision story, and likely a second language — the ops
   burden the product deliberately refuses.

**The MTU question — measured, not assumed.** `WireBudget` caps the whole
datagram at 1152 B (envelope 24 + extensions + ciphertext+tag ≤ 1128), and
the comment already calls 1152 "the bridge-safe ceiling" — the wire was
sized for this day. But a WT datagram must fit inside one QUIC packet:
1200 B baseline UDP payload minus QUIC header + AEAD + datagram-frame
framing leaves **roughly 1150–1180 B, browser- and path-dependent**
(`transport.datagrams.maxDatagramSize` tells the truth at runtime). 1152
probably just fits; "probably" is not a gate. B-2 measures it in all three
engines; if any engine lands under 1152, the browser session negotiates a
lower shard ceiling at connect time — the DPLPMTUD hook in the budget
comment ("a negotiated session parameter, never per-packet") already
reserves exactly this move, downward instead of up.

## 3. Decode, render, audio, input — the browser reality

### 3.1 Video codec support as of mid-2026 (WebCodecs decode)

| Codec | Safari | Chrome/Edge | Firefox | Linux desktop browsers |
|---|---|---|---|---|
| HEVC | Universal (26.0+ full WebCodecs; VideoToolbox, sw fallback) | Hardware-dependent (Win needs the OS HEVC extension; Edge has licensing gaps) | 134+ Win / 136+ macOS, hardware only | **Absent** (Chrome/Linux unsupported) |
| AV1 | Hardware only — M3+/A17+ (~24–33% of Safari sessions measured) | Universal (dav1d software fallback built in) | Universal | Universal |
| H.264 | Universal | Universal | Universal | Universal |

Empirical fleet data (1M+ devices, 2026): AV1 decode ~91.5% of sessions,
HEVC near-universal on Safari and near-absent on Firefox/Edge — **AV1 +
HEVC together cover 99.73%**. H.264 buys only the last 0.27% at the cost
of a third host encode profile and the worst rate/quality of the three.

**Recommendation: the host declares `[hevc, av1]` for browser sessions;
the browser client declares what `VideoDecoder.isConfigSupported()`
affirms; the existing capability intersection picks.** This is the
machinery working as designed — `CapabilityCodec` assigned only
`hevc = 1` in wire v1 and documented that "AV1 lands as a new id when it
lands"; the id list is ascending and unknown-value-tolerant on purpose.
Assigning `av1 = 2` is an APPEND to the vector file, not a regeneration.

**What AV1 costs the host, honestly:**

- **NVENC: cheap.** The RTX 4050 is Ada — 8th-gen NVENC with hardware AV1
  encode; libavcodec exposes `av1_nvenc` and the encode leaf already
  speaks libavcodec. (D-0-style pup verification owed at the slice:
  `ffmpeg -encoders | grep av1_nvenc` and a smoke encode.)
- **The packetizer seam: the real (contained) cost.** `VideoPacketizer`
  is Annex-B-shaped — `AnnexBCheck.isFrameShaped` / `containsIrap` gate
  every frame and derive IDR-ness from NAL types. AV1 has no Annex B; it
  emits OBUs (the low-overhead bitstream). The seam needs an OBU-aware
  sibling (frame-shaped check + keyframe detection — simpler than HEVC's,
  OBU headers are byte-aligned and self-describing) or an explicit
  is-keyframe flag from the encoder. The FEC/shard interior is
  codec-blind bytes and does not change. New vector cases append.
- **WebCodecs config plumbing:** codec string (`av01.0.08M.08` shape) and
  the Annex-B-vs-description question for HEVC (`hev1.*` without a
  `description` = Annex B mode in Chrome; Safari behavior needs the B-4
  probe) — client-side detail, recorded so B-4 does not rediscover it.

**WASM software decode — rejected for v1.** dav1d compiles to wasm and
decodes ~1080p30-ish on good desktops with threads+SIMD; 2048×1280@50 is
beyond honest reach, it burns the CPU the damage-driven model tries to
spare, and it forfeits the hardware pipeline WebCodecs exists to provide.
If a browser supports neither AV1 nor HEVC, the viewer says so loudly and
stops — a truthful refusal beats a slideshow.

### 3.2 Audio — the easy one

Opus decode via WebCodecs `AudioDecoder`: Chrome 94+, Firefox 130+
(desktop), Safari 26.0+. Playout via an `AudioWorklet` ring buffer —
the browser sibling of the client's jitter discipline, deliberately
minimal in v1 (fixed small target, no WSOLA — CL-17's adaptive machinery
is native-client territory; the browser bar is "5 ms cadence audio plays
without gross artifacts", not equilibrium-matching). Opus PLC: the
WebCodecs decoder does not expose concealment; v1 accepts brief gaps
(LAN loss is the design point, and video repair already dominates).
Firefox-for-Android has no WebCodecs at all — named, not worked around.

### 3.3 Input and clipboard — straightforward, with named gotchas

- Pointer/keyboard/wheel events map onto the existing typed input
  messages (LyteWire codecs, already proven under wasm). Pointer Lock is
  universal for relative capture.
- **Keyboard Lock API is Chromium-only** — Safari/Firefox sessions cannot
  capture Cmd-Tab/Alt-Tab-class chords; the viewer ships with that honest
  asterisk (the native client keeps its edge here).
- Clipboard: `navigator.clipboard` read wants a user gesture + permission
  prompt (Safari strictest — gesture per read); write is easier. Maps
  cleanly onto clipboard v1's CTRL messages and the same consent posture;
  rides B-6.

## 4. The Noise question — already answered by the probe

Verified by inspection and by execution:

- `Wire/Sources/LyteWire/Crypto/` imports exactly `Crypto` (three files:
  NoisePrimitives, CPace, RetryCookie) — the lint-confined single
  dependency, nothing else.
- swift-crypto resolves to **3.15.1**, which carries upstream WASI support
  (socket-dependent BoringSSL files excluded, `OPENSSL_NO_ASM` +
  no-threads defines under `Platform.wasi` — merged 2023, stable since).
  It compiled and its AEAD/HKDF/X25519/HMAC paths executed in the probe.
- No platform entropy or clocks are reached for: randomness enters via
  injected `some RandomNumberGenerator` (ConnectionId, PAKE), time via
  injected wire timestamps — the sans-IO doctrine, doing its job. (WASI
  provides `random_get` besides, so even the default generator would
  work; we do not need it.) The noise-v1 and pairing-v1 vector suites
  passing under wasmtime is the executable proof: **the handshake the
  browser will run is byte-identical to the one pup already speaks.**

The JS boundary supplies: datagram bytes in/out (WebTransport streams via
JavaScriptKit), `performance.now()` into the injected clock, and
`crypto.getRandomValues` into the injected RNG. Paired identity persists
in IndexedDB/localStorage — the Keychain sibling, named in B-3's slice
(a browser profile holding a session-capable static key is a real, if
LAN-scoped, artifact; same threat class as the macOS client's Keychain
entry).

## 5. The proposed slice ladder — B-n, one worker-session each

New namespace **B-n**, no collisions. New package territory: **`Web/`**
(SwiftPM package `LyteWeb` — wasm executable importing LyteWire +
JavaScriptKit, plus the static page/JS glue), so no B-slice fights the
Wire/, Host/, or root workers except B-2 (Host/) and B-4's host half —
serialization noted per slice. Effort scale as the H3 plan (S ≤ 2d,
M 3–7d).

| ID | Territory | Slice | Mac vs pup | Deps | Gate | Effort |
|---|---|---|---|---|---|---|
| B-1 | Wire/ (2 lines) + CI | The wasm leg: `#if !os(WASI)` guard on the lint test; a `Scripts/` runner that cross-builds Wire for `wasm32-unknown-wasip1` and executes the suite under wasmtime with the preopen mapping; pin toolchain 6.3.3 + SDK checksum | Mac-local (Linux CI identical) | none — probe de-risked it | Wire build green under the wasm SDK; **400/400 under wasmtime with all 13 vector files byte-exact** — wasm32 becomes the third attested platform; native suites untouched | S |
| B-2 | Host/ | WebTransport listener leaf: `CWebTransport` (lsquic; ngtcp2+nghttp3 fallback ruling recorded in-slice), `#if os(Linux)`, behind `--browser`; self-minted ECDSA P-256 cert, ≤14-day rotation, hash exposed; datagrams bridged to the session engine as opaque Lyte-UDP bytes; serves the static viewer page | needs pup for live; lib compiles under mock on Mac | owner decision A | echo-level: browser (all 3 engines) connects via `serverCertificateHashes`, datagrams round-trip; **measured `maxDatagramSize` ≥ 1152 recorded per engine — or the negotiate-down ruling written**; native UDP path provably untouched with the flag off | M–L (the wave's new infrastructure) |
| B-3 ★ | Web/ (new) | **Wire-view in a browser** — the H3 moment: wasm LyteWire + JS shims (datagram pump, injected clock/RNG, IndexedDB identity); PIN-PAKE pairing, Noise IK dial, capabilities exchange, CTRL channel, live stats panel (books, RTT, loss) — NO video | Mac-side dev vs pup host | B-1, B-2 | one browser session against pup at committed HEAD: pair fresh via PIN, re-dial zero-UI from stored identity, capabilities intersect truthfully, CTRL echo + stats live, clean typed teardown; 0 unseal failures both ends | M |
| B-4 ★ | Web/ + Host/ (serializes with B-2's owner) + Wire/ (vector append) | Video: `av1 = 2` capability id (vector APPEND), OBU-aware frame check at the packetizer seam, `av1_nvenc` browser-session profile; browser side: depacketize/FEC-repair in wasm → WebCodecs `VideoDecoder` → canvas; HEVC path exercised on Safari | needs pup (NVENC) | B-3; owner decision B | 2048×1280@50 renders in Chrome (AV1) and Safari (HEVC) on the LAN; damage-driven repair observable in the browser books under a loss leg; frozen vectors: appended cases only, all 13 files still byte-exact on all THREE platforms | M |
| B-5 | Web/ | Audio + input: Opus via `AudioDecoder` + AudioWorklet ring; pointer/keyboard → typed input messages; Pointer Lock; Keyboard Lock where Chromium | pup for live | B-3 (B-4 for joint feel) | audio plays at 5 ms cadence without gross artifacts alongside video; typed input drives the host desktop; capture asterisks documented per engine | M |
| B-6 | Web/ | Clipboard (CTRL v1 messages + gesture-gated `navigator.clipboard`, same consent posture) + minimal UI: connect/PIN flow, stats toggle, the honest unsupported-browser refusal | Mac-local mostly | B-3, B-5 | text clipboard both directions in Chrome + Safari; UI holds the LYTE-PLAN §10 line (capabilities on/off, no knob farm) | S–M |

**The J-G3 amendment this doc proposes** (the H3 plan asked the scoping
doc to name the browser's minimal bar): *"In one live run, a stock browser
on the LAN pairs with lyte-host via PIN, re-dials zero-UI, and holds a
healthy CTRL + stats session over WebTransport (B-3's gate), without
disturbing any native-path gate."* — that is the MUST. **B-4 video is the
target** and the wave should fight for it — a browser rendering pup's
desktop is the headline. **The cut line falls after B-4: B-5 and B-6 are
declared H4 spill unless the wave runs ahead.** Grounds for the flag: the
H3 wave already carries F-2 (in flight) + F-3/F-4 + F-5 + the wire-v2 doc;
B-2 is genuinely new infrastructure (a QUIC/H3 leaf) whose integration
risk is untested; and solo-maintainer arithmetic was the H3 plan's own
named risk before six B-slices existed. B-1 is cheap insurance regardless
of everything else — take it immediately.

Worker discipline: B-1 needs two lines in Wire/ — coordinate with the F-2
worker's territory lock (or land it as F-2 exits; the guard collides with
nothing). B-2 is a Host/ slice; B-4 touches Host/ + Wire/ vectors and
serializes behind B-2 and F-2's vector freeze respectively. Web/ is virgin
territory throughout.

## 6. Decisions the owner must make

- **A. Host QUIC posture — in-process leaf or same-box sidecar?**
  Recommendation: **in-process lsquic C leaf** behind `--browser`,
  `#if os(Linux)`, with a one-paragraph amendment note to the decision
  record (its QUIC rejection was about the CORE transport; an optional
  browser-edge leaf that the native path never links is a different
  animal). The sidecar keeps `lyte-host` purer at the cost of a second
  artifact + supervision story — the ops burden this product refuses.
- **B. Browser-session codec profile.** Recommendation: **offer
  `[hevc, av1]`, let the existing intersection choose; no H.264.**
  AV1+HEVC covers 99.73% of 2026 browser sessions; H.264 would buy the
  residue at the price of a third NVENC profile and the worst
  quality-per-bit. Sub-question folded in: `av1 = 2` id assignment rides
  the D-5 wire-version discussion (it is an append, not a version bump —
  but D-5 is where codec-id bookkeeping is already headed).
- **C. Certificate + page-serving UX.** The host self-mints ECDSA P-256,
  rotates ≤ 14 days, and the page needs a secure context. Recommendation:
  **the host serves the viewer page itself over HTTPS with the same
  cert** — one interstitial accept per browser profile (self-signed), and
  from then on the page arrives knowing the current cert hash, so
  WebTransport dials cleanly forever (rotation refreshes the embedded
  hash at page load; a mid-session rotation grace window keeps standing
  sessions alive). Alternative (hash typed/pasted from the pairing flow)
  is clunkier and buys nothing on a LAN where the host is already the
  trust anchor via PIN-PAKE. Named honestly: Safari 26.4 (macOS 26) is
  the browser floor for WebTransport — older Safari gets the truthful
  refusal screen.
- **D. (Confirm) the cut line.** B-3 as the J-G3 MUST, B-4 target,
  B-5/B-6 H4-spill-unless-ahead — §5's proposal, the owner's call.

## 7. What this doc did NOT do

No repo code was touched; no pup contact; the probe artifacts live in
`/tmp/lyte-wasm-probe/` (disposable) and the toolchain additions are
user-local (`~/.swiftly`, `~/.wasmtime` — removable with `swiftly
uninstall 6.3.3` and deleting the directories). The working tree's Wire/
(F-2 in flight) was deliberately NOT probed — `git archive 7517b78` was.
JavaScriptKit interop, the AudioWorklet, and lsquic's actual ergonomics
are B-3/B-5/B-2's first hours respectively, not this doc's claims.
