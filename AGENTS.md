# AGENTS.md — how to work in this repo

Stable conventions, architecture, and hard rules for the Lyte repo. For
*current* state (what's committed, what slice is next, live-run results),
read `HANDOFF.md` — the tracked session ledger. This file holds only what
doesn't change session to session.

## What Lyte is

A GPLv3 remote-desktop system where we own both ends: a SwiftUI macOS
client and a Swift Linux host. The core decision (2026-07-20): **both ends
speak exactly one protocol, Lyte-UDP** — our own protocol over plain UDP.
H2 functional parity (input, 5 ms audio, congestion control, targeted
repair) closed 2026-07-22 with the H2 joint gate. The GameStream/Sunshine
dialect never existed on the host; the client's old GameStream stack and
the Sunshine install on the reference host were demolished at the H2 exit
(2026-07-22) — Lyte↔Lyte is the only path. Depth:
`docs/20260720-215100-lyte-udp-decision.md` (the decision record) and
`docs/20260720-222500-lyte-build-plan.md` (the master plan — slice ladder,
gates, the H0a/H0b/H1/H2/H3+ milestones).

## Repo structure — three SwiftPM packages (all swift-tools-version 6.0)

- **`Wire/`** — package `LyteWire`: the shared, sans-IO, Foundation-free
  protocol core both ends import. Targets: `LyteWire` (codecs, FEC, Noise,
  vocabulary), `CNanorsWire` (vendored nanors RS-FEC C leaf),
  `LyteWireTestKit` (vector loaders; may use Foundation),
  `lyte-wire-vectorgen` (vector authoring tool). One sanctioned dependency:
  swift-crypto (`import Crypto`, lint-confined to `Sources/LyteWire/Crypto/`;
  CryptoKit forbidden everywhere). Builds and tests on macOS and Linux —
  byte-exact cross-platform is a gate, not a hope.
- **`Host/`** — package `LyteHost`: the Linux host. Depends on
  `.package(path: "../Wire")`. `HostCore` (pure Swift bitstream helpers) and
  `HostWire` (packetizer/FEC/pacer wiring onto LyteWire) build and test
  everywhere, macOS included. The `lyte-host` executable and the C leaves
  (`CPipeWireCapture`, `CHevcEncode`, `CPipeWireAudio`, `COpusEncode`,
  `CNetIO`, `CInputUinput`, plus the `CDBus`/`CPipeWire`/`CLibAV`/`COpus`
  system-library modules) exist only under `#if os(Linux)` in the manifest.
- **Root** — package `Lyte`: the macOS client (macOS-only; SwiftUI app
 `Lyte`, `lyte-cli`). `LyteTransport` is the whole client protocol stack
 (imports LyteWire): socket + demux, video/audio pipelines, discovery,
 pairing, session. `LyteUI` holds the shared AppKit shims (render view,
 icon); `lyte-helperd` + `LyteHelperProtocol` are the SMAppService AWDL
 helper pair; `COpus` is the one C leaf (libopus decode/PLC). The
 GameStream stack (`LyteKit`/`CEnet`/`CNanors`) was deleted at the H2
 exit per the demolition checklist in
 `docs/20260720-221103-build-plan-client.md`.

## Build & test

Mac (Command Line Tools lack XCTest, hence DEVELOPER_DIR):

```
cd Wire && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Host && DEVELOPER_DIR=/Applications/Xcode.app swift test
DEVELOPER_DIR=/Applications/Xcode.app swift test        # root, from repo root
```

The no-Foundation lint (`Wire/Scripts/lint-no-foundation.sh`) runs
automatically inside `swift test` via `NoFoundationLintTests` — CI needs
nothing beyond `swift test`. It can also be invoked directly; it fails on
any Foundation/Dispatch/Network import in `Wire/Sources/LyteWire` and on
`import Crypto` outside `Crypto/`.

Client binaries that contact a host: use `Scripts/build-cli.sh` /
`Scripts/make-app.sh` so the stable "Lyte Dev" signature preserves Keychain
authorization (`docs/MACOS-SIGNING.md`).

### Reference host (pup) — facts specific to THIS box, not repo-wide rules

`pup` = the Linux host at 10.0.0.249 (`ssh pup`): Ubuntu 26.04, GNOME/Mutter
Wayland, RTX 4050, PipeWire, Swift 6.1.2 at `/usr/local/bin/swift`,
passwordless sudo. Source syncs there; `Host/Package.swift` needs Wire as a
sibling directory:

```
rsync -a --delete --exclude .build Wire/ pup:src/Wire/
rsync -a --delete --exclude .build Host/ pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build'
```

The `LD_LIBRARY_PATH` shim is a **local pup-box workaround only**: Swift
6.1.2's build tools want `libxml2.so.2`, which Ubuntu 26.04 doesn't ship
(it has `.so.16`), so `~/.local/lib/swift-compat/libxml2.so.2` symlinks to
the system `libxml2.so.16`. Not a universal requirement.

`lyte-host` must run inside the logged-in, unlocked graphical session
(portal capture is inhibited otherwise). First portal run shows a one-time
consent dialog on the host's physical screen; the persisted restore token
makes later runs headless.

## Architecture doctrine (LYTE-PLAN §4 + the decision record)

- **Pure Swift, both ends. C only at hardware/OS leaves** — on the host:
  PipeWire, NVENC/libavcodec, D-Bus, libopus, the UDP socket (CNetIO's
  cmsg/sendmmsg syscalls), uinput (CInputUinput, the input fallback); in
  Wire: nanors. Everything above a leaf is Swift.
- **LyteWire is sans-IO**: no Foundation, no sockets, no threads; clocks
  and randomness are injected. It must stay WASM-compilable — the future
  browser client imports the same core. The rule is lint-enforced, not
  trusted.
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
- Don't push unless asked (main runs ahead of origin by convention).
  Avoid `--amend`.

**HANDOFF.md** is the tracked session ledger (in the repo since `8da50bf`;
the `.gitignore` entry is vestigial and inert for a tracked file). Read it
first for current state and the resume point; edit it freely; commit
updates in the ledger voice.

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

## Doc map — where to look next

- `HANDOFF.md` — current state, what's committed, resume point (start here).
- `docs/20260720-222500-lyte-build-plan.md` — master plan: slices, gates,
  waves, checkpoints.
- `docs/20260720-215100-lyte-udp-decision.md` — why Lyte-UDP only, what
  was dropped, what survives.
- `LYTE-PLAN.md` — overall strategy; §4 technology commitments, §6 host
  ladder.
- Pillars + overview (`docs/20260720-1917*`, `docs/20260720-193000`) — the
  protocol spec.
- `docs/HOST-PLAN.md` — capture/encode/input detail (its wire mandate is
  superseded; see its banner). `Host/README.md` — host build/run specifics.
- `Wire/Vectors/README.md` — the wire formats as frozen data, plus the
  freeze policy.
