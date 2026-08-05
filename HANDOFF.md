# Lyte — session handoff

*Current as of 2026-08-05. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** clean `main` through PR #203. There is one checkout, no auxiliary
  worktree, no topic branch, and no open pull request.
- **Current objective:** commission the freshly published client against the
  exact PR #203 host, then measure the owner's Wi-Fi/lid-closed performance
  baseline before changing transport policy. The portable client-control
  boundary and prompt pre-session host shutdown are complete.
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
  PR #199 corrected the Direct Eye's false damage premise, replaced FB-flip
  gating with a compact full-screen GPU fingerprint, and retired the obsolete
  flip-gap ledger. PR #200 moved clipboard text and image consent, capability
  gates, direction judgment, echo suppression, bounded lane state, and wire
  encoding behind `ClientControlSession`; macOS now executes typed decisions.
  PR #201 moved cursor-shape decoding, malformed-input classification, and
  capability judgment behind the same portable session; AppKit now only
  projects accepted shapes. PR #202 moved audio-track and video-posture
  decoding, capability gates, and durable posture state behind that boundary;
  transport now only executes synchronized effects. PR #203 made the
  nonblocking Noise await loop observe the existing termination flag, return a
  typed cancellation, stop its sender thread, clean pre-session leaves, and
  exit zero. Frozen wire vectors did not change.

## Last green gates

The exact PR #203 source commit `2dda9d5` (landed as `40916a4`) passed the
complete warning-enforced macOS gate:
Common 93, Wire 513, Host 341, Client 347, and SystemTests 17. Benchmark and
host-release safety, signing policy, 25 analyzer tests, app identity, the
signed CLI, hermetic linkage, packaging, and double signed release-app
assembly all passed. The isolated host-image lifecycle also passed.

The same source passed pup's deterministic gate: Common 94, Wire 513, and Host
343; warning-enforced portable-client builds; warning-enforced host debug and
release builds; hermetic linkage; pinned Opus proof; the release image and
installer lifecycle; kernel socket/TOS and pacing harnesses; and protected-state
verification. A standalone six-second GPU run made 360 observations with zero
skipped beats and zero missed grabs; that retained PR #199 hardware evidence
averaged 1.69 ms per fingerprint observation and was not repeated for this
shutdown-only PR.

Focused PR #203 proof passed a real Linux ephemeral-socket integration in 3 ms.
An isolated unadvertised pup host on UDP 41983 received SIGTERM and exited zero
in 6 ms; all protected identity hashes remained byte-identical.

The composed `LyteClientSession` target also cross-built with warnings as
errors for `wasm32-unknown-wasip1` under the official Swift 6.3.3 WASI SDK.

Focused architecture proof on the composed main branch passes all three host
composition/security laws: one native `@main` doorway, injected argument
composition, and an executable-wide Noise-only scan over all 12 shipping host
Swift files. Wire's full WebAssembly leg also passed 511 tests under wasmtime
47.0.2 on `wasm32-unknown-wasip1` with zero failures.

## Current live rig

### Client

- `.build/Lyte.app` PID 21143 is running. It was freshly release-built, signed,
  published, and launched from product source revision `40916a4837ac`, bundle
  build `1785951699`. Pup is still awaiting a handshake, so do not describe it
  as a commissioned connection yet. Do not launch a benchmark or second
  ordinary Lyte app while it is open; both use the same bundle identity.
- Bundle identifier `dev.shreeve.lyte`, team `SD6N7Z8P9P`, signed by
  `Apple Development: Steve Shreeve (8FHNN4RZ9Q)`, build `1785951699`.
- Lyte executable SHA-256:
  `7056d09b8dd2a16cd91fba8363bea00d3201c9148d8bf6ee6f4f8ff55c00048f`.
  Helper SHA-256:
  `a78b4eef7cb15b476aedda0772f1dbadf895b3f39be837824217d538198175ec`.
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
- `lyte-host.service` PID 237010 is active on UDP 41151. Its configured 120-second
  no-client-handshake timeout can exercise systemd restart policy; a changing
  PID alone is not a host crash.
- Deployed release binary: `~/src/lyte-host/.build/release/lyte-host`, SHA-256
  `7f0be45e971e2a63b8f2aa74d155febe39b195d821511460cf37f4287da4d9a6`.
- Session log: `/tmp/lyte-host-session.log`.
- PR #203 is commissioned: after the one-time old-binary SIGKILL, an ordinary
  `systemctl restart` of the new pre-session process completed in 438 ms,
  logged `termination requested before handshake — clean stop`, and exited
  through systemd normally. Future no-client restarts need no force or reboot.

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

1. In the freshly launched Lyte app, select pup (or Search Again) and confirm
   that the exact client and host complete Noise and open the Direct Eye.
2. Capture a controlled performance trace on pup's current Wi-Fi, lid-closed
   setup; diagnose frozen video/audio choppiness from current-build evidence.
3. Keep that baseline green while adding thin macOS/Linux/Windows/browser
   shells at the shared client boundary.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Source-layout decision: `docs/20260803-084328-source-layout-and-migration.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
