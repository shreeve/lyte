# AGENTS.md — how to work in this repo

Stable conventions, architecture, and hard rules for the Lyte repo. For
*current* state (what's committed, what slice is next, live-run results),
read `HANDOFF.md` — the tracked session ledger. This file holds only what
doesn't change session to session.

## What Lyte is

An MIT-licensed remote-desktop system where we own both ends: a SwiftUI macOS
client and a Swift Linux host. The core decision (2026-07-20): **both ends
speak exactly one protocol, Lyte-UDP** — our own protocol over plain UDP.
H2 functional parity (input, 5 ms audio, congestion control, targeted
repair) closed 2026-07-22 with the H2 joint gate. The GameStream/Sunshine
dialect never existed on the host; the client's old GameStream stack and
the Sunshine install on the reference host were demolished at the H2 exit
(2026-07-22) — Lyte↔Lyte is the only path. Depth:
`docs/20260720-215100-lyte-udp-decision.md` (the decision record); the
H-era build plans completed their ladder and are retired to git history
(`git show 4bb3e11:docs/20260720-222500-lyte-build-plan.md`).

## Repo structure — four SwiftPM packages (all swift-tools-version 6.0)

- **`Wire/`** — package `LyteWire`: the shared, sans-IO, Foundation-free
  protocol core both ends import. Targets: `LyteWire` (codecs, FEC, Noise,
  vocabulary), `CNanorsWire` (vendored nanors RS-FEC C leaf),
  `LyteWireTestKit` (vector loaders; may use Foundation),
  `lyte-wire-vectorgen` (vector authoring tool). It imports the sibling
  `LyteCore` utility layer; its one sanctioned external dependency is
  swift-crypto (`import Crypto`, lint-confined to `Sources/LyteWire/Crypto/`;
  CryptoKit forbidden everywhere). Builds and tests on macOS and Linux —
  byte-exact cross-platform is a gate, not a hope.
- **`Common/`** — package `LyteCommon`: the v2 shared layer beside (never
  inside) frozen LyteWire. `LyteCore` is sans-IO shared policy with injected
  time; `LyteIO` is the operating-system adapter layer both ends consume.
  `LyteCore.Histogram` owns the shared percentile and retention doctrine;
  `LyteCore.AnnexBCheck` owns the one NAL walker and production access-unit
  splitter; `LyteCore.HevcBitWriter`/`HevcBitReader` are the inverse bit and
  emulation-prevention vocabulary; `LyteCore.Sha256` is the one streaming and
  one-shot digest model; `LyteCore.Hex` is the one byte/integer hex spelling;
  `LyteCore.WireTos` owns the four product DSCP lanes; `LyteCore.ChromaPairing`
  owns the Best singleton shape while the host/client role types stay split;
  `LyteCore.BoundedRendererHandoff` owns dependency-episode queue and recovery
  verdicts while CoreMedia sample adaptation stays in the client shell;
  the first extracted adapter is the one process-wide monotonic clock;
  `LyteVideoPipeline` receives that clock through its constructor;
  `COpus` is the one shared libopus system-library module.
- **`Host/`** — package `LyteHost`: the Linux host. Depends on
  `.package(path: "../Wire")` and, for Linux shells, `../Common`.
  `HostCore` (pure Swift bitstream helpers) and
  `HostWire` (packetizer/FEC/pacer wiring onto LyteWire) build and test
  everywhere, macOS included. The `lyte-host`/`lyte-eye`/`lyte-nvenc`
  executables, `HostEye` (the direct eye: KMS doorbell + EGL blit +
  native VAAPI pens), and the C leaves (`CPipeWireAudio`, `COpusEncode`,
  `CNetIO`, `CInputUinput`, plus the `CDBus`/`CPipeWire`/
  `CDRM`/`CGBM`/`CEGL`/`CVA`/`CNvEnc`/`CCuda` system-library modules)
  exist only under `#if os(Linux)` in the manifest. The portal-era
  leaves (`CPipeWireCapture`, `CHevcEncode`, `CLibAV`, the vendored
  ffmpeg) were demolished in E5 (2026-08-02, tag `self-hosted`).
- **Root** — package `Lyte`: the macOS client (macOS-only; SwiftUI app
 `Lyte`, `lyte-cli`). `LyteTransport` is the whole client protocol stack
 (imports LyteWire and LyteIO): socket + demux, video/audio pipelines,
 discovery,
 pairing, session. `LyteCorpus` is the corpus/diagnostic harness
 (corpus frames, gate math, PNG IO, the decode readback tap, the
 quality scorer) — consumed only by lyte-cli, the app's env-gated
 benchmark, and tests; the streaming stack carries no harness code.
 `LyteUI` holds the shared AppKit shims (render view,
 icon); `lyte-helperd` + `LyteHelperProtocol` are the SMAppService AWDL
 helper pair; the client decoder/PLC consumes Common's `COpus` leaf. The
 GameStream stack (`LyteKit`/`CEnet`/`CNanors`) was deleted at the H2
 exit per the demolition checklist in the client build plan (retired
 to git history).

## Build & test

Mac (Command Line Tools lack XCTest, hence DEVELOPER_DIR):

```
cd Wire && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Common && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Host && DEVELOPER_DIR=/Applications/Xcode.app swift test
DEVELOPER_DIR=/Applications/Xcode.app swift test        # root, from repo root
```

The no-Foundation lints (`Wire/Scripts/lint-no-foundation.sh` and
`Common/Scripts/lint-no-foundation.sh`) run automatically inside their
packages' `swift test` via `NoFoundationLintTests` — CI needs nothing beyond
the package suites. They fail on Foundation/Dispatch/Network imports in the
sans-IO cores; Wire additionally confines `import Crypto` to `Crypto/`, while
LyteCore forbids crypto imports entirely.

Client binaries that contact a host: use `Scripts/build-cli.sh` /
`Scripts/make-app.sh` so the stable "Lyte Dev" signature preserves Keychain
authorization (`docs/MACOS-SIGNING.md`).

### Reference host (pup) — facts specific to THIS box, not repo-wide rules

`pup` = the Linux host, WIRED at 10.0.0.232 (`ssh pup`; Wi-Fi backup at
.249): Ubuntu 26.04, GNOME/Mutter Wayland, Intel Meteor Lake Arc iGPU
(owns the panel; the direct eye encodes on it) + RTX 4050, PipeWire,
Swift 6.1.2 at `/usr/local/bin/swift`, passwordless sudo. Source syncs
there; `Host/Package.swift` needs Wire and Common as sibling directories:

```
rsync -a --delete --exclude .build Wire/ pup:src/Wire/
rsync -a --delete --exclude .build Common/ pup:src/Common/
rsync -a --delete --exclude .build Host/ pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build'
```

No ffmpeg env exists anymore (E5 demolished the vendored lib; a plain
build is itself a gate). After EVERY rebuild, re-arm the DRM ticket:
`sudo -n setcap cap_sys_admin+ep .build/debug/lyte-host` (and
`lyte-eye` when used) — the owner's standing loop respawns onto the
new binary. The `LD_LIBRARY_PATH` shim is a **local pup-box workaround
only**: Swift 6.1.2's build tools want `libxml2.so.2`, which Ubuntu
26.04 doesn't ship (it has `.so.16`), so
`~/.local/lib/swift-compat/libxml2.so.2` symlinks to the system
`libxml2.so.16`. Not a universal requirement.

Capture needs no session and no consent dialog (the direct eye reads
the scanout with CAP_SYS_ADMIN; pairing is the consent model). The
input/clipboard leaves still use the Mutter RemoteDesktop session bus
when present.

## Architecture doctrine (LYTE-PLAN §4 + the decision record)

- **Pure Swift, both ends. C only at hardware/OS leaves** — on the host:
  PipeWire audio, libva/DRM/EGL module maps (the direct eye), D-Bus,
  libopus, the UDP socket (CNetIO's cmsg/sendmmsg syscalls), uinput
  (CInputUinput, the input fallback); in Wire: nanors. Everything above
  a leaf is Swift — since E5, including the HEVC bitstream itself
  (HostCore's pens).
- **LyteWire is sans-IO**: no Foundation, no sockets, no threads; clocks
  and randomness are injected. It must stay WASM-compilable — the future
  browser client imports the same core. The rule is lint-enforced, not
  trusted.
- **LyteCore policy is single-threaded value state**: platform shells own
  locks. The video conductor and delivery gauge carry no synchronization;
  their client controllers/books are the cross-queue adapters.
- **Client video policy receives time**: `LyteVideoPipeline` receives
  nanoseconds and `VideoFlightRecorder` receives microseconds through
  mandatory constructors; neither reads an OS clock internally.
- **`VideoSink` is the client render organ**: pipeline and session submit only
  through the named seam. The app handoff, wire-view's AVFoundation adapter,
  and the test target's headless sink are its concrete owners.
- **Test vectors are frozen wire contracts**, not fixtures
  (`Wire/Vectors/README.md`). A committed vector file never regenerates: if
  codec and vector disagree, that is a wire-contract break to investigate.
  New cases append; changed semantics mean a new file version and a
  wire-version discussion first. Byte-exact equality on macOS AND Linux is
  part of the gates.
- **Transport-agnostic core, packetizer as leaf**: nothing above the socket
  knows the carrier is plain UDP (the `LyteTransport` facade keeps QUIC
  re-adoptable); geometry/budget decisions live at the packetizing seam.
- The pillar docs are the protocol spec — reference, don't restate:
  `docs/20260720-19170{1,2,3,4}-lyte-protocol-*.md` (image quality, timing,
  resiliency, transport) reconciled by
  `docs/20260720-193000-lyte-protocol-overview.md`.

## Conventions & hard rules

**Commits.**
- Stage per package: `git add Wire/`, `git add Host/`, etc. NEVER
  `git add -A`.
- Repo commit voice: declarative first line with an em-dash flourish,
  why-focused body. Real examples:
  - `W5: the wire goes dark — Noise IK lands against the published vectors, and every shard now rides under a 16-byte proof`
  - `HS-4: every datagram carries its own colors — CNetIO drives per-packet DSCP and kernel TX timestamps from Swift`
- NO AI-attribution trailers or co-author lines, ever.
- Avoid `--amend`. Never force-push main.
- **The PR train is the working pattern** (established with the
  2026-07-30 audit sweep, #1–#19): branch → fix → reproducing pin →
  suites green on Mac AND pup → `gh pr create` → merge with a
  ledger-voice subject carrying `(#N)` → record the landing → push.
  Main is pushed as part of the train; land on success, close on
  failure. PR association lives in the `(#N)` subject suffix. The
  sweep-era PRs squash-merged; when `gh pr merge` is unavailable,
  landing via `git merge --no-ff` with the `(#N)` subject is the
  accepted fallback (#72, #73 landed that way).

**HANDOFF.md** is the tracked session ledger. Read it first for current
state and the resume point; edit it freely; commit updates in the
ledger voice. It carries only what is live — frozen history is in
git history (`git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`).

**Networking / host safety.**
- Lyte UDP work uses 41000-range ports by convention. (The old "stay off
  47998–48010" rule protected Sunshine; Sunshine was uninstalled at the H2
  exit and the rule is retired.)
- Never touch `~/.config/lyte-host/{portal_token,noise_static.key,
  paired_clients}` — verify they survive any run that goes near them.
- Scope any netem/tc impairment to the specific Lyte port
  (`Scripts/netem/lo-netem.sh` is the pattern — prio+u32 filters); remove
  it after.

**Multi-worker discipline.** One coherent worker per package territory
(`Wire/`, `Host/`, root) at a time — never two workers in one package.
Long-running live tests (soaks, netem runs) can look "stalled" from the
transcript; don't assume a worker died from idle output alone.

## The v2 program (2026-07-30 →)

v1 closed at the annotated tag **`v1-final`** after a six-agent final
review. The record: the ANALYSIS trio was retired 2026-08-02 after the
E5 demolition (full text in git history at `860369a` —
`git show 860369a:ANALYSIS.md`); the still-open findings live in
TODO.md's "ANALYSIS ledger — the live remainder" section, beside the
audit-caveats section. The v2 laws are `docs/20260730-115707-lyte-v2-rulings.md` — **read
them as constraints, never re-litigate**: one repo forever (no v1/v2
split, convergence in place, always green); target shape
Client / Common / Host with Common split as `Common/Sources/LyteCore`
(`LyteCore`, sans-IO, lint-guarded) / `Common/Sources/LyteIO` (`LyteIO`,
shared OS adapters, adapters-never-policy) /
`Common/Sources/LyteTestKit` (`LyteTestKit`); fix before
spec; spec before code; rebuild only earned organs against the frozen
vectors. Phase order: the ANALYSIS Tier 1/2 PR train → multi-agent
spec phases (inventory → design panels → adversarial review →
synthesis, artifacts under `Docs/spec-drafts/`) → tree migration →
organ rebuilds.

## Doc map — where to look next

- `HANDOFF.md` — current state, what's committed, resume point (start here).
- `docs/README.md` — the docs card catalog: living vs frozen vs
  reference studies, one line each.
- TODO.md's "ANALYSIS ledger — the live remainder" — every still-open
  defect from the v1-final review (the retired ANALYSIS trio's full
  text: `git show 860369a:ANALYSIS.md`).
- `docs/20260730-115707-lyte-v2-rulings.md` — settled v2 law.
- `docs/20260801-105800-direct-eye-plan.md` — the direct-eye epoch,
  E0–E5 (complete; `self-hosted`) ·
  `docs/20260802-013946-postures-design.md` — the active postures track.
- `docs/20260720-215100-lyte-udp-decision.md` — why Lyte-UDP only, what
  was dropped, what survives.
- `LYTE-PLAN.md` — overall strategy; §4 technology commitments, §6 host
  ladder.
- Pillars + overview (`docs/20260720-1917*`, `docs/20260720-193000`) — the
  protocol spec.
- `Host/README.md` — host build/run specifics.
- `Wire/Vectors/README.md` — the wire formats as frozen data, plus the
  freeze policy.
