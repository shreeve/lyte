# Lyte source layout and behavior-preserving migration

*Owner-approved ruling of record, 2026-08-03. This supersedes only the
directory and target-shape portions of
`20260730-115707-lyte-v2-rulings.md`. Its one-repo, always-green,
fix-before-spec, spec-before-code, and rebuild-only-earned-organs laws remain
in force.*

> **Extension (2026-08-07):** client platform identifiers gain **`Browser`**
> (`LyteClientBrowser`; later `LyteBrowserApp` under `Applications/`). Frozen
> in
> [`20260807-021425-browser-client-platform-slice.md`](20260807-021425-browser-client-platform-slice.md).
> Body below still names MacOS / Linux / Windows as authored.

## 1. Prime invariant

The migration changes ownership, names, paths, and dependency direction. It
does not change observable behavior.

On the far side, Lyte must retain the same:

- Lyte-UDP bytes and frozen vectors;
- HEVC parameter sets and decoded pixels;
- video cadence, quality floors, audio continuity, and input behavior;
- pairing identity, trust, preferences, and on-disk formats;
- CLI products, arguments, output, and exit status;
- app identity, signing behavior, helper contract, and artifact paths;
- Linux systemd service, operator configuration, and live-ops posture.

Mechanical moves and semantic consolidation are separate PRs. A move first
proves exact equivalence. A following PR may consolidate newly adjacent code
only with explicit parity pins and deletion of every displaced copy.

## 2. One filesystem grammar

Every SwiftPM package uses the same conventional shape:

```text
<Package>/
├── Package.swift
├── Sources/
│   ├── <ProductionTarget>/
│   ├── <ProductionTarget>TestKit/
│   └── C<Platform><Capability>/
└── Tests/
    ├── <ProductionTarget>Tests/
    └── <ProductionTarget>TestKitTests/
```

The names are not synonyms:

- `Sources/<Target>/` is compiled library or executable code, Swift or C.
- `Sources/<Target>TestKit/` is reusable Swift support imported by two or
  more test targets. Production binaries never link it.
- `Tests/<Target>Tests/` is the executable Swift test suite.
- `Tests/<Target>Tests/Fixtures/` holds fixtures private to that suite.
- `Scripts/Tests/` holds Python and shell test programs.
- `Wire/Vectors/` remains the exceptional frozen wire-contract store.

Top-level and organizational directories use UpperCamelCase. Swift files use
UpperCamelCase. C and Python files use snake_case. Shell executables use
kebab-case. Swift modules use the `Lyte` prefix; C modules use
`C<Platform><Capability>`. Platform identifiers are `MacOS`, `Linux`, and
`Windows`.

There are no `Utils`, `Helpers`, `Misc`, or `Shared` drawers. A concept gets
its own precise name or stays beside its owning subsystem.

## 3. Canonical top level

```text
Lyte/
├── Wire/
├── Common/
├── Client/
├── Host/
├── Applications/
├── SystemTests/
├── Scripts/
└── Docs/
```

`Applications` is separate because a platform product may compose the client
role, host role, or both. `SystemTests` is a SwiftPM package that drives the
real client and host libraries in one graph; its own reusable equipment lives
under `SystemTests/Sources/LyteSystemTestKit`, while its test cases live under
`SystemTests/Tests/LyteClientHostTests`.

The current lowercase `docs/` moves to `Docs/` only in a dedicated,
link-checked mechanical PR. Dated records remain frozen; living documents and
supersession banners carry path changes.

## 4. Package and target ownership

### Wire

`LyteWire` owns only the frozen Lyte-UDP contract: bytes, numeric vocabulary,
framing, crypto, control messages, media packetization, FEC, and bulk message
formats. It remains Foundation-free, sans-IO, and vector-pinned.

`LyteWireTestKit` owns reusable vector loaders and wire simulations. Actual
tests remain `LyteWireTests`.

Every Wire Swift target mirrors one subsystem grammar:

```text
<Target>/
├── Arq/
├── Audio/
├── Bulk/
├── Capabilities/
├── Clipboard/
├── Control/
├── Crypto/{Noise,Pairing,Retry}/
├── Fec/
├── Session/
├── Telemetry/
└── Video/
```

A target omits a domain only when it has no files in that domain. The shared
wire spine (`Envelope`, vocabulary, byte/error/budget/version primitives),
cross-domain TestKit primitives, executable entry point, and whole-target
architecture tests stay at their target roots rather than entering a vague
drawer. `LyteWireTestKit` and `LyteWireTests` additionally use `Simulation`.
`LyteWireVectorGen` is the UpperCamelCase authoring target; its executable
product remains `lyte-wire-vectorgen`. A layout test enforces the complete
grammar, exact root allowlists, and intentional omissions.

### Common

`LyteCore` owns pure behavior that has exactly the same semantics on both
ends: binary vocabularies, collections, digests, shared telemetry laws, and
injected port protocols. Pure does not automatically mean Common; role-only
policy stays with its role.

`LyteIO` owns concrete OS adapters only when both roles consume the same
implementation. It depends on LyteCore; LyteCore never depends on it. It is
allowed to stay intentionally small.

`LyteTestKit` owns repository-wide virtual time, SimNet, pure media fixtures,
and reusable harness vocabulary. Diagnostics that ship in a benchmark binary
are not TestKit.

