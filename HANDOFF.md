# Lyte — session handoff

*Current as of 2026-08-05. This is the live resume point, not a history log.*

## Resume here

- **Branch:** resume `agent/host-session-core` from its committed extraction
  after incorporating clean `main` through PR #181.
- **GitHub:** PR #181 prevents clean verification from deleting the owner's
  running app and makes a missing optional helper fail soft instead of entering
  the crashing `SMAppService.register()` path.
- **Workspace:** one checkout and no auxiliary worktrees.
- **Current objective:** extract pure host session policy behind injected time
  and randomness without moving sockets, queues, persistence, or Linux IO.

## Last green gates

The #168 hermetic Opus slice passed its focused macOS checks: Common's 86 tests,
the host release-posture ratchet, signed app assembly, exact third-party notice
hashes, deployment target checks, positive Opus and nanors symbol checks, and
the complete Mach-O dependency/RPATH allowlist. A separately downloaded
official Opus 1.6.1 archive matched all 240 pinned files byte-for-byte.

The complete pup gate passed Common 87, Wire 513, and Host 339 tests; the debug
and release builds; release host/audio linkage checks; positive Opus symbol
proof; and the netio and pacing harnesses. The release Opus leaf compiled with
`-O2`. Pup's protected identity state was unchanged.

The final local-network identity gate passed all five packages: Common 86,
Wire 513, Host 338, Client 283, and SystemTests 17. It also passed benchmark and
host-release safety, signing policy, 25 analyzer tests, app-identity policy,
the signed CLI, packaging, and hermetic linkage. The isolated release app was
assembled twice at one path; the second build advanced `CFBundleVersion` and
exercised the atomic bundle-swap path without touching `.build/Lyte.app`.
Focused discovery/access coverage is 24 tests. `git diff --check` and shell
syntax are clean.

The warning-zero gate passed macOS Common 86, Wire 513, Host 338, Client 284,
and SystemTests 17 with Swift warnings promoted to errors. Signing, analyzers,
the signed CLI, hermetic linkage, packaging, and double signed app assembly
also passed. Pup passed Common 87, Wire 513, and Host 339; warning-enforced
debug and release builds; hermetic linkage; socket and pacing harnesses; and
protected-state verification. Clean independent audits found no remaining
repo-source Swift warnings.

The stats-overlay repair passed warning-enforced macOS Common 86, Wire 513,
Host 338, Client 285, and SystemTests 17. Pup passed Common 87, Wire 513, Host
339, debug and release builds, hermetic linkage, socket and pacing harnesses,
and protected-state verification. The signed release app passed packaging and
hermetic linkage, connected to pup, and kept its main thread idle for 11,994 of
12,008 samples during a 15-second live trace with Session Stats visible. No
`TimelineView`, `statsRows`, or stats-overlay stack appeared; the menu remained
responsive through two stats toggles.

The automatic-Conductor cleanup passed macOS Common 86, Wire 513, Host 338,
Client 286, and SystemTests 17 plus benchmark safety, signing, app identity,
packaging, and hermetic linkage. Pup passed Common 87, Wire 513, and Host 339;
warning-enforced debug and release builds; hermetic linkage; socket and pacing
harnesses; and protected-state verification. The focused law proof pins a
one-beat shipping floor, hole-driven whole-beat growth, and proof-driven
whole-beat return. The signed release app connected to pup with video and audio
while its application menu correctly exposed no Settings item.

Exact helper-client authentication passed macOS Common 86, Wire 513, Host 338,
Client 291, and SystemTests 17 plus all safety, signing, identity, packaging,
and linkage checks. Pup passed Common 87, Wire 513, and Host 339 plus both
builds, linkage, harnesses, and protected-state verification. Four focused
requirement tests pin both supported signer forms and malformed fail-closed
behavior; packaging repeatedly proved the signed app is accepted while the
same-signed helper and `/bin/ls` are rejected. Live helper PID 98023 installed
the exact app DR before delegate activation, accepted app PID 96213, held AWDL
down, and emitted no Security performance diagnostic.

The truthful-flight-ledger slice passed macOS Common 87, Wire 513, Host 338,
Client 293, and SystemTests 17 plus benchmark safety, signing, analyzer,
packaging, hermetic-linkage, and double app-assembly checks. Pup passed Common
88, Wire 513, and Host 339 plus warning-enforced debug and release builds,
linkage, socket and pacing harnesses, and protected-state verification. The
focused laws separate total cue, measured path, and reserve; expire historical
renderer blame from the rolling window; and select the newest cue after the
six-second frame ring wraps.

