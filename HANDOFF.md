# Lyte — session handoff

*Current as of 2026-08-06. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** `main` @ `57c3a5b`.
- **Just landed:** PR #212 (`b778989`) — glass-cursor tip/hotspot fix:
  enable `DRM_CLIENT_CAP_ATOMIC` so cursor `CRTC_X`/`CRTC_Y` are visible;
  keep a missing plane distinct from a real `(0,0)` park; sans-IO
  `CursorHotspot` pins. Tip includes #209–#212.
- **Current objective:** verify resize-corner cursor alignment live, then
  prove the harsh-path control plane and finish Conductor reserve
  commissioning.

## Last green gates

PR #212 Host suite green (350), including new `CursorHotspotTests`. PR #209
Host suite green (342). PR #210 Wire suite green (514) plus focused Host
`SessionGateTests`. The earlier full warning-enforced macOS + pup gate still
stands on the PR #207 source pin (`79df48f` / Common 98, Wire 513,
Host 341–343, Client 347, SystemTests 17); re-run a complete gate only if a
later touch wants a fresh cross-package stamp.

Focused Conductor pins remain: severe holes grow posture to exactly four
beats; 60 Hz / 30 Hz / one-Hz clean evidence return one beat after two
elapsed seconds; contrary evidence restarts the proof.

## Current live rig

### Client

- Fresh release app from `main` @ `57c3a5b` (`LyteSourceRevision` =
  `57c3a5b81af2`), launched via `Scripts/launch-app.sh` as PID **39823**.
  Bundle: `.build/Lyte.app` (`dev.shreeve.lyte`). Connect manually if needed.
- Bundle identity remains `dev.shreeve.lyte`. Do not launch a benchmark or
  second ordinary app while an interactive Lyte is open.
- The owner-installed Local Network exception `10.0.0.0/24` remains active
  after Apple Feedback FB21858319/FB21858436.

### Host

- `pup` is wired at `10.0.0.232/24` on `enxf8e43b7ede7c`; Wi-Fi `.249` is the
  backup. `/etc/lyte/lyte-host.conf` advertises the wired interface.
- `lyte-host.service` remains the standing UDP 41151 host. Its PID can change
  when the configured 120-second no-client-handshake timeout exercises
  systemd restart; a changing pre-session PID alone is not a crash.
- **Deploy honesty:** standing binary rebuilt from `main` @ `57c3a5b` on
  2026-08-06; service restarted active, listening `0.0.0.0:41151`. Binary
  SHA-256 `8b527bda30e9bbebd513cb7a4b50c18a0decf389ecce673a8e8b048b91a709f0`
  at `/home/shreeve/src/lyte-host/.build/release/lyte-host`. Identity files
  unchanged (portal_token / noise_static.key / paired_clients checksums
  verified before and after restart). Session log:
  `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`.

## Latest performance evidence

Controlled 30-second Wi-Fi motion (pre-#204): 1,831/1,831 frames at
59.978 fps, zero IDR/loss/NACK/renderer failures, exact 16.667 ms gaps,
transport p99 5.819 ms, ~57 dB native quality. Artifact:
`.build/benchmarks/motion-20260805T183100Z-15743-4985f42799bc.jsonl`.

Harsh-path unit evidence is on main (#209); live moderate-netem /
delay-burst re-commission after deploy is still owed. Conductor
reserve-distribution measurement on current builds remains outstanding.

## Next commissioning order

1. ~~Cursor tip/hotspot fix (#212) + deploy host/client~~ done
   (`57c3a5b`; host active on 41151; client PID 39823). Owner should connect
   and verify window resize corners (tl/tr/br/bl): shape and tip must match
   the drawn cursor; session log `cursor derive` lines should show real
   `plane(x,y)` (not `nil` / tip fallback) and non-zero hotspots on resize
   chrome.
2. Harsh-path live proof on a fresh 41xxx test host (never 41151): moderate
   netem + delay-burst per
   `docs/20260806-115922-harsh-path-control-plane.md`; confirm climb leaves
   the old ~3 Mbps settle and IDR stays near the prior 2-IDR result; restore
   qdisc/binary after.
3. Observe motion then a static screen; confirm Conductor reserve returns one
   beat per two clean seconds toward one beat (~17 ms), never above four
   (~67 ms).
4. Quit the ordinary app; run the exact-build 30-second motion benchmark on
   Ethernet, then Wi-Fi with lid closed; record cue/reserve p50/p95/max with
   the existing cadence, loss, quality, and renderer gates.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Harsh-path control plane: `docs/20260806-115922-harsh-path-control-plane.md`
- Metronome design: `docs/20260803-050422-metronome-playout-design.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