### Client

`LyteClientCore` owns pure client-role policy. `LyteClientSession` owns the
IO-free initiator/session orchestration over LyteWire. The platform targets
`LyteClientMacOS`, `LyteClientLinux`, and `LyteClientWindows` implement their
ports. `LyteClientDiagnostics` owns production-linked benchmark/readback
instrumentation; `LyteClientTestKit` owns test-only client equipment.

### Host

`HostCore` owns pure host-role policy. `HostSession` owns the IO-free
responder/session orchestration over LyteWire. The platform targets
`LyteHostMacOS`, `LyteHostLinux`, and `LyteHostWindows` implement their ports.
Hardware and OS C leaves remain targets under `Host/Sources` and use the
`C<Platform><Capability>` grammar.

### Applications

`LyteMacOSApp`, `LyteLinuxApp`, and `LyteWindowsApp` are composition roots.
They select the matching client and host platform targets and contain only
construction, lifecycle, settings, commands, and UI. `LyteCLI` and helper
products live here without pulling policy out of the role modules.

## 5. Dependency law

Dependencies point inward:

```text
Applications
    ↓
platform adapters (MacOS / Linux / Windows)
    ↓
ClientSession / HostSession
    ↓
ClientCore / HostCore
    ↓
LyteWire + LyteCore
```

`LyteIO` implements shared LyteCore ports at the platform edge. TestKit
targets may import production targets; no production target imports a
TestKit.

The following targets are lint-enforced IO-free:

- LyteCore
- LyteWire
- LyteClientCore
- LyteClientSession
- LyteHostCore
- LyteHostSession

They do not import Foundation, Dispatch, Network, UI/media frameworks,
Glibc, WinSDK, or hardware leaves. They do not open sockets or files, read a
system clock, create locks or threads, or invoke hardware. Time, randomness,
datagrams, stores, encoded media, and decoded events enter through values or
injected ports.

## 6. Boundary admission rule

Place each file by asking, in order:

1. Does it define contract bytes or frozen numeric vocabulary? LyteWire.
2. Is it pure with identical semantics on both roles? LyteCore.
3. Is it reusable test-only support? The narrowest applicable TestKit.
4. Is it pure but role-specific? ClientCore or HostCore.
5. Does it orchestrate initiator/responder session state? The role Session.
6. Is it a concrete adapter? The matching role and platform target.
7. Does it only construct and run a product? Applications.

A new target must enforce a real dependency, platform, linkage, replaceable
organ, or production/test boundary. Otherwise, use a subsystem directory
inside an existing target.

## 7. Green migration protocol

The migration proceeds through focused PRs:

1. Establish deterministic Mac and pup gates.
2. Normalize Common to `Sources/LyteCore`, `Sources/LyteIO`, and eventually
   `Sources/LyteTestKit`; repair and consolidate every cross-tree ratchet.
3. Organize Wire internally without changing its module or vectors.
4. Move the root client package to Client while preserving root `.build`
   artifact paths through explicit SwiftPM package/scratch paths.
5. Establish SystemTests before extracting shared session rituals.
6. Extract ClientCore, ClientSession, and platform adapters one cohesive
   organ at a time.
7. Extract HostSession and platform adapters while preserving HostCore laws.
8. Move product composition into Applications.
9. Add Linux, Windows, and MacOS role targets only with their first real
   adapter and platform gate; no empty scaffolding targets.
10. Move `docs/` to `Docs/` last, with every live link and script path checked.

At every step:

- all applicable Mac and Linux suites pass;
- frozen vectors remain byte-identical;
- source/path ratchets assert that expected scan roots exist and contain
  production Swift files;
- product names, signatures, bundle identifiers, artifact locations, help
  text, persistence, and wire formats remain unchanged;
- a platform-sensitive move earns its specific hardware/live gate.

The final gate runs both Good 4:2:0 and Best 4:4:4 Beauty Bar legs, plus
video/audio/input/clipboard/file/lifecycle smoke, against byte-identical
protected state.

## 8. Pre-migration safety repairs

The architecture audit found four false or stale safety surfaces. All four
are now repaired and ratchet-pinned:

1. **Resolved in the Common normalization:** every cross-tree ratchet now uses
   one `LyteTestKit` source-tree model that rejects missing, empty, or
   unreadable production roots.
2. **Resolved in the Common normalization:** client and host provenance now
   includes Wire and tracked SwiftPM resolution, while the package gates
   invalidate stale build state from one complete manifest-graph hash.
3. `benchmark-app.sh handshake-only` restarts the authoritative systemd unit,
   requires a new `MainPID` that owns UDP 41151 and matches the built binary,
   and brackets the run with protected identity/configuration fingerprints.
   It never supervises or kills the host process directly.
4. `benchmark-netem.sh` runs the current motion leg in a unique evidence
   directory. A distinctively-owned prio/u32 topology preserves `fq_codel`
   for unmatched traffic and diverts only UDP source port 41151 toward the
   benchmark client's exact IPv4 address into netem; cleanup verifies that
   the owned qdisc is gone.

The deterministic gate exercises the orchestration through fake-command
failure tests; hardware/netem operation remains explicitly invoked. Live
deployment uses systemd with ambient CAP_SYS_ADMIN; it does not apply setcap
to the standing service binary.
