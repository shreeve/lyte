# Lyte — session handoff

*Current as of 2026-08-06. Live resume only; Git owns completed history.*

## Resume here

- **Tip:** `main` @ PR #222 family (sparse-evidence symmetric hold; pull for
  exact SHA). Includes #220 IRAP close and #221 reproof docs.
- **Next:**
  1. Owner visual check of resize-corner cursor tips (owed from #212) —
     tl/tr/br/bl shape/tip match and `cursor derive` with real `plane(x,y)` /
     non-zero hotspots.
  2. Optional later: HS-30 probe-cadence A/B; longer motion settle under
     moderate netem once loss-band noise is better characterized;
     Conductor numbers on a true Ethernet client path.

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
  `e8b5664361827974b55df6244b183ea2fd73898407a9753b615adc8452c23fb4` at
  `/home/shreeve/src/lyte-host/.build/release/lyte-host` (sparse-hold tip).
  Identity files verified unchanged through the #222 climb re-proof cycle.
  Session log: `/tmp/lyte-host-session.log`.

**Safety (law in `AGENTS.md`):** never touch
`~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`; never
displace 41151 — test hosts use a fresh 41xxx port and `--no-advertise`; no
second Direct Eye while 41151 holds the DRM seat; hand-run binaries under the
home build tree with `setcap` (not `/tmp`).

## Proof (2026-08-06)

### ONE — harsh-path climb — PASS (doctrine + sparse-hold)

**Root cause of “0 upshifts” on quiet static:** content-driven. After the
opening IDR drains, ~300 B keepalives are single-datagram flights — no
delivery train (≥3 matched packets) forms, so `lastDeliveryAt` goes stale and
climb is unreachable by construction. Wire-view “quality Mbps” is **content**
bitrate, not standing rate (post-#220 static ended at **13.8 Mbps** standing
with belief ~33 Mbps, not the 2 Mbps floor). Doctrine forbids padding a blank
desktop to probe (`docs/20260806-115922-harsh-path-control-plane.md`).

**Policy fix (#222):** loss / overuse / post-FEC falls now require the same
delivery freshness as climbs **or** standing pacer backlog. Sparse keepalive
under mild netem **freezes** instead of one-way ratcheting. Book:
`sparseEvidenceHolds`.

**Climb proof bar:** mild-motion under moderate netem — not quiet-static.

Port **41202** (`--no-advertise --require-paired`); standing 41151 stopped for
the DRM seat then restored. Netem: moderate `20ms / 10ms / 1%`, scoped
`sport 41202 → 10.0.0.211` via `port-netem.sh` (removed after). Host tip
`a6c1455…` / SHA `e8b56643…`. 60 s `lyte-cli wire-view` + motion-presenter.
Identity hashes unchanged.

| Check | Result |
|---|---|
| Static no-climb doctrine | **PASS** — correct; not a climb defect |
| Sparse ratchet closed | **PASS** — unit pins; live book showed 1 sparse hold |
| Motion upshifts above floor | **PASS** — **5 upshifts**, final **3208 kbps** (> 2 Mbps floor); 21 downs (loss-limited settle ~3 Mbps while belief stayed ~33 Mbps) |
| IDR storm | **PASS** — **1 IDR / 60 s**, 0 client IDR-requests acted; 0 FROZEN mode transitions |
| No RECOVERY thrash | **PASS** — 0 frames suppressed (FROZEN/closed) |

Artifact: `.build/benchmarks/harsh-path-climb-20260806T234411Z/`.
Prior static PARTIAL: `.build/benchmarks/harsh-path-20260806T213410Z/`.

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
