# Lyte — session handoff

*Current as of 2026-08-05. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** clean `main` through PR #188. There are no auxiliary worktrees,
  other local or remote branches, or open pull requests.
- **Current objective:** make the Noise-only host ratchet scan the complete
  shipping executable target, then repeat WASM and owner-visible live-rig
  commissioning.
- **Recent landings:** PR #186 made shipping transport Noise-only and removed
  513 net lines; PR #187 made `HostApplication` the native Swift `@main` entry;
  PR #188 aligned every living architecture document with those landings and
  the automatic Conductor. Frozen dated records and vectors did not change.

## Last green gates

The exact PR #188 commit passed the complete warning-enforced macOS gate:
Common 93, Wire 513, Host 345, Client 301, and SystemTests 17. Benchmark and
host-release safety, signing policy, 25 analyzer tests, app identity, the
signed CLI, hermetic linkage, packaging, and double signed release-app
assembly all passed.

The same commit passed pup's deterministic gate: Common 94, Wire 513, and Host
346; warning-enforced debug and release builds; hermetic linkage; pinned Opus
symbol proof; socket/TOS and pacing harnesses; and protected-state
verification. The gate did not deploy or restart the standing service.

Focused architecture proof on the composed main branch passes all three host
composition/security laws: one native `@main` doorway, injected argument
composition, and no plaintext selector in the named host seams. The next slice
widens that last scan to every Swift file in `Host/Sources/lyte-host`.

## Current live rig

### Client

- `.build/Lyte.app` PID 64483 is running and responsive. Do not launch a
  benchmark or second ordinary Lyte app while it is open; both use the same
  bundle identity.
- Bundle identifier `dev.shreeve.lyte`, team `SD6N7Z8P9P`, signed by
  `Apple Development: Steve Shreeve (8FHNN4RZ9Q)`, build `1785919825`.
- Lyte executable SHA-256:
  `aa5b63f5acfbc30e559e5c398d047b3db7e9a1a517a71397a0dbf4267b59d48f`.
  Helper SHA-256:
  `eae3cff51bbe689f4e82e755edc49ef9b2d5c320286bd452dd33148a92e1fe2e`.
- The beachball was resolved in PR #181: the old gate removed the live bundle
  while the process was running, then helper registration crashed inside
  bundle plist loading. Client tests now use `Client/.build`, gates assemble
  isolated apps, stream start does not own helper registration, and missing
  registration fails soft.
- macOS Local Network privacy remained path-prohibited even while its
  preference layer logged Lyte as allowed (Apple FB21858319/FB21858436). At the
  owner's direction, the documented Wi-Fi exception `10.0.0.0/24` is installed
  in `com.apple.network.local-network`. After reboot, the exact signed app
  connected to pup. This deliberately bypasses Local Network privacy for every
  app contacting that trusted Wi-Fi `/24`.

### Host

- `pup` is wired at `10.0.0.232`; Wi-Fi backup is `10.0.0.249`.
- `lyte-host.service` is active on UDP 41151. Its configured 120-second
  no-client-handshake timeout can exercise systemd restart policy; a changing
  PID alone is not a host crash.
- Deployed release binary: `~/src/lyte-host/.build/release/lyte-host`, SHA-256
  `9eb92ad911225e84d7c4dd0e0a40a04af15a33a39102f25933045d11bacb03e3`.
- Session log: `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Latest owner-visible evidence

Lyte connected to pup with video, audio, keyboard, and mouse. The automatic
Conductor decomposed observed delay into measured path plus whole-beat reserve,
grew after genuine holes, and returned through proof-driven clean beats. The
user warning now counts only terminal renderer misses/failures; disturbances
that the reserve successfully absorbs remain diagnostic evidence and do not
raise a warning pill. No manual cushion setting is present or scheduled.

## Next commissioning order

1. Land the executable-wide Noise-only host ratchet as its own PR.
2. Run the Wire WASM suite on the landed tree.
3. Build/deploy a clean release host on pup without altering identity state,
   build/launch the exact signed Mac app, and repeat the owner-visible stream
   proof.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