The architecture-boundary ratchet passed macOS Common 92, Wire 513, Host 338,
Client 293, and SystemTests 17 plus benchmark safety, signing, 25 analyzers,
app identity, signed CLI, hermetic linkage, and double signed release-app
assembly. Pup passed Common 93, Wire 513, and Host 339 plus warning-enforced
debug and release builds, linkage, socket and pacing harnesses, and protected-
state verification. One reusable lexer now owns structural source scans;
registered pure targets fail closed on missing roots, outward imports, OS
clocks, synchronization, and IO vocabulary. Frozen vectors were unchanged.

The client-core roaming extraction passed macOS Common 92, Wire 513, Host
338, Client 294, and SystemTests 17 plus benchmark safety, signing, 25
analyzers, app identity, the signed CLI, hermetic linkage, and double signed
release-app assembly. Pup passed Common 93, Wire 513, and Host 339 plus
warning-enforced debug and release builds, linkage, socket and pacing
harnesses, and protected-state verification. `LyteClientCore` has no
dependencies or allowed imports; pure virtual-time roaming proof lives in
`LyteClientCoreTests`, while persistence, Network.framework, and real-session
resume proof remain at the transport edge. Frozen vectors were unchanged.

The client-session lifecycle extraction passed macOS Common 92, Wire 513,
Host 338, Client 299, and SystemTests 17 plus benchmark safety, signing, 25
analyzers, app identity, the signed CLI, hermetic linkage, and double signed
release-app assembly. Pup passed Common 93, Wire 513, and Host 339 plus
warning-enforced debug and release builds, linkage, socket and pacing
harnesses, and protected-state verification. The new `LyteClientSession`
target also built directly on Linux with warnings as errors. Receiver
lifecycle ownership, detector reconfiguration, and state/mode edge reporting
are now IO-free value policy; locks, clocks, timers, wire sends, callbacks,
media handling, and platform IO remain in `LyteTransport`. Frozen vectors were
unchanged.

The Swift host-audio extraction passed macOS Common 93, Wire 513, Host 340,
Client 299, and SystemTests 17 plus benchmark safety, signing, 25 analyzers,
app identity, the signed CLI, hermetic linkage, and double signed release-app
assembly. Pup passed Common 94, Wire 513, and Host 341 plus warning-enforced
debug and release builds, direct pinned-Opus symbol linkage, socket and pacing
harnesses, and protected-state verification. A two-second live pup audio run
produced 398 hard-CBR packets: exactly 200.0 packets/s, 80 bytes each, 5,000 us
between every graph-clock timestamp, and clean decode-back. `COpusEncode` is
deleted; `HostAudio` owns codec policy in Swift, while one policy-free inline C
bridge remains solely because Swift cannot import variadic functions. Frozen
vectors were unchanged.

The failure-only video-warning slice passed 14 focused warning-contract tests
and the complete warning-enforced macOS gate: Common 93, Wire 513, Host 340,
Client 297, and SystemTests 17 plus benchmark safety, signing, 25 analyzers,
app identity, the signed CLI, hermetic linkage, and double signed release-app
assembly. Pup passed Common 94, Wire 513, and Host 341 plus warning-enforced
debug and release builds, linkage, socket and pacing harnesses, and protected-
state verification. The user-facing meter now receives only final renderer-
handoff lateness and explicit renderer loss/failure; successfully absorbed
delivery disturbances remain in the flight recorder and do not raise a pill.
Frozen vectors were unchanged.

The live-app clean-safety fix passed the complete warning-enforced macOS gate:
Common 93, Wire 513, Host 340, Client 297, and SystemTests 17 plus benchmark
safety, signing, 25 analyzers, app identity, the signed CLI, packaging, and
hermetic linkage. The gate ran while Lyte PID 55056 was live; its bundle
version, executable SHA-256, and PID were identical before and after. The
captured crash was `EXC_BAD_ACCESS` in `_load_plist_from_bundle` after the old
gate erased `.build/Lyte.app` and stream start tried to register its now-
missing helper. Client tests now use `Client/.build`; stream start never owns
registration; `.notFound` fails soft. PR #181 landed the fix.

## Current live rig

### Client

