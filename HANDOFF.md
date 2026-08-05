# Lyte — session handoff

*Current as of 2026-08-05. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** `fix/direct-eye-same-fb-damage` from clean `main` through PR #198.
  There is one checkout, no auxiliary worktree, and no open pull request yet.
- **Current objective:** land the Direct Eye correction that observes pixels
  at 60 Hz, treats KMS framebuffer identity only as an import-cache key, and
  encodes only actual changes. Then resume the IO-free client-control sequence
  with clipboard followed by cursor.
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
  and event delivery; PR #197 composed both organs behind one
  `ClientControlSession`, made capability-failure teardown one cross-organ value
  decision, and reduced the macOS transport by another 19 lines; PR #198 moved
  host-audio negotiation gates, confirmed posture, one-time startup
  reconciliation, malformed-status handling, role-confusion judgment, and
  outbound request bytes into one IO-free `ClientAudioRoutingSession`, leaving
  macOS transport to synchronize counters, execute sends, and project events.
  This branch corrects the Direct Eye's false damage premise, replaces FB-flip
  gating with a compact full-screen GPU fingerprint, and retires the obsolete
  flip-gap ledger. Frozen wire vectors did not change.

## Last green gates

The exact current source passed the complete warning-enforced macOS gate:
Common 93, Wire 513, Host 340, Client 329, and SystemTests 17. Benchmark and
host-release safety, signing policy, 25 analyzer tests, app identity, the
signed CLI, hermetic linkage, packaging, and double signed release-app
assembly all passed. The isolated host-image lifecycle also passed.

The same source passed pup's deterministic gate: Common 94, Wire 513, and Host
341; warning-enforced portable-client builds; warning-enforced host debug and
release builds; hermetic linkage; pinned Opus proof; the release image and
installer lifecycle; kernel socket/TOS and pacing harnesses; and protected-state
verification. A standalone six-second GPU run made 360 observations with zero
skipped beats and zero missed grabs; fingerprint readback averaged 1.69 ms.

Focused architecture proof on the composed main branch passes all three host
composition/security laws: one native `@main` doorway, injected argument
composition, and an executable-wide Noise-only scan over all 12 shipping host
Swift files. Wire's full WebAssembly leg also passed 511 tests under wasmtime
47.0.2 on `wasm32-unknown-wasip1` with zero failures.

## Current live rig

### Client

- `.build/Lyte.app` PID 60433 is running and connected to pup. Do not launch a
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

- `pup` is currently on Wi-Fi at `10.0.0.249`; wired address `10.0.0.232` is
  unplugged. The active advertisement interface is `wlp0s20f3`.
- `lyte-host.service` PID 90865 is active on UDP 41151. Its configured 120-second
  no-client-handshake timeout can exercise systemd restart policy; a changing
  PID alone is not a host crash.
- Deployed release binary: `~/src/lyte-host/.build/release/lyte-host`, SHA-256
  `d6dc2db577045477d6f458fe428f0ceadab6dba35d1b3f25fe720bc35b93b33b`.
- Session log: `/tmp/lyte-host-session.log`.
- A pre-session process can ignore SIGTERM while blocked in handshake receive;
  this commissioning restart required a scoped systemd SIGKILL. The service
  immediately restarted under PID 90865; the product fix is filed in `TODO.md`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Latest owner-visible evidence

The deployed corrected host and exact signed app completed Noise and opened the
native VAAPI Direct Eye at 2048×1280 in Best 4:4:4. The first live run observed
17,171 screen beats, encoded only 1,369 changes, skipped one beat, and missed
zero grabs. The final cleaned build reconnected successfully; on pup's Wi-Fi
the estimator recovered from its opening loss dip to 27.6 Mbps and beacon RTT
settled near 10 ms. Normal 30 fps content no longer emits false 60 Hz capture-
skip diagnostics. The automatic Conductor remains the only presentation and
video-reserve owner.

## Next commissioning order

1. Land this Direct Eye correction through the PR train and record its commit.
2. Move clipboard control judgment behind `ClientControlSession`, preserving
   consent, capability, origin/echo, size, and role-confusion laws as typed
   IO-free decisions; then do the same for cursor control.
3. Keep the clean Mac/Linux/WASM/live commissioning baseline green, then add
   thin macOS/Linux/Windows/browser shells at that shared boundary.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
