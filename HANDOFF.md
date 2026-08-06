# Lyte — session handoff

*Current as of 2026-08-06. This is the live resume point; Git owns completed
history.*

## Resume here

- **Branch:** `main` @ tip including PR #214 (`4617fc8` family; pull for
  exact SHA).
- **Just landed:** PR #214 — `benchmark-netem.sh` requires
  `LYTE_BENCHMARK_PORT` and refuses standing 41151 unless explicitly allowed.
- **Current objective:** owner visual check of resize-corner cursor tip
  (still owed from #212). Harsh-path live proof and Conductor cue/reserve
  commissioning numbers are recorded below.

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

- Fresh release app from tip (`LyteSourceRevision` matches the rebuilt
  bundle), launched via `Scripts/launch-app.sh`. Connect manually if needed.
- Bundle identity remains `dev.shreeve.lyte`. Do not launch a benchmark or
  second ordinary app while an interactive Lyte is open.
- The owner-installed Local Network exception `10.0.0.0/24` remains active
  after Apple Feedback FB21858319/FB21858436.
- Mac path to pup is **Wi‑Fi `en0` / 10.0.0.211** (not a dedicated Ethernet
  NIC on this client); treat conductor numbers as Wi‑Fi evidence.

### Host

- `pup` is wired at `10.0.0.232/24` on `enxf8e43b7ede7c`; Wi-Fi `.249` is the
  backup. `/etc/lyte/lyte-host.conf` advertises the wired interface.
- `lyte-host.service` remains the standing UDP 41151 host. Its PID can change
  when the configured 120-second no-client-handshake timeout exercises
  systemd restart; a changing pre-session PID alone is not a crash.
- **Deploy honesty:** standing binary SHA-256
  `8b527bda30e9bbebd513cb7a4b50c18a0decf389ecce673a8e8b048b91a709f0` at
  `/home/shreeve/src/lyte-host/.build/release/lyte-host`. Identity files
  unchanged through the harsh-path stop/start cycle (portal_token /
  noise_static.key / paired_clients checksums verified). Session log:
  `/tmp/lyte-host-session.log`.

Never touch pup's
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}` and never
displace its standing UDP 41151 service. Test hosts require a fresh 41xxx port
and `--no-advertise`. **Do not run a second Direct Eye while 41151 holds the
DRM seat** — parallel eyes black the interactive glass. Hand-run test binaries
must live off `/tmp` (`nosuid` strips file caps); put them under the home
build tree and `setcap` there.

## Latest performance evidence

### Clean motion (prior)

Controlled 30-second Wi-Fi motion (pre-#204): 1,831/1,831 frames at
59.978 fps, zero IDR/loss/NACK/renderer failures, exact 16.667 ms gaps,
transport p99 5.819 ms, ~57 dB native quality. Artifact:
`.build/benchmarks/motion-20260805T183100Z-15743-4985f42799bc.jsonl`.

### ONE — harsh-path live proof (2026-08-06) — FAIL / PARTIAL

- **Port:** 41200 (`--no-advertise --require-paired`); standing 41151 stopped
  for the DRM seat, then restored.
- **Netem:** moderate `20ms delay / 10ms jitter / 1% loss`, scoped
  `sport 41200 → 10.0.0.211` via `port-netem.sh`; removed after.
- **Tip / binary:** client tip `4617fc8`; host SHA `8b527bda…`.
- **Client:** 60 s `lyte-cli wire-view` (CLI, not Lyte.app).
- **Numbers (primary timed leg):** host `ctrl: IDR request` **116**,
  `static-screen IDR served` **114**, eye book **115 IDRs**; client
  **116 IDR-requests / 4 verdicts**; **0** `lifecycle: FROZEN` / **0**
  client `PILL ON`; rate fell to floor **2000 kbps**, with **18–25**
  `evidence climb` upshifts (e.g. 2000→~2889) that loss repeatedly pulled
  back — not the old 500 kbps pin, but not a sustained climb off the floor
  under continuous 1% loss.
- **Verdict:**
  - IDR storm gone → **FAIL** (still ~114–116 served IDRs / 60 s; static /
    near-static + lost-IDR re-arm under 1% loss).
  - Climb under mild residual → **PARTIAL** (climbs fire above 2 Mbps floor;
    settle remains floor-neighborhood under this impairment).
  - No RECOVERY thrash → **PASS** (zero FROZEN).
- Artifacts: `.build/benchmarks/harsh-path-20260806T211856Z/` and
  `.build/benchmarks/harsh-path-motion-20260806T212138Z/`.

### TWO — Conductor cue/reserve (2026-08-06) — PASS (Wi‑Fi)

- **Path honesty:** Mac `en0` Wi‑Fi 10.0.0.211 → pup wired `.232` (no client
  Ethernet NIC in use).
- **Motion 30 s** (`Scripts/benchmark-app.sh --seconds 30 motion`, analyzer
  **PASS**): cue p50/p95/max **47.933 / 65.270 / 127.900** ms; reserve
  p50/p95/max **22.100 / 55.068 / 55.240** ms (**~1.33 / 3.30 / 3.31** beats);
  reserve never above four. Artifact:
  `.build/benchmarks/conductor-20260806T212417Z/motion-20260806T212428Z-11686-71df5e4e53d0.jsonl`.
- **Static reserve return** (20 s idle desktop after motion): reserve
  **3.76 → 1.05** beats across ~18 s at ~one beat per two clean seconds
  (e.g. 3.76→2.92→2.08 … →1.09→1.05); never above four. Analyzer FAIL on
  static presentation-gap (expected for sparse keepalives); conductor
  return law is the measured bar. Artifact:
  `.build/benchmarks/conductor-static-20260806T212519Z/`.

## Next commissioning order

1. ~~Cursor tip/hotspot fix (#212) + deploy host/client~~ done; **owner still
   should verify** window resize corners (tl/tr/br/bl) live — shape/tip match
   and `cursor derive` lines with real `plane(x,y)` / non-zero hotspots.
2. ~~Harsh-path live proof on fresh 41xxx~~ **done — FAIL/PARTIAL** (see ONE).
   Follow-up: stop the static-screen lost-IDR re-arm storm under 1% loss
   without restoring dual-path host stale-NACK amplification.
3. ~~Conductor reserve live measure~~ **done — PASS on Wi‑Fi** (see TWO).
   Optional later: repeat on a true Ethernet client path when available.
4. Optional: HS-30 probe-cadence A/B once a non-storming harsh climb is live.

## Recovery pointers

- Repository law and canonical commands: `AGENTS.md`
- Deferred actionable work: `TODO.md`
- Harsh-path control plane: `docs/20260806-115922-harsh-path-control-plane.md`
- Metronome design: `docs/20260803-050422-metronome-playout-design.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
- Retired strategy: `git show 59e8bb4:LYTE-PLAN.md`
