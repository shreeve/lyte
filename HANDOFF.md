# Lyte — session handoff

*Current as of 2026-08-06. Live resume only; Git owns completed history.*

## Resume here

- **Tip:** `main` @ PR #220 family (diagnostic IRAP close; pull for exact SHA).
  Includes #215 commissioning and #216 root-docs cleanup.
- **Next:**
  1. Owner visual check of resize-corner cursor tips (owed from #212) —
     tl/tr/br/bl shape/tip match and `cursor derive` with real `plane(x,y)` /
     non-zero hotspots.
  2. Optional later: harsh-path climb under mild residual once a motion leg
     is re-run without the IDR storm (proof ONE still PARTIAL on climb);
     Conductor numbers on a true Ethernet client path; HS-30 probe-cadence
     A/B.

## Live rig

### Client (pop)

- Fresh release app from tip (`LyteSourceRevision` matches the rebuilt
  bundle), launched via `Scripts/launch-app.sh`. Bundle identity
  `dev.shreeve.lyte` — do not launch a benchmark or second ordinary app while
  interactive Lyte is open.
- Mac path to pup is **Wi‑Fi `en0` / 10.0.0.211** (no dedicated Ethernet NIC
  on this client). Local Network exception `10.0.0.0/24` remains active
  (FB21858319/FB21858436).

### Host (pup)

- Wired `10.0.0.232/24` on `enxf8e43b7ede7c`; Wi‑Fi `.249` backup.
  `/etc/lyte/lyte-host.conf` advertises the wired interface.
- Standing service: `lyte-host.service` on UDP **41151**. PID may change on
  the configured 120 s no-client-handshake systemd restart — not alone a crash.
- Deployed binary SHA-256
  `8b527bda30e9bbebd513cb7a4b50c18a0decf389ecce673a8e8b048b91a709f0` at
  `/home/shreeve/src/lyte-host/.build/release/lyte-host`. Identity files
  verified unchanged through the #220 harsh-path stop/start cycle. Session
  log: `/tmp/lyte-host-session.log`.

**Safety (law in `AGENTS.md`):** never touch
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`; never
displace 41151 — test hosts use a fresh 41xxx port and `--no-advertise`; no
second Direct Eye while 41151 holds the DRM seat; hand-run binaries under the
home build tree with `setcap` (not `/tmp`).

## Proof (2026-08-06)

### ONE — harsh-path live — PASS (IDR) / PARTIAL (climb)

Port **41201** (`--no-advertise --require-paired`); standing 41151 stopped for
the DRM seat then restored. Netem: moderate `20ms delay / 10ms jitter / 1%
loss`, scoped `sport 41201 → 10.0.0.211` via `port-netem.sh` (removed after).
Client tip includes #220; host SHA `8b527bda…` (unchanged host code). 60 s
`lyte-cli wire-view`. Identity hashes unchanged through the cycle.

| Check | Result |
|---|---|
| IDR storm gone | **PASS** — host **2 IDRs / 1 static-screen** / 60 s (`ctrl: IDR request` 1; client **1 IDR-request / 5 verdicts**) — was ~114–116 static IDRs |
| Climb under mild residual | **PARTIAL** — static quiet desktop; 8 loss/overuse downshifts, **0 upshifts**; no floor pin, not a sustained climb (re-check on motion) |
| No RECOVERY thrash | **PASS** — 0 `lifecycle: FROZEN` / 0 client `PILL ON` |

Root cause of the prior storm: wire-view enqueued IRAPs without
`noteVideoIrapEnqueued`, so `IdrRequester` retried forever while the host's
500 ms offer window re-armed retained-surface IDRs. Fixed in #220.

Prior FAIL artifact: `.build/benchmarks/harsh-path-20260806T211856Z/`.
Re-proof: `.build/benchmarks/harsh-path-20260806T213410Z/`.

### TWO — Conductor cue/reserve — PASS (Wi‑Fi)

Path: Mac Wi‑Fi 10.0.0.211 → pup wired `.232`.

- **Motion 30 s** (`Scripts/benchmark-app.sh --seconds 30 motion`): analyzer
  **PASS**. Cue p50/p95/max **47.933 / 65.270 / 127.900** ms; reserve
  p50/p95/max **22.100 / 55.068 / 55.240** ms (**~1.33 / 3.30 / 3.31** beats);
  reserve never above four.
  Artifact: `.build/benchmarks/conductor-20260806T212417Z/motion-20260806T212428Z-11686-71df5e4e53d0.jsonl`.
- **Static reserve return** (20 s idle after motion): reserve **3.76 → 1.05**
  beats across ~18 s at ~one beat per two clean seconds; never above four.
  (Analyzer FAIL on static presentation-gap is expected for sparse keepalives;
  conductor return law is the measured bar.)
  Artifact: `.build/benchmarks/conductor-static-20260806T212519Z/`.

Focused Conductor unit pins still hold: severe holes grow posture to exactly
four beats; clean 60/30/1 Hz evidence returns one beat after two elapsed
seconds; contrary evidence restarts the proof.

## Pointers

- Law and canonical commands: `AGENTS.md`
- Deferred work: `TODO.md`
- Harsh-path control plane: `docs/20260806-115922-harsh-path-control-plane.md`
- Metronome design: `docs/20260803-050422-metronome-playout-design.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
