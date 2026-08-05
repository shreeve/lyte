# Lyte — session handoff

*Current as of 2026-08-04. This is the live resume point, not a history log.*

## Resume here

- **Branch:** resume from `main`; the Apple Development signing slice follows
  the Local Network recovery landed in #166.
- **GitHub:** no open pull requests.
- **Workspace:** one clean checkout and no auxiliary worktrees.
- **Current objective:** replace the Homebrew libopus runtime dependency with a
  pinned hermetic leaf.

## Last green gates

The #166 baseline passed the complete deterministic macOS gate: all five Swift
packages, benchmark safety, analyzer tests, signed CLI, and signed app. It also
passed the complete pup gate: Common, Wire, Host, plain `swift build`, kernel
socket checks, and pacing checks. Pup's protected identity state was unchanged.

Focused Local Network coverage passed 9 policy tests and 8 discovery tests.
The client now distinguishes a definitive policy denial from an ambiguous
route-or-permission failure, preflights direct autoconnect, offers the supported
System Settings recovery path, and rescans after the owner returns.

The pending signing slice passed its isolated executable signer test. It covers
automatic and explicit Apple Development selection, duplicate and ambiguous
identities, SHA-1 overrides, self-signed fallback, absent or invalid identities,
app and CLI identifiers, team consistency, and malformed designated
requirements. Two consecutive release rebuilds retained identical authority,
team, and designated requirements for the app and helper; strict deep signing
verification and both Mach-O UUID checks passed.

The final complete macOS gate passed all five packages, benchmark safety, 25
analyzer tests, signing-policy tests, signed CLI, and enhanced signed-app
packaging checks. The complete pup gate passed Common 84, Wire 513, Host 339,
the plain build, and both kernel harnesses with protected identity state
unchanged.

## Current live rig

### Client

- `.build/Lyte.app` is running from the intended bundle path.
- It is signed by `Apple Development: Steve Shreeve (8FHNN4RZ9Q)` with team
  identifier `SD6N7Z8P9P` and bundle identifier `dev.shreeve.lyte`.
- macOS is showing the one-time Keychain prompt for `Lyte Client Noise
  Identity`. The owner must choose whether to grant it; automation must not
  enter the password or click a security decision.
- Live LaunchServices proof is incomplete until that prompt is resolved and
  the ordinary app sustains a stream for at least 30 seconds.
- Do not launch a benchmark or second ordinary Lyte app while this process is
  open; both use the same bundle identity.

### Host

- `pup` is wired at `10.0.0.232`; Wi-Fi backup is `10.0.0.249`.
- The standing `lyte-host.service` owns UDP 41151 and is active. Its configured
  120-second no-client-handshake timeout can trigger the existing systemd
  restart policy; that event is not evidence of a host crash.
- Unit binary: `~/src/lyte-host/.build/debug/lyte-host`.
- Session log: `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Commissioning findings still open

1. The release app links Homebrew's
   `/opt/homebrew/opt/opus/lib/libopus.0.dylib`; replace it with a pinned,
   hermetic shared leaf and prove the bundle has no Homebrew runtime path.
2. Resolve the `VideoReadbackTap` Swift concurrency/pointer warnings, the
   unnecessary mutable test variables, and Linux `String(cString:)`
   deprecations; then add a warning ratchet.
3. Run the owner-visible two-column stats-ledger check after live streaming is
   restored. GNOME Shell's known ten-second source-stall comb on pup remains an
   environment limitation, not a Lyte host-loop defect.

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
