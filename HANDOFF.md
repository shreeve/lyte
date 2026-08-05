# Lyte — session handoff

*Current as of 2026-08-04. This is the live resume point, not a history log.*

## Resume here

- **Branch:** `cleanup/playout-setting-truth`, based directly on clean `main` at
  the #170 landing.
- **GitHub:** PR #171 is the stats-overlay beachball repair, based directly on
  the #170 landing.
- **Workspace:** one checkout and no auxiliary worktrees.
- **Current objective:** land PR #171 and return to clean `main`, then
  reconcile the playout setting and
  `docs/CUSHION.md` with the Conductor's one-beat minimum.

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

## Current live rig

### Client

- `.build/Lyte.app` is running and connected to pup. The previous app's
  beachball was a main-thread `StatsOverlay` feedback loop: its `TimelineView`
  repeatedly invoked `ConnectionModel.statsRows()` and percentile sorting from
  SwiftUI layout while media queues kept playing. The repaired overlay renders
  cached rows and refreshes them from one cancellable one-second task. The live
  proof is recorded under the focused gate above.
- It is signed by `Apple Development: Steve Shreeve (8FHNN4RZ9Q)` with team
  identifier `SD6N7Z8P9P` and bundle identifier `dev.shreeve.lyte`.
- The current candidate bundle is source `a16f93e0153b+`, build `1785904418`,
  with client-source hash
  `8147584f679bb83f98044fdb38b04c753d35d75c46e85ebc170bb8038fd47590`;
  its packaging, hermetic-linkage, and strict deep-signature checks pass.
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

1. Reconcile the playout setting and `docs/CUSHION.md` with the Conductor's
   actual one-beat minimum, then pin the settings-to-config mapping.
2. Authenticate every privileged `lyte-helperd` XPC client with an exact code
   signing requirement; pin signed-client acceptance and foreign rejection.
3. Run the owner-visible two-column stats-ledger check during a sustained live
   stream and investigate the reported network stalls. GNOME Shell's known
   ten-second source-stall comb on pup remains an environment limitation, not
   a Lyte host-loop defect.

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
