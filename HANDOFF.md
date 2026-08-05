# Lyte — session handoff

*Current as of 2026-08-04. This is the live resume point, not a history log.*

## Resume here

- **Branch:** resume on `main` after the current landing; do not continue on
  the merged feature branch.
- **GitHub:** PR #169 is the local-network identity landing, based on #168.
- **Workspace:** one checkout and no auxiliary worktrees.
- **Current objective:** reboot macOS to clear its confirmed stuck Local Network
  privacy state, publish the landed app while Lyte is stopped, launch it through
  `Scripts/launch-app.sh`, and verify discovery plus sustained streaming.

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
syntax are clean. The known `VideoReadbackTap` warnings remain queued below.

## Current live rig

### Client

- `.build/Lyte.app` is not currently running.
- It is signed by `Apple Development: Steve Shreeve (8FHNN4RZ9Q)` with team
  identifier `SD6N7Z8P9P` and bundle identifier `dev.shreeve.lyte`.
- The current candidate bundle is source `33ed995f62e7+`, build `1785898737`;
  its packaging, hermetic-linkage, and strict deep-signature checks pass.
- LaunchServices resolves the exact candidate path, build version, signing
  identity, and Mach-O UUID. Bonjour discovers pup and its UDP 41151 endpoint,
  but macOS 26.6 marks every resolved child path `Local network prohibited`
  even while Lyte's Local Network switch is enabled. Apple DTS reproduces this
  enabled-but-denied state as an OS bug (FB21858319/FB21858436). No system-wide
  CIDR privacy exception has been installed.
- Next live step: reboot macOS to clear the stuck in-memory privacy state, leave
  Lyte enabled, rebuild while the app is stopped, launch through
  `Scripts/launch-app.sh`, and verify discovery/streaming. A normal permission
  toggle or code change does not inherently require a reboot; this restart is
  recovery for the confirmed OS-state mismatch.
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

1. Resolve the `VideoReadbackTap` Swift concurrency/pointer warnings, the
   unnecessary mutable test variables, and Linux `String(cString:)`
   deprecations; then add a warning ratchet.
2. Reconcile the playout setting and `docs/CUSHION.md` with the Conductor's
   actual one-beat minimum, then pin the settings-to-config mapping.
3. Authenticate every privileged `lyte-helperd` XPC client with an exact code
   signing requirement; pin signed-client acceptance and foreign rejection.
4. Run the owner-visible two-column stats-ledger check during a sustained live
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
