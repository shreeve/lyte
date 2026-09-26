# AGENTS.md — repository law

Stable engineering rules for Lyte. Current branch, live rig state and next
work: [HANDOFF.md](HANDOFF.md). Deferred work: [TODO.md](TODO.md). How the
code is laid out today: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Git
owns completed history; do not write it into these files.

## System identity

Lyte is an MIT-licensed remote-desktop system whose macOS client and Linux
host speak one independently owned protocol, Lyte-UDP, over plain UDP.
There is no Sunshine, Moonlight, GameStream, RTSP, RTP, VNC or RDP
compatibility path ([decision](docs/decisions/20260720-215100-lyte-udp-decision.md)).
The current wire contract is [docs/PROTOCOL.md](docs/PROTOCOL.md) backed by
the vectors in `Wire/Vectors/`; the dated pillar documents are history.

## Package ownership

Six SwiftPM packages, Swift tools version 6.0, Swift 6 language mode. Who
owns which concept, target by target, is
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#targets); these are the rules.

- **`Common/` — `LyteCommon`:** `LyteCore` owns shared sans-IO policy and
  injected-time utilities, the Conductor included; `LyteIO` owns shared OS
  adapters, which never own policy; `COpus` is the one pinned, statically
  linked libopus leaf (BSD, separate from Lyte's MIT license).
- **`Wire/` — `LyteWire`:** sans-IO codecs, cryptography, FEC, ARQ, state
  machines, vocabulary and the frozen vectors. Swift Crypto is the only
  external dependency, and `import Crypto` is confined to
  `Sources/LyteWire/Crypto/`. The `LyteWireVectorGen` library owns every
  vector file's model and builder: test targets may depend on it,
  production never does. `LyteWireTestKit` owns the vector loader and
  reusable wire test equipment.
- **`Host/` — `LyteHost`:** `HostCore`, `HostSession` and `HostWire` are
  sans-IO (`HostWire` executes session decisions without doing IO).
  `HostEye` and the C leaves are Linux-only behind `#if os(Linux)` in the
  manifest; every pure target builds and tests on macOS too.
- **`Client/` — `Lyte`:** every client shell shares the one sans-IO
  initiator in `LyteClientSession`. Production streaming code never
  depends on corpus or harness code; the named exception is the `Lyte`
  app linking `LyteCorpus` for its diagnostic benchmark, and only a
  diagnostic bundle (`Scripts/make-app.sh --diagnostics`, Info.plist
  `LyteDiagnosticEntryPoints`) obeys the benchmark and witness
  environment. Sparkle ([docs/RELEASING.md](docs/RELEASING.md)) is the app
  target's only third-party dependency: nothing below the app imports it,
  and only a release bundle starts it.
- **`Browser/` — `LyteClientBrowser`:** `LyteClientBrowserCore` is sans-IO
  over the shared cores. Page JavaScript owns browser IO (WebTransport,
  WebCodecs, WebGPU, the AudioWorklet ring, DOM input) and never
  reimplements protocol or Conductor policy. `Host` is a test-only
  dependency.
- **`SystemTests/` — `LyteSystemTests`:** tests that compose the exported
  Client and Host libraries. It owns no production code and does not
  justify a dependency between Client and Host.

Client never imports Host and Host never imports Client. Every package uses
`Sources/<Target>/` for sources and `Tests/<Target>Tests/` for a target's
own tests; a suite that composes several targets is named for what it
composes (`LyteClientHostTests`, `LyteHostIntegrationTests`). Reusable test
equipment is named `<Domain>TestKit` and lives under `Sources/`; only test
targets, other TestKits and the vector builders depend on it, and no
shipping target in any package imports XCTest, a TestKit or
`LyteWireVectorGen`. Common's `RoleBoundaryTests` and `SingleOwnerTests`
enforce both boundaries.

## Architecture doctrine

- **Swift above leaves.** C is allowed only at hardware and OS boundaries:
  DRM/GBM/EGL/VAAPI module maps, PipeWire audio, libopus, UDP syscalls,
  D-Bus, uinput and nanors. HEVC bitstream policy is Swift.
- **Sans-IO cores.** `LyteCore`, `LyteWire`, `LyteClientCore`,
  `LyteClientSession`, `LyteClientBrowserCore`, `HostCore`, `HostSession`
  and `HostWire` contain no Foundation, Dispatch, Network, sockets,
  threads, locks or OS clocks; time and randomness are injected. Their allowed imports are declared in
  `Common/Tests/LyteTestKitTests/SansIOArchitectureTests.swift`, the one
  enforcement point. Session targets may import `LyteCore` (Core sits below
  Session). `LyteWire` must stay WebAssembly-compilable.
- **One owner per concept.** Shared policy lives in `LyteCore`, wire
  contracts in `LyteWire`, role policy with its role. Extract only when a
  real second owner exists; similar-looking role code is not a shared
  abstraction. When a second owner needs a variant, parameterize the owner
  before forking it. Client shells (native and browser) share the sans-IO
  initiator in `LyteClientSession`; a shell never grows its own.
- **Value policy, shell synchronization.** Core policy is single-threaded
  value state. Platform shells own queues, actors and locks.
- **Named media organs.** Client rendering enters through `VideoSink`; host
  capture enters through `ScreenSource`. Core policy never reaches around
  these seams into platform frameworks.
- **Transport-agnostic policy.** Nothing above the packetizing and socket
  seam depends on UDP carrier details, so another carrier (WebTransport
  today) needs no protocol-policy change.
- **Vectors are append-only contracts.** Never modify, regenerate, rename or
  delete a committed file under `Wire/Vectors/` to make a test pass. New
  cases go in new files; changed semantics need a new vector version and an
  explicit wire-version decision. The macOS gate enforces this. macOS,
  Linux and WebAssembly bytes must match exactly.
- **One protocol path.** Feature messages are capability-negotiated,
  session-scoped, size-bounded, consent-gated, origin-aware where
  reflective, and never payload-logged. Encryption is always on.

The v2 rulings still bind: one repository, convergence in place, always
green; form before spec, spec before code; rebuild only earned organs
against frozen contracts ([record](docs/decisions/20260730-115707-lyte-v2-rulings.md)).

### Standing rulings

- Chroma is a three-tier session posture: Good = 4:2:0, Better = 4:2:2
  (dormant until real hardware offers it), Best = 4:4:4. Changing chroma
  means a clean reconnect, never a mid-stream encoder dial.
- The shipping color path is BT.709 limited range: the Direct Eye blit
  converts with BT.709 coefficients and the VUI signals BT.709. Full range
  is named and queued; GBR identity-matrix output is out because CoreMedia
  has no matching vocabulary.
- Keep the capped-CQ FEC posture. A group-index change or split-group frame
  design requires a wire-v2 decision first.
- Rate changes never reset the encoder or mint an IDR. With native pens
  this is structural; do not reintroduce a reset-based path.
- Monitor selection waits for a real multi-monitor host. Geometry is fixed
  at announce time; a change is a typed teardown plus reconnect.

## Safety

Operational detail and the reasons behind each rule:
[docs/OPERATIONS.md](docs/OPERATIONS.md#safety).

- Never modify or delete pup's host identity:
  `~/.config/lyte/{noise_static.key,paired_clients}`, its knobs
  `~/.config/lyte/host.conf`, or the pre-XDG copies under
  `~/.config/lyte-host/`. Verify their SHA-256 before and after any run
  that approaches identity state.
- Never displace the owner's standing UDP 41151 service. Test hosts use a
  fresh 41xxx port and `--no-advertise`.
- Never run a second Direct Eye while the service holds the DRM seat.
  Hand-run binaries live under the home build tree (not `/tmp`), get
  `setcap cap_sys_admin+ep` on the exact binary, and lose it afterwards.
- Impair only with `Scripts/netem/port-netem.sh`, scoped to one Lyte flow,
  and remove it after the run. Live benchmarks and netem runs need the
  owner's go-ahead.
- Do not run a benchmark while the owner's interactive app is open: the
  diagnostic build is published to the same `.build/Lyte.app` with the
  same bundle identity.
- Do not deploy to or restart the standing service without the owner's
  go-ahead; deploys use `Host/Scripts/deploy-host.sh` as documented in
  [docs/OPERATIONS.md](docs/OPERATIONS.md#deploy-and-roll-back).

## Change discipline

- Start from [HANDOFF.md](HANDOFF.md); keep it accurate as live state
  changes.
- Preserve unrelated user changes in a dirty worktree.
- Stage by path (`git add Wire/`, `git add AGENTS.md HANDOFF.md`). Never
  `git add -A`.
- Commit subjects are declarative with the repository's em-dash flourish;
  the body explains why. Commits, PRs, tags and release notes carry no AI
  attribution or co-author lines.
- Avoid amend. Never force-push `main`.
- Fix a bug with a test that fails before the fix and passes after.
- Test behavior. Tests that pin source spellings, private member names,
  exact lines or file lists are not behavior tests; replace them with a
  behavioral test or delete them. Keep the import-allowlist and sans-IO
  lints, forbidden-token scans, and single-owner ratchets ("only one
  implementation of X"); a new ratchet is a row in the one token-aware
  table, `Common/Tests/LyteTestKitTests/SingleOwnerTests.swift`.
- Shell checks must fail on macOS bash 3.2, which ignores `set -e` for a
  failing bare `[[ … ]]` or `(( … ))`, and no bash fails on `! cmd`. Guard
  each check (`[[ … ]] || fail "…"`, `Scripts/lib/assert.sh`) or make it an
  `if` condition; `Scripts/Tests/test-shell-assertions.sh` lints every
  tracked script.
- Code comments state invariants. Slice ids, dates, "found live" stories
  and owner-ruling narratives belong in commit messages; git owns history.
- Repository scripts use POSIX tools (`grep`, `sed`, `awk`, `find`). `rg`
  is fine for interactive search but is not installed as a binary on every
  machine, so scripts never call it.
- Build and test commands, and what the Mac and pup gates run:
  [docs/TESTING.md](docs/TESTING.md). Client binaries that contact a host
  are built with `Scripts/build-cli.sh` or `Scripts/make-app.sh`
  ([docs/MACOS-SIGNING.md](docs/MACOS-SIGNING.md)).
- **Land a PR:** branch → change → reproducing test → Mac and pup gates →
  `gh pr create` → merge to `main` with `(#N)` in the landing subject →
  delete the branch → update `HANDOFF.md` when live state changed → push.
- One worker owns a package territory at a time. Long live tests may be
  quiet; silence alone is not failure.

## Document ownership

| File | Owns |
|---|---|
| `README.md` | Product identity, architecture sketch, quickstart, doc map |
| `AGENTS.md` | Repository law (this file) |
| `HANDOFF.md` | Current branch, live rig state, next work; at most 40 lines |
| `TODO.md` | Deferred work only; never completed narrative |
| `CHANGELOG.md` | User-visible changes per release; `Scripts/release.sh` publishes each version's section |
| `LICENSE` | Legal terms; never paraphrase or consolidate it |
| `docs/README.md` | Catalog of living docs, binding decisions and history, with status |
