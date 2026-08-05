# AGENTS.md — repository law

This file contains stable engineering rules for Lyte. Read `HANDOFF.md`
first for the current branch, next slice, test results, and live-rig state.
Read `TODO.md` for deliberately deferred work. Do not put completed history
in any of these files; Git already owns it.

## System identity

Lyte is an MIT-licensed remote-desktop system whose macOS client and Linux
host speak exactly one independently owned protocol: Lyte-UDP over plain
UDP. The product contains no Sunshine, Moonlight, GameStream, RTSP, RTP,
VNC, or RDP compatibility path. The decision record is
`docs/20260720-215100-lyte-udp-decision.md`; the protocol specification is
the four `docs/20260720-19170*-lyte-protocol-*.md` pillars reconciled by
`docs/20260720-193000-lyte-protocol-overview.md`.

## Package ownership

All five packages use Swift tools version 6.0 and the source-layout grammar
in `docs/20260803-084328-source-layout-and-migration.md`.

- **`Wire/` — `LyteWire`:** Foundation-free, sans-IO protocol codecs,
  cryptography, FEC, state machines, vocabulary, and frozen vectors.
  `CNanorsWire` is the vendored Reed-Solomon C leaf;
  `LyteWireTestKit` owns reusable vector equipment. Swift Crypto is its sole
  external dependency and `import Crypto` is confined to
  `Sources/LyteWire/Crypto/`.
- **`Common/` — `LyteCommon`:** `LyteCore` owns shared sans-IO policy and
  injected-time utilities; `LyteIO` owns shared OS adapters;
  `LyteTestKit` owns reusable shared test equipment. Adapters never own
  policy. `COpus` is the one pinned, statically propagated libopus source
  leaf; its upstream BSD license remains separate from Lyte's MIT license.
- **`Host/` — `LyteHost`:** `HostCore` owns pure host policy and bitstream
  helpers; `HostSession` owns IO-free responder policy with injected time and
  randomness; `HostAudio` owns Swift host codec policy over the shared
  `COpus` mechanism; `HostWire` executes session decisions through
  packetization, FEC, pacing, and wire orchestration. Linux-only executables
  and hardware/OS C leaves stay behind `#if os(Linux)` in the manifest. Pure
  targets must build on macOS too.
- **`Client/` — `Lyte`:** macOS-only app and CLI. `LyteClientCore` owns pure
  client-role policy; `LyteClientSession` owns IO-free initiator/session
  orchestration; `LyteTransport` owns the client protocol/media and macOS IO
  stack; `LyteCorpus` owns diagnostic and benchmark machinery; `LyteUI`
  owns shared AppKit shims;
  `LyteClientTestKit` owns reusable client test equipment. Production
  streaming code must not depend on corpus or harness code.
- **`SystemTests/` — `LyteSystemTests`:** cross-role composition tests that
  import exported Client and Host libraries. It owns no production code and
  does not justify a dependency between Client and Host.

Every Swift package uses `Sources/<Target>/` for Swift source and
`Tests/<Target>Tests/` for XCTest targets. Reusable Swift test equipment is
named `<Domain>TestKit` and lives under `Sources/`; `Tests/` never means a
reusable library. C/system-library leaves stay explicit and narrow.

## Architecture doctrine

- **Swift above leaves.** C is allowed only at hardware/OS boundaries:
  DRM/GBM/EGL/VAAPI/CUDA/NVENC module maps, PipeWire audio, libopus, UDP
  syscalls, D-Bus, uinput, and nanors. HEVC bitstream policy is Swift.
- **Sans-IO cores.** `LyteWire` and `LyteCore` contain no Foundation,
  Dispatch, Network, sockets, threads, or OS clocks. Time and randomness are
  injected. Their lints run as package tests. `LyteWire` must remain
  WASM-compilable.
- **One owner per concept.** Shared policy lives in `LyteCore`; wire
  contracts in `LyteWire`; role policy stays with its role. Extract only
  when a real second owner exists—similar-looking role code is not itself a
  shared abstraction.
- **Value policy, shell synchronization.** Core policy is single-threaded
  value state. Platform shells own queues, actors, and locks.
- **Named media organs.** Client rendering enters through `VideoSink`;
  host capture enters through `ScreenSource`. Core policy cannot reach
  around these seams into platform frameworks.
- **Transport-agnostic policy.** Nothing above the packetizing/socket seam
  depends on UDP carrier details. The `LyteTransport` facade preserves the
  option to adopt another carrier without changing protocol policy.
- **Frozen vectors are contracts.** Never regenerate a committed vector to
  make a test pass. Append new cases. Changed semantics require a new vector
  version and an explicit wire-version decision. macOS and Linux bytes must
  match exactly.
- **One protocol path.** Feature messages are capability-negotiated,
  session-scoped, size-bounded, consent-gated, origin-aware where reflective,
  and never payload-logged. Encryption is always on.