- `.build/Lyte.app` (PID 77688) is running; helper PID 77929 is active. The previous app's
  beachball was a main-thread `StatsOverlay` feedback loop: its `TimelineView`
  repeatedly invoked `ConnectionModel.statsRows()` and percentile sorting from
  SwiftUI layout while media queues kept playing. The repaired overlay renders
  cached rows and refreshes them from one cancellable one-second task. The live
  proof is recorded under the focused gate above.
- It is signed by `Apple Development: Steve Shreeve (8FHNN4RZ9Q)` with team
  identifier `SD6N7Z8P9P` and bundle identifier `dev.shreeve.lyte`.
- The current candidate bundle is clean source `39638567a097`, build
  `1785918461`.
  Its Lyte and helper executable SHA-256 values are respectively
  `676c817ca64c5260daa704b2a6ea0152cffd5c43adfa9df6b520e43604976352`
  and `ca926cb3c27673b718f6d13db830a20e6bdd543bb0429cbfff20d22e033423b0`.
  Packaging, hermetic-linkage, and strict deep-signature checks pass.
- LaunchServices resolves the exact candidate path, build version, signing
  identity, and Mach-O UUID. After the completed reboot and an owner-controlled
  Lyte Local Network off/on cycle, the signed GUI still browses and resolves
  pup but Network.framework marks every IPv4 and IPv6 child path `Local network
  prohibited`. The signed CLI discovers `10.0.0.232:41151`, and route, ping,
  and direct UDP checks succeed. Apple DTS reproduces this enabled-but-denied
  state as an OS bug (FB21858319/FB21858436). A clean Lyte quit, fresh
  `nehelper` and explicitly kickstarted `nesessionmanager`, and exact-bundle
  relaunch reproduced the contradiction: the preference layer logged Lyte as
  allowed while every resolved path remained prohibited. No privacy database
  or undocumented plist edit was attempted. At the owner's direction, the
  Apple-documented Wi-Fi exception `10.0.0.0/24` is installed in
  `com.apple.network.local-network`. After the required reboot, the exact
  signed bundle connected to pup successfully and CoreMedia reported the video
  renderer ready for display; the fresh trace contained no `Local network
  prohibited` verdict. This exception deliberately bypasses Local Network
  privacy for every app contacting the owner's trusted Wi-Fi `/24`.
- Do not launch a benchmark or second ordinary Lyte app while this process is
  open; both use the same bundle identity.

### Host

- `pup` is wired at `10.0.0.232`; Wi-Fi backup is `10.0.0.249`.
- The standing `lyte-host.service` owns UDP 41151 and is active. Its configured
  120-second no-client-handshake timeout can trigger the existing systemd
  restart policy; that event is not evidence of a host crash.
- Unit binary: `~/src/lyte-host/.build/release/lyte-host`.
- The deployed release binary has SHA-256
  `9eb92ad911225e84d7c4dd0e0a40a04af15a33a39102f25933045d11bacb03e3`.
  The service's configured no-client timeout intentionally changes its PID;
  the current service remains active and listening on UDP 41151.
- The one-time debug-to-release service migration sustained the same PID for
  30 seconds with zero restarts. The previous config is recoverable at
  `/etc/lyte/lyte-host.conf.pre-release-opus-20260804`.
- Session log: `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Latest commissioning evidence

The sustained owner-visible run resolved the ledger ambiguity without changing
playout policy. A 63 ms cue decomposed into about 10 ms of current path and 53
ms of reserve. Four historical Apple renderer drops with zero recent drops no
longer blamed the renderer; the live verdict named pre-render delivery. Later
59 fps motion caught one genuinely recent Apple drop and an 8.1 ms enqueue p99,
and the verdict correctly changed to renderer dropped frames. A 104 ms episode
raised the automatic cue near 132 ms; clean active frames returned it through
107 ms in whole-beat steps. The exact landed app then reconnected with zero
loss over its first 35.1k host packets, one total/zero recent renderer drops,
and current pre-render attribution. The evidence supports the Conductor's
automatic response; no policy change was earned.

## Architecture train after commissioning

Keep every landing small and green. The remaining order is:

1. Extract pure host session policy behind injected time and randomness.
2. Make application composition roots explicit.
3. Remove executable insecure/plaintext production paths while preserving
   test-only frozen-vector equipment.
4. Finish documentation and architectural ratchets, then repeat clean macOS,
   pup, WASM, and live-rig commissioning.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
