# Lyte — session handoff

*Current as of 2026-08-05. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** clean `main` through PR #205 after this handoff lands. There is
  one checkout, no auxiliary worktree, and no open implementation PR.
- **Current objective:** measure the newly bounded Conductor first on pup's
  wired path, then under the owner's adverse Wi-Fi/lid-closed setup. Preserve
  exact 60 Hz beat cadence while proving that clean reserve settles near one
  beat and real trouble can earn no more than four.
- **Recent landings:** PR #203 made pre-session host shutdown prompt and clean.
  PR #204 made the benchmark analyzer treat the first-three-second native
  readback race as warm-up while keeping every steady-state quality gate hard.
  PR #205 made the automatic video reserve an exact 1–4 beat posture: one beat
  at rest, whole-beat growth only after a real hole, a four-beat ceiling, and
  one beat returned after each 120-frame (~2 s) clean proof. The 150 ms total
  cue remains only a path-delay/clock-mapping failsafe; it cannot mint hidden
  reserve beyond four beats.

## Last green gates

The exact PR #205 source commit `5f41098` (landed as `360d788`) passed the
complete warning-enforced macOS gate: Common 96, Wire 513, Host 341, Client
347, and SystemTests 17. Frozen-vector, sans-IO and ownership ratchets;
benchmark and host-release safety; analyzer tests; signing; app identity;
hermetic linkage; release-image and installer tests; and double signed
release-app assembly all passed.

The same source passed pup's deterministic Linux gate: Common 96, Wire 513,
and Host 343; warning-enforced portable-client, host debug, and host release
builds; release-image and installer checks; hermetic linkage; kernel socket/TOS
and pacing harnesses; and protected-state verification. Rebuilding the host
produced the same release-binary SHA-256, confirming PR #205 changes only
client playout policy.

Focused Conductor tests pin both directions of the law: a severe hole grows
the shipping posture from one beat to exactly four and cannot mint a fifth;
clean evidence then returns all three earned beats one at a time until the
one-beat floor is restored.

## Current live rig

### Client

- `.build/Lyte.app` PID 74705 is the freshly release-built, signed, and
  published PR #205 landing. It completed Noise with pup, opened video, and is
  the only ordinary Lyte client running.
- Product source revision `360d788d6d18`; bundle build `1785955849`; build UTC
  `2026-08-05T18:51:16Z`; source-tree digest
  `b5ad83fc80a7d8cf3c284b7afe846788fdb78b5503ab7829ace8afd5f0a09539`.
- Lyte executable SHA-256:
  `ca1d2a1f7dc6adf7899e5dda3b6393fdb0a6a2994a1da5c4e994355d8a935204`.
  Helper SHA-256:
  `af01bdd8bbd1d90ce94eaea8a014daeedf961334c2c6d1cb0b358eb8c3076c3b`.
- Bundle identifier `dev.shreeve.lyte`, team `SD6N7Z8P9P`, signed by
  `Apple Development: Steve Shreeve (8FHNN4RZ9Q)`.
- Do not launch a benchmark or second ordinary app while this one is open;
  both use the same bundle identity.
- The owner-installed Local Network exception `10.0.0.0/24` remains active
  after Apple Feedback FB21858319/FB21858436 captured the contradictory
  preference-allowed/path-prohibited macOS state.

### Host

- `pup` is wired at `10.0.0.232/24` on `enxf8e43b7ede7c`; Wi-Fi `.249` is the
  backup. `/etc/lyte/lyte-host.conf` advertises the wired interface.
- `lyte-host.service` is active on UDP 41151. Its PID can change when the
  configured 120-second no-client-handshake timeout exercises systemd restart;
  a changing pre-session PID alone is not a crash.
- Deployed release binary SHA-256:
  `7f0be45e971e2a63b8f2aa74d155febe39b195d821511460cf37f4287da4d9a6`.
- Session log: `/tmp/lyte-host-session.log`.
- The commissioned PR #205 client negotiated Best 4:4:4 and opened the native
  VAAPI Direct Eye at 2048×1280. The current socket is
  `10.0.0.232:41151 → 10.0.0.211`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Latest performance evidence

The controlled 30-second Wi-Fi motion run immediately before PR #204 delivered
1,831/1,831 frames at 59.978 fps with zero IDR requests, zero loss/NACKs, zero
renderer failures, exact 16.667 ms presentation gaps, 5.819 ms transport p99,
and about 57 dB native quality. One readback unavailable at 1.007 s was wholly
inside excluded warm-up; the corrected analyzer passes the trace with no
failure. Artifact:
`.build/benchmarks/motion-20260805T183100Z-15743-4985f42799bc.jsonl`.

PR #205's unit and composition proof is complete, and the exact landed app is
live. Its controlled Ethernet and adverse-Wi-Fi reserve distributions remain
the next measurement; do not claim the subjective latency win from unit proof
alone.

## Next commissioning order

1. Observe the ordinary wired session after clean motion and confirm the UI's
   reserve returns toward one beat (~17 ms), never above four (~67 ms).
2. Quit the ordinary app, run the exact-build 30-second motion benchmark on
   Ethernet, and record cue/reserve p50, p95, and maximum alongside the existing
   cadence, loss, quality, and renderer gates.
3. Repeat the same trace with pup on Wi-Fi and lid closed. Compare the same
   authored workload; diagnose only from current-build evidence.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Metronome design: `docs/20260803-050422-metronome-playout-design.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
