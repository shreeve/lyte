# Lyte — session handoff

*Current as of 2026-08-05. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** clean `main` through PR #196. There are no auxiliary worktrees,
  other local or remote branches, or open pull requests.
- **Current objective:** compose lifecycle and capabilities behind one IO-free
  `ClientControlSession` façade, then move the remaining feature-control
  judgment behind that same platform-shell boundary.
- **Recent landings:** PR #186 made shipping transport Noise-only and removed
  513 net lines; PR #187 made `HostApplication` the native Swift `@main` entry;
  PR #188 aligned every living architecture document with those landings and
  the automatic Conductor; PR #189 made the Noise-only law scan every shipping
  host source; PR #190 made pup continuously compile the IO-free client policy
  with warnings as errors; PR #191 recorded the living browser direction and
  its WASM/WebTransport/WebCodecs/WebGPU commissioning boundary; PR #192 made
  the living design, comparison, and repository maps distinguish shipping
  behavior from future direction; PR #193 created the rootless Linux host image
  with stable paths, complete notices, an exact inventory, and a SHA-256
  manifest; PR #194 made installation consume only that verified image,
  retired `LYTE_HOST_BIN` and every installed checkout path, preserved operator
  configuration and identity, and made uninstall symmetric; PR #195 moved
  capability startup, intersection, update answers, and failure judgment into
  one IO-free client-session owner that builds unchanged on macOS, Linux, and
  WebAssembly; PR #196 moved mode-transition and session-teardown decoding into
  the lifecycle organ, leaving transport only synchronization, counters, sends,
  and event delivery. Frozen dated records and vectors did not change.

## Last green gates

The exact PR #196 source commit `bf713fe` passed the complete warning-enforced
macOS gate: Common 93, Wire 513, Host 345, Client 312, and SystemTests 17.
Benchmark and
host-release safety, signing policy, 25 analyzer tests, app identity, the
signed CLI, hermetic linkage, packaging, and double signed release-app
assembly all passed. The isolated host-image lifecycle also proved exact
inventory, permissions, stable service path, manifest and corruption rejection;
install/reinstall preservation; explicit service lifecycle; symmetric
uninstall/purge; and identity preservation.

The same commit passed pup's deterministic gate: Common 94, Wire 513, and Host
346; warning-enforced `LyteClientCore` and `LyteClientSession` Linux builds;
warning-enforced debug and release builds; hermetic linkage; pinned Opus symbol
proof; a real release host image plus packaged-binary linkage proof; the full
installer lifecycle in an isolated root; socket/TOS and pacing harnesses; and
protected-state verification. The gate did not deploy or restart the standing
service. The extracted `LyteClientSession` target also cross-built directly for
`wasm32-unknown-wasip1` with the pinned Swift 6.3.3 WebAssembly SDK.

Focused architecture proof on the composed main branch passes all three host
composition/security laws: one native `@main` doorway, injected argument
composition, and an executable-wide Noise-only scan over all 12 shipping host
Swift files. Wire's full WebAssembly leg also passed 511 tests under wasmtime
47.0.2 on `wasm32-unknown-wasip1` with zero failures.

## Current live rig

### Client

- `.build/Lyte.app` PID 86190 is running and connected to pup. Do not launch a
  benchmark or second ordinary Lyte app while it is open; both use the same
  bundle identity.
- Bundle identifier `dev.shreeve.lyte`, team `SD6N7Z8P9P`, signed by
  `Apple Development: Steve Shreeve (8FHNN4RZ9Q)`, build `1785923981`.
- Lyte executable SHA-256:
  `f21a45da5797b7eb57e86009a8db711ac21d78809dcca84a458f2dccc8ef3170`.
  Helper SHA-256:
  `f0c31df74085fa61ebc28b330cc61ebe44cd723c0ca44d3ea578048c66df5720`.
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
  `0e00b24f66124d63bf1a2b83dbff3c363b50c92d1869c37a1be7f6151d3abb07`.
- Session log: `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Latest owner-visible evidence

The clean PR #189 artifacts completed a Noise handshake and negotiated HEVC,
4:2:0, idle silence, host-audio routing, and a 1152-byte datagram ceiling. The
native VAAPI direct eye opened at 2048×1280; video/IDR, 5 ms Opus audio, cursor,
input, and beacon traffic were live, with recent beacon RTT converging around
6–10 ms. The automatic Conductor remains the only video-reserve owner. The user
warning counts only terminal renderer misses/failures; absorbed disturbances
stay diagnostic and silent.

## Next commissioning order

1. Extract the remaining concrete client-session orchestration into the
   IO-free `LyteClientSession` boundary.
2. Keep the clean Mac/Linux/WASM/live commissioning baseline green, then add
   thin macOS/Linux/Windows/browser shells at that shared boundary.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
