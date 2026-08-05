# Lyte — session handoff

*Current as of 2026-08-04. This is the live resume point, not a history log.*

## Resume here

- **Branch:** resume on clean `main` after the #174 landing; do not continue on
  its merged feature branch.
- **GitHub:** PR #174 is landing exact helper-client authentication with full
  signed acceptance, foreign rejection, Mac, pup, and live proof.
- **Workspace:** one checkout and no auxiliary worktrees.
- **Current objective:** run the sustained owner-visible stats-ledger
  investigation and fix only defects supported by its attribution evidence.

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

## Current live rig

### Client

- `.build/Lyte.app` (PID 96213) is running and connected to pup. The previous app's
  beachball was a main-thread `StatsOverlay` feedback loop: its `TimelineView`
  repeatedly invoked `ConnectionModel.statsRows()` and percentile sorting from
  SwiftUI layout while media queues kept playing. The repaired overlay renders
  cached rows and refreshes them from one cancellable one-second task. The live
  proof is recorded under the focused gate above.
- It is signed by `Apple Development: Steve Shreeve (8FHNN4RZ9Q)` with team
  identifier `SD6N7Z8P9P` and bundle identifier `dev.shreeve.lyte`.
- The current candidate bundle is source `34026759f9f3+`, build `1785908343`.
  Its Lyte and helper executable SHA-256 values are respectively
  `b859dff80bdf42c9240bbbb302599c2307ebaef6ba001998d84b32dd4dbcd15c`
  and `7d9ac31cc84ea845bfb214c6e51bf56cb73f6dd619adbbe800f7923ab828648f`.
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

## Commissioning findings still open

1. Run the owner-visible two-column stats-ledger check during a sustained live
   stream and investigate the reported stalls. The first owner snapshot saw 6
   delays (63 ms worst) while loss was 12/184.3k (0.007%), delivery p99 was
   1.8 ms, jitter 6.0 ms, RTT 6.7 ms, source/ready p99 33.6/35.7 ms, cadence
   56/56 fps, renderer drops 9, and the automatic cue had grown to 73 ms. This
   points away from network delivery and toward pup's known GNOME Shell
   ten-second source-cadence comb and/or client rendering; prove attribution in
   the sustained run before changing code.

## Architecture train after commissioning

Keep every landing small and green. The intended order is:

1. Strengthen one sans-IO/dependency ratchet before creating more targets.
2. Extract pure `LyteClientCore` policy one organ at a time, starting with
   roaming policy.
3. Extract the client session vertical without moving platform IO.
4. Replace `COpusEncode` with the pinned `COpus` Swift-facing leaf and delete
   the duplicate C codec-policy wrapper.
5. Extract pure host session policy behind injected time and randomness.
6. Make application composition roots explicit.
7. Remove executable insecure/plaintext production paths while preserving
   test-only frozen-vector equipment.
8. Finish documentation and architectural ratchets, then repeat clean macOS,
   pup, WASM, and live-rig commissioning.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
