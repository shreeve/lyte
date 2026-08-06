# Lyte — session handoff

*Current as of 2026-08-06. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** `recovery-silence-grace` off latest `main` (separate from open
  `harsh-path-recovery` / PR #209). One checkout; no auxiliary worktree.
- **Current objective:** land the RECOVERY-only silence grace so CTRL wakes
  cannot thrash FROZEN⇄RECOVERY at the ACTIVE 350 ms bar; keep #209's floor /
  FEC / 0x10 work on its own train.
- **Recent landings:** PR #208 recorded the time-proof commissioning. PR #207
  made Conductor return cadence-independent. Harsh-path floor/FEC work remains
  on PR #209; this branch is only the session-machine hysteresis follow-up.

## Last green gates

The exact PR #207 source commit `79df48f` passed the complete warning-enforced
macOS gate: Common 98, Wire 513, Host 341, Client
347, and SystemTests 17. Frozen-vector, sans-IO and ownership ratchets;
benchmark and host-release safety; analyzer tests; signing; app identity;
hermetic linkage; release-image and installer tests; and double signed
release-app assembly all passed.

The same source passed pup's deterministic Linux gate: Common 98, Wire 513,
and Host 343; warning-enforced portable-client, host debug, and host release
builds; release-image and installer checks; hermetic linkage; kernel socket/TOS
and pacing harnesses; and protected-state verification. The standing host was
not displaced and protected identity/configuration state remained unchanged.

Focused Conductor tests pin both directions and all relevant cadences: a severe
hole grows the shipping posture from one beat to exactly four and cannot mint a
fifth; 60 Hz, 30 Hz, and one-Hz clean evidence return one beat after the same
two elapsed seconds; contrary path evidence restarts the proof; and four beats
return to the one-beat floor in exactly six clean seconds at one Hz.

## Current live rig

### Client

- `.build/Lyte.app` PID 69280 is the freshly release-built, signed, and
  published PR #207 landing. It completed Noise with pup, opened video, and is
  the only ordinary Lyte client running.
- Product source revision `05df35c7ac1b`; bundle build `1785964994`; build UTC
  `2026-08-05T21:23:43Z`; source-tree digest
  `f717264f24619bd46d58bf881642b69f63d6589f891fe9ed24b4eafa1e69c454`.
- Lyte executable SHA-256:
  `81e66a7dd75cc9f11bc238c24fa0adff2148d3f4273b90772a15437eb77445b2`.
  Helper SHA-256:
  `d7b38435a3a05fc009c8e5d546f52890d741f9b08bb3aedfa8b1d14dc648f9f5`.
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
- The commissioned PR #207 client negotiated Best 4:4:4 and opened the native
  VAAPI Direct Eye at 2048×1280. The current socket is
  `10.0.0.232:41151 → 10.0.0.211:56798`.

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

A passive paused-video observation exposed the final PR #205 defect: at roughly
one fresh frame per second, its 120-frame proof meant about two minutes rather
than two seconds, and its 600-sample path tail could retain stale evidence for
about ten minutes. PR #207 replaces both sample-count durations with exact
elapsed-time policy. Its exact landed release app is now live; controlled
reserve-distribution measurement remains outstanding.

## Next commissioning order

1. Observe motion followed by a static screen and confirm reserve returns one
   beat per two clean seconds toward one beat (~17 ms), never above four
   (~67 ms).
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
