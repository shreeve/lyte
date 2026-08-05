# Lyte — session handoff

*Current as of 2026-08-04. This is the live resume point, not a history log.*

## Resume here

- **Branch:** `commissioning/hermetic-opus`, based on `ddedf1c` (`main`, #167).
- **GitHub:** no open pull requests.
- **Workspace:** one clean checkout and no auxiliary worktrees.
- **Current objective:** land the hermetic Opus slice, then migrate pup's
  standing host from its existing debug binary to the release binary and
  verify the live rig without changing identity state.

## Last green gates

The #167 baseline passed the complete deterministic macOS and pup gates.

The hermetic Opus slice has passed its focused macOS checks: Common's 86 tests,
the host release-posture ratchet, signed app assembly, exact third-party notice
hashes, deployment target checks, positive Opus and nanors symbol checks, and
the complete Mach-O dependency/RPATH allowlist. A separately downloaded
official Opus 1.6.1 archive matched all 240 pinned files byte-for-byte.

The complete pup gate passed Common 87, Wire 513, and Host 339 tests; the debug
and release builds; release host/audio linkage checks; positive Opus symbol
proof; and the netio and pacing harnesses. The release Opus leaf compiled with
`-O2`. Pup's protected identity state was unchanged.

The final complete macOS gate passed all five packages, benchmark and host
release safety, signing policy, 25 analyzer tests, the signed CLI, and signed
app packaging. The app's hermetic linkage checks passed both before publication
and after the atomic bundle swap.

## Current live rig

### Client

- `.build/Lyte.app` is running from the intended bundle path as PID 38415.
- It is signed by `Apple Development: Steve Shreeve (8FHNN4RZ9Q)` with team
  identifier `SD6N7Z8P9P` and bundle identifier `dev.shreeve.lyte`.
- The owner confirmed that ordinary streaming works. The current visible
  commissioning issue is the existing network-stall ledger, not app launch or
  host discovery.
- Do not launch a benchmark or second ordinary Lyte app while this process is
  open; both use the same bundle identity.

### Host

- `pup` is wired at `10.0.0.232`; Wi-Fi backup is `10.0.0.249`.
- The standing `lyte-host.service` owns UDP 41151 and is active. Its configured
  120-second no-client-handshake timeout can trigger the existing systemd
  restart policy; that event is not evidence of a host crash.
- Unit binary: `~/src/lyte-host/.build/debug/lyte-host`.
- The repository now specifies `.build/release/lyte-host`; the live config has
  intentionally not been changed or restarted before the branch lands.
- Session log: `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Commissioning findings still open

1. Resolve the `VideoReadbackTap` Swift concurrency/pointer warnings, the
   unnecessary mutable test variables, and Linux `String(cString:)`
   deprecations; then add a warning ratchet.
2. Run the owner-visible two-column stats-ledger check during a sustained live
   stream and investigate the reported network stalls. GNOME Shell's known
   ten-second source-stall comb on pup remains an environment limitation, not
   a Lyte host-loop defect.
3. After this branch lands, perform the one-time live-host move to the release
   binary and prove service health, binary identity, and protected-state
   stability.

## Architecture train after commissioning

Keep every landing small and green. The intended order is:

1. Extract pure `LyteClientCore` policy with a sans-IO import lint.
2. Extract pure host session policy behind injected time and randomness.
3. Extract the client ingress/session vertical without moving platform IO.
4. Make application composition roots explicit.
5. Remove executable insecure/plaintext production paths while preserving
   test-only frozen-vector equipment.
6. Finish documentation and architectural ratchets, then repeat clean macOS,
   pup, WASM, and live-rig commissioning.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
