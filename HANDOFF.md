# Lyte — session handoff

*Current as of 2026-08-07. Live resume only; Git owns completed history.*

## Resume here

- **Campaign:** harsh-path control plane is **closed** on `main` —
  #209 ownership/floor, #210 RECOVERY grace, #212 cursor ATOMIC hotspot,
  #220 wire-view IRAP episode close (~114 → 2 IDRs), #222 sparse-evidence
  rate freeze (quiet-static no-climb is doctrine; motion climb proven).
  Living-doc cleanup landed in the #216 family.
- **Tip:** `main` @ browser B-2 — WebTransport datagram carrier in Chrome
  (pull if HEAD moved). Opaque Lyte envelopes / Noise ciphertext round-trip
  WT↔UDP via `lyte-wt-sidecar`; measured ceiling ≥ 1152 B (`Browser/`,
  `docs/BROWSER.md`).
- **Next:** **B-3** — pair, Noise, capabilities, control-only session
  against pup over the browser WT carrier. No media. Wayland clipboard
  leaf remains **blocked on GNOME** —
  `docs/20260807-015743-wayland-clipboard-gnome-blocker.md`.

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
- Standing service: `lyte-host.service` on UDP **41151**. PID changes on the
  configured 120 s no-client-handshake systemd restart — not alone a crash.
- Deployed binary SHA-256
  `e8b5664361827974b55df6244b183ea2fd73898407a9753b615adc8452c23fb4` at
  `/home/shreeve/src/lyte-host/.build/release/lyte-host` (#222 tip).
  Identity files verified unchanged through the climb re-proof cycle.
  Session log: `/tmp/lyte-host-session.log`.

**Safety (law in `AGENTS.md`):** never touch
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`; never
displace 41151 — test hosts use a fresh 41xxx port and `--no-advertise`; no
second Direct Eye while 41151 holds the DRM seat (parallel eyes black the
glass); hand-run binaries under the home build tree with `setcap` (not
`/tmp`).

## Proof (final bars)

### Browser B-2 — PASS (Chrome)

```sh
Browser/Scripts/build.sh
Browser/Scripts/smoke-chrome.sh
# PASS  envelope-v1/nominal-video-shard
# PASS  noise-v1/snow-ik-25519-chachapoly-sha256
# PASS  wt-carrier/envelope-echo
# PASS  wt-carrier/noise-msg1-echo
# PASS  wt-carrier/budget-1152
# PASS  wt-carrier/ceiling — measured 1214 B ≥ 1152 B
#        (reported maxDatagramSize=1024; measure is truth)
```

Interactive: `Browser/Scripts/serve.sh` → http://127.0.0.1:8765/ in Chrome
(starts `lyte-wt-sidecar`). Safari not a gate. Adapter decision: same-box
sidecar for B-2; host leaf packaging deferred. No pup session / media yet
(B-3…).

### Harsh-path — PASS (closed)

Doctrine: quiet-static 0 upshifts is correct (no delivery trains; do not
pad). Wire-view “quality Mbps” is content bitrate, not standing rate.
Book: `docs/20260806-115922-harsh-path-control-plane.md`.

| Check | Result |
|---|---|
| #220 IRAP / IDR storm | **PASS** — episode ~114 → 2 IDRs; re-proof 1 IDR / 60 s, 0 client IDR-requests acted, 0 FROZEN |
| #222 sparse hold | **PASS** — unit pins; live book 1 sparse hold; static no-climb correct |
| Motion climb | **PASS** — **5 upshifts**, final **3208 kbps** (> 2 Mbps floor); 21 downs (loss-limited ~3 Mbps; belief ~33 Mbps) |
| RECOVERY thrash | **PASS** — 0 frames suppressed (FROZEN/closed) |

Artifacts: `.build/benchmarks/harsh-path-climb-20260806T234411Z/` (motion);
`.build/benchmarks/harsh-path-20260806T213410Z/` (prior static PARTIAL).

### Conductor cue/reserve — PASS (Wi‑Fi)

Path: Mac Wi‑Fi 10.0.0.211 → pup wired `.232`. Ethernet client path optional
later (`TODO.md`).

- **Motion 30 s:** analyzer **PASS**. Cue p50/p95/max
  **47.933 / 65.270 / 127.900** ms; reserve p50/p95/max
  **22.100 / 55.068 / 55.240** ms (**~1.33 / 3.30 / 3.31** beats); reserve
  never above four.
  Artifact: `.build/benchmarks/conductor-20260806T212417Z/motion-20260806T212428Z-11686-71df5e4e53d0.jsonl`.
- **Static reserve return** (20 s idle after motion): reserve **3.76 → 1.05**
  beats across ~18 s; never above four. (Analyzer FAIL on static
  presentation-gap is expected for sparse keepalives.)
  Artifact: `.build/benchmarks/conductor-static-20260806T212519Z/`.

## Pointers

- Law and canonical commands: `AGENTS.md`
- Deferred work: `TODO.md`
- Browser living direction: `docs/BROWSER.md`
- Browser platform B-0: `docs/20260807-021425-browser-client-platform-slice.md`
- Harsh-path control plane: `docs/20260806-115922-harsh-path-control-plane.md`
- Metronome design: `docs/20260803-050422-metronome-playout-design.md`
- Direct Eye correction: `docs/20260805-084033-direct-eye-pixel-observation.md`