Settled v2 laws live in `docs/20260730-115707-lyte-v2-rulings.md`. Treat
them as constraints: one repository, convergence in place, always green;
fix before spec, spec before code; rebuild only earned organs against frozen
contracts.

### Standing rulings

- Chroma is a three-tier session posture: Good = 4:2:0, Better = 4:2:2
  (dormant until real hardware offers it), Best = 4:4:4. Changing chroma
  means a clean reconnect; it is never a mid-stream encoder dial.
- The shipping color path is 601-limited. Full-range is named and queued;
  GBR identity-matrix output is out because CoreMedia has no matching
  vocabulary.
- Keep the capped-CQ FEC posture. A group-index change or split-group frame
  design requires a wire-v2 decision first.
- Rate changes must not reset the encoder or mint an IDR. With native pens
  this property is structural; do not reintroduce a reset-based path.
- Monitor selection is deferred until a real multi-monitor host exists.
  Geometry changes are fixed at announce time and require a typed teardown
  plus reconnect.

## Build and test

macOS Command Line Tools lack XCTest, so use full Xcode explicitly:

```sh
cd Wire && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Common && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Host && DEVELOPER_DIR=/Applications/Xcode.app swift test
DEVELOPER_DIR=/Applications/Xcode.app swift test \
  --package-path Client --scratch-path .build
cd SystemTests && DEVELOPER_DIR=/Applications/Xcode.app swift test
```

Client binaries that contact a host must be built through
`Scripts/build-cli.sh` or `Scripts/make-app.sh`; the stable "Lyte Dev"
signature preserves Keychain authorization. Quit a running app before
rebuilding its bundle, then use `Scripts/launch-app.sh` so LaunchServices
registers the exact published artifact. See `docs/MACOS-SIGNING.md`.

### Reference host: pup

`pup` is the Linux reference host, wired at `10.0.0.232` (`ssh pup`; Wi-Fi
backup `.249`). It runs Ubuntu 26.04 on an Intel Meteor Lake display GPU
plus an RTX 4050 with no attached connectors. Swift 6.1.2 is at
`/usr/local/bin/swift`.

Sync sibling packages before Host because its manifest uses relative paths:

```sh
rsync -a --delete --exclude .build Wire/ pup:src/Wire/
rsync -a --delete --exclude .build Common/ pup:src/Common/
rsync -a --delete --exclude .build Host/ pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build -c release'
```

The `LD_LIBRARY_PATH` shim is specific to pup: Swift's build tools request
`libxml2.so.2`, while Ubuntu provides `.so.16`. It is not a product
dependency. No ffmpeg environment exists; a plain build is a gate.

The standing host is the release-built system service `lyte-host.service` on
UDP 41151.
After a deployed rebuild, run `sudo -n systemctl restart lyte-host`; its
ambient capability grants direct-eye DRM access. Hand-run `lyte-eye` or
host binaries need `sudo -n setcap cap_sys_admin+ep <exact-binary>`.
Details and current operational deviations belong in `HANDOFF.md`.

## Safety

- Never touch pup's
  `~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`.
  Verify them before and after any run that approaches identity state.
- Never displace the owner's standing UDP 41151 service. Test hosts use an
  explicit fresh 41xxx port and `--no-advertise`.
- Scope netem/tc impairment to the exact Lyte port, following
  `Scripts/netem/lo-netem.sh`, and remove it after the run.
- Do not launch a benchmark app while the owner's interactive app is open;
  both use the same bundle identity and a diagnostic launch can replace the
  real client.

## Change discipline

- Start from `HANDOFF.md`; keep it accurate as live state changes.
- Preserve unrelated user changes in a dirty worktree.
- Stage by territory (`git add Wire/`, `git add Host/`, or explicit root
  files). Never use `git add -A`.
- Use `apply_patch` for edits. Prefer `rg`/`rg --files` for discovery.
- Commit subjects are declarative, use the repository's em-dash flourish,
  and explain why in the body. Never add AI attribution or co-author lines.
- Avoid amend. Never force-push main.
- Use the PR train: branch → change → reproducing pin → Mac and pup gates →
  `gh pr create` → merge with `(#N)` in the landing subject → record the
  landing → push.
- One coherent worker owns a package territory at a time. Long live tests
  may be quiet; silence alone is not failure.

## Document ownership

- `README.md` — public product identity, architecture, and direction.
- `AGENTS.md` — stable repository and engineering law.
- `HANDOFF.md` — short, current resume point and live operational state.
- `TODO.md` — deferred actionable work only.
- `LICENSE` — legal terms; never paraphrase or consolidate it.
- `docs/README.md` — catalog for living decisions and frozen records.

The former root strategy document is retired at this cleanup. Its valid
product direction is now in `README.md`; its implementation law is here;
its protocol, design, and historical decisions remain in the dated records.
Recover the final pre-retirement copy with
`git show 59e8bb4:LYTE-PLAN.md`.
