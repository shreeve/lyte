# Testing

Every gate in the repository, with the flags the gate scripts use. "Mac and
pup gates" in [AGENTS.md](../AGENTS.md) means
`Scripts/CI/test-all-macos.sh` and `Scripts/CI/test-all-pup.sh`, both
passing on the commit being landed. There is no hosted CI; the gates are
run by hand.

## Requirements

- **macOS:** full Xcode. Command Line Tools lack XCTest, so export
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the gate
  defaults to `/Applications/Xcode.app`).
- **pup:** Swift 6.1.2 at `/usr/local/bin/swift` and the `LD_LIBRARY_PATH`
  shim described in [OPERATIONS.md](OPERATIONS.md#build-on-pup).
- **WebAssembly legs (optional):** swiftly, Swift 6.3.3 and the
  `swift-6.3.3-RELEASE_wasm` SDK, plus `wasmtime` for the Wire leg. Pins
  and install commands: `Scripts/lib/wasm-toolchain.sh`. On an Xcode 27
  Mac the pinned toolchain cannot compile against the macOS 27 SDK; the
  lib selects an older installed SDK, or honor `SDKROOT`.
- **Browser smoke (optional):** Google Chrome, a GPU, Node 24 or 26,
  `openssl`, and network access for the first `npm install` of
  `rwebtransport` under `Browser/Harness/`.
- **Python analyzer tests:** Python 3.9–3.12 (the gate builds a venv in
  `.build/ci-python` from `Scripts/requirements.txt`, NumPy 2.0.2); set
  `LYTE_CI_PYTHON` to pick the interpreter.

## Package tests

Run from the repository root. These are the gate's exact commands; the gate
also runs `swift package resolve` first and `swift package clean` when the
build graph changed.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path Common      --scratch-path Common/.build      -Xswiftc -warnings-as-errors
swift test --package-path Wire        --scratch-path Wire/.build        -Xswiftc -warnings-as-errors
swift test --package-path Host        --scratch-path Host/.build        -Xswiftc -warnings-as-errors
swift test --package-path Client      --scratch-path Client/.build      -Xswiftc -warnings-as-errors
swift test --package-path SystemTests --scratch-path SystemTests/.build -Xswiftc -warnings-as-errors
swift test --package-path Browser     --scratch-path Browser/.build     -Xswiftc -warnings-as-errors
```

Never point Client's scratch path at the repository root `.build`: it holds
the published `Lyte.app`, and `swift package clean` would delete it while it
runs.

Which suites to run after a change: Wire → all packages; Common → Host,
Client, SystemTests, Browser; Host → SystemTests, Browser; Client →
SystemTests, Browser.

Iterate with `--filter <TestClass>`. Environment knobs read by the suites:

| Variable | Effect |
|---|---|
| `LYTE_ARQ_TRIALS` | Seeded ARQ simulation trials (default 2,000; `25000` or more for the long form) |
| `LYTE_ARQ_SEED` | Replay one ARQ simulation seed |
| `LYTE_HARDWARE_TESTS=1` | Run tests that use real machine hardware (today: the audio route-change test, which plays through the real output device); skipped otherwise |

### Test equipment

Gate tests drive the real engines through shared kits instead of per-file
fakes:

| Kit | Target | Use |
|---|---|---|
| `SealedCtrlPeer` | `LyteWireTestKit` | A role-agnostic sealed far end: handshake, per-channel seqs, ARQ, capability declaration, retry answers |
| `HostSessionHarness`, `PeerBackedClient` | `HostWireTestKit` (test-only target) | A shipping `HostWire.Session` with an outbox and virtual time |
| `ScriptedHost`, `ClientCoreHarness`, `ManualMicrosClock` | `LyteClientTestKit` | The real `LyteUdpSessionCore` without a socket, against a scripted host |
| `SimNet`, `SplitMix64` | `LyteWireTestKit` | Deterministic impairment; 64-bit seeded draws identical on every platform |

### What the suites contain

| Package | Test targets |
|---|---|
| Common | `LyteCoreTests` (with the single-owner ratchets), `LyteIOTests`, `LyteTestKitTests` (the sans-IO lint), `COpusTests` |
| Wire | `LyteWireTests` — codecs, vector files, `VectorRegenerationTests`, ARQ/FEC/Noise/pairing simulations |
| Host | `HostCoreTests`, `HostSessionTests`, `HostWireTests` (session gates), `HostAudioTests`, `HostLayoutTests`; Linux only: `HostEyeTests`, `CNetIOTests`, `LyteHostIntegrationTests` |
| Client | `LyteTransportTests`, `LyteClientSessionTests`, `LyteClientCoreTests`, `LyteCorpusTests` (slow corpus legs), `LyteAppTests` (app lifecycle under injected services), `LyteHelperTests` |
| SystemTests | `LyteClientHostTests` — real client and host composed in one process |
| Browser | `LyteClientBrowserCoreTests` — the browser core against an in-process `HostWire.Session` |

### Repository lints (run inside the Common suite)

- `SansIOArchitectureTests`: import allowlists for every sans-IO target
  (`LyteCore`, `LyteClientCore`, `LyteClientSession`, `LyteWire`,
  `HostCore`, `HostSession`, `HostWire`), `Crypto` confined to
  `LyteWire/Crypto/`, `CNanorsWire` confined to `Fec/NanorsBackend.swift`,
  and a forbidden-token scan (Foundation IO, locks, threads, OS clocks,
  system randomness).
- Single-owner ratchets (`LyteCoreTests/*RatchetTests`): one
  implementation of each shared concept (Annex-B, hex, SHA-256, histogram,
  Wire TOS, renderer handoff, video sink, screen source, …) across all
  production sources, Browser included.
- Layout tests (`HostLayoutTests`, `ClientLayoutTests`,
  `SystemTestsLayoutTests`) check the `Sources/<Target>` /
  `Tests/<Target>Tests` grammar and role boundaries, not file lists.

## The macOS gate — `Scripts/CI/test-all-macos.sh`

In order:

1. **Frozen vectors.** Fails when any file under `Wire/Vectors/` other than
   `README.md` is modified, deleted, renamed or retyped relative to
   `LYTE_GATE_BASE_SHA` (default: merge base with `origin/main`). New files
   are allowed. `LYTE_ALLOW_VECTOR_CHANGES=1` overrides, deliberately.
2. **Package tests** for Common, Wire, Host, Client, SystemTests and
   Browser, as above.
3. **WebAssembly legs** when the pinned toolchain is installed:
   `Browser/Scripts/build.sh`, then `Wire/Scripts/wasm-test.sh` when
   `wasmtime` is present. Otherwise the gate prints `SKIPPED` and
   continues.
4. **Script tests:** `test-benchmark-safety.sh`,
   `test-host-release-posture.sh`, `test-host-package-image.sh --self-test`,
   `test-host-installer.sh --self-test` (which also runs
   `test-host-deploy.sh`), `test-sign-dev.sh`.
5. **Python:** `test_analyze_app_benchmark.py`, `test_motion_preflight.py`,
   then `test-app-identity.sh`.
6. **Signed debug CLI:** `Scripts/build-cli.sh debug`,
   `codesign --verify --strict`, `test-hermetic-linkage.sh`.
7. **Signed release app** into a temporary `.build/.lyte-ci-app.*`
   destination, assembled twice (the bundle version must increase), then
   `test-app-packaging.sh`, `codesign --verify --strict` on the app, the
   app binary and `lyte-helperd`, and `test-hermetic-linkage.sh`. The
   owner's `.build/Lyte.app` is never touched.

## The pup gate — `Scripts/CI/test-all-pup.sh`

Mirrors Browser, Client, Common, Wire, Host and SystemTests to
`~/src/lyte-gates/deterministic/` on `LYTE_PUP_HOST` (default `pup`) under a
lock, then:

1. Fingerprints protected state: `~/.config/lyte/{noise_static.key,
   paired_clients,host.conf}` (required), the pre-XDG copies when present,
   `/etc/systemd/system/lyte-host.service`, and the `~/.local/bin/lyte-host`
   link target.
2. Package tests (`swift test -Xswiftc -warnings-as-errors`) for Common,
   Wire and Host; `swift build --target LyteClientCore` and
   `--target LyteClientSession` for Client.
3. Plain and release Host builds with `-warnings-as-errors`.
4. Stages a host image and runs `test-host-package-image.sh`,
   `test-host-installer.sh IMAGE` and `--self-test`, and
   `test-hermetic-linkage.sh`.
5. Checks `lyte-host` links no libav/libsw* library and carries the pinned
   Opus encoder.
6. Runs `lyte-netio-check` and `lyte-pace-check`.
7. Verifies the protected-state fingerprint is unchanged.

The pup gate never deploys or restarts the standing service. Browser is
mirrored and hashed but not built on pup: its JavaScriptKit dependency
needs Swift 6.2 or later.

## WebAssembly

```sh
Wire/Scripts/wasm-test.sh     # the whole Wire suite on wasm32-unknown-wasip1 under wasmtime
Browser/Scripts/build.sh      # LyteClientBrowser.wasm + page staged in Browser/.serve/
```

Without binaryen's `wasm-opt` the staged module is about 77 MB and behaves
the same.

## Browser smoke — `Browser/Scripts/smoke-chrome.sh`

Not part of either gate. It always rebuilds, starts `lyte-control-peer
--emit-corpus` on a fresh loopback port (never 41151) behind
`lyte-wt-sidecar --udp-peer`, and drives headless Chrome through the
session proof. It passes when every line below is present (each PASS line continues with
its measurements):

```text
PASS  envelope-v1/nominal-video-shard
PASS  noise-v1/snow-ik-25519-chachapoly-sha256
PASS  control-session/noise-pair-caps
PASS  control-session/clipboard-cap
PASS  control-session/teardown
PASS  frame-present/classify
PASS  frame-present/webcodecs
PASS  frame-present/webgpu
PASS  conductor-video/assemble
PASS  conductor-video/schedule
PASS  conductor-video/present
PASS  session-input/echo
PASS  clipboard/text-roundtrip
PASS  audio/depacketize
PASS  audio/webcodecs
PASS  audio-worklet/ring
PASS  interaction-shell/b6
```

The video legs are paced: the page runs one loop (ingest, decode,
present) and presents each frame on the Conductor's clock.
`conductor-video/schedule` asserts that presented PTS sit on the beat grid
and that no frame was shown before its PTS; `conductor-video/present`
asserts at least five frames presented and at least three decoded ahead of
their beat and held until it. The log also prints a `sink={…}` counter
line and a `pacing` line (per frame: ms decoded and presented relative to
its PTS). Frame 0 always presents about 20–45 ms late (it anchors the score
with a one-beat cushion), and frame 1 is sometimes skipped as late; both are
the Conductor's laws working, not failures.

The WebTransport carrier echo proofs (`wt-carrier/*`) are skipped in peer
mode. Environment: `LYTE_WT_RUNTIME` (`node`|`bun`), `LYTE_CHROME`,
`LYTE_CONTROL_PEER_PORT`, `LYTE_BROWSER_SMOKE_TIMEOUT_S`,
`LYTE_BROWSER_CONFIGURATION`. What the smoke does and does not prove is in
[BROWSER.md](BROWSER.md).

## Live benchmarks (pup)

These touch the owner's rig. Run them only when the owner allows a live
run, and read the safety rules in [OPERATIONS.md](OPERATIONS.md#safety)
first.

`Scripts/benchmark-app.sh [--no-build] [--seconds N] [--out DIR]
static|motion|quality-static|handshake-only|all` builds and launches the
real `Lyte.app` against the standing host, drives
`Scripts/motion-presenter.py` on pup's glass for motion legs, and judges the
run with `Scripts/analyze-app-benchmark.py`. `all` runs each leg in its own
process. It takes the app-artifact lock and refuses to run while the
owner's interactive app is open.

`Scripts/benchmark-netem.sh moderate` shapes one host→client flow with
`Scripts/netem/port-netem.sh` (20 ms delay, 10 ms jitter, 1 % loss) around
one motion leg and judges the impairment SLOs. See
[`Scripts/netem/README.md`](../Scripts/netem/README.md).

| Variable | Used by | Meaning |
|---|---|---|
| `LYTE_PUP_HOST` | both, pup gate | ssh host (default `pup`); `PUP` and `LYTE_BENCHMARK_PUP` are refused |
| `LYTE_BENCHMARK_HOST` | both | address the app dials (default `10.0.0.232`, the wired leg; use `10.0.0.249` while pup is on Wi-Fi only) |
| `LYTE_BENCHMARK_PORT` | both | UDP port `lyte-host.service` must own (app default 41151; netem requires it) |
| `LYTE_BENCHMARK_ALLOW_STANDING_PORT` | netem | `1` to impair the standing 41151 flow |
| `LYTE_BENCHMARK_SECONDS` | app | leg length (default 30) |
| `LYTE_BENCHMARK_OUT_DIR` | both | evidence root (default `.build/benchmarks`) |
| `LYTE_BENCHMARK_QUALITY_PROBE` | app | GPU-readback quality witness (default 1) |
| `LYTE_BENCHMARK_FREEZE_FRAME_ID` | app | frame held for `quality-static` (default 900) |
| `LYTE_BENCHMARK_CHROMA_TIER` | app | chroma tier the app requests |
| `LYTE_ENABLE_PIPELINE_WITNESS` | app | client per-frame JSONL witness |

## Adding a test

- Reproduce a bug with a test that fails before the fix.
- Test behavior. Do not pin source spellings, private member names or
  file lists; see [AGENTS.md](../AGENTS.md#change-discipline).
- New wire bytes need a new vector file (or new cases appended in a new
  file) plus a builder in `LyteWireVectorGen`.
