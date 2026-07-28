# Lyte video-quality probe — PSNR, drops, cadence at the post-HS-22b build

*2026-07-28, ~10:20–10:50 MDT (16:20–16:50 UTC). A measurement-only probe:
no package sources touched, no repo builds in the working tree. The owner
remembers "choppiness and blurriness" from the trip era and wanted numbers.
Here they are.*

## What ran, on what

- **Host**: the deployed HS-22b-verified binary, copied out of harm's way
  before any worker rsync could replace it —
  `~/src/lyte-host/.build/debug/lyte-host` (mtime 2026-07-27 21:28:27,
  19,275,440 B, answers `--no-vbv-reconfigure`) → `~/qprobe/lyte-host`.
  Only the copy ever ran. All probe instances on **port 41166**; the
  owner's loop and 41151 untouched (the loop was down when the probe
  started and came back up mid-probe — see hygiene).
- **Client**: `lyte-cli` release, built ONCE from a `git worktree` of HEAD
  `b9a4923` at `~/lyte-qprobe-wt` (outside the repo — the root worker's
  territory stayed unchurned), signed "Lyte Dev" via `build-cli.sh`. The
  repo's existing release binary predated HS-22a's quality line and the
  debug binary was the root worker's live churn — neither would do.
- **Recipe**: the prior gate's method (`493b6bd`, the ~50 dB slice-3 gate),
  rediscovered and reused. `LYTE_DUMP_RAW=<path>` env-gates a dump of the
  **final retained raw frame** (stride-packed BGRx as PipeWire delivered
  it) at run end; file mode writes the Annex-B HEVC alongside. Decode the
  stream, convert both sides to yuv420p, and read **luma PSNR** from
  ffmpeg's `psnr` filter (`shortest=1`, looped raw reference). The gate
  bar: ≥ 50 dB post-ratchet on static content. 2048×1280 bgr0, stride
  8192 (no padding). All encodes ran `--ratchet` (capped-CQ — the session
  posture) with `--bitrate-mbps 20` on wire-shaped legs to match the
  HS-22b books ("cap 20000 kbps").

## 1. Fidelity — PSNR

### Static desktop (file mode, 60 s, the blur time-series)

311 frames encoded (61 damage — the 1 Hz clock, 250 ratchet passes),
**1 IDR**, QP 12 throughout, 2.85 MB total (0.38 Mbps). Per-frame luma
PSNR of every decoded frame against the single end-of-run reference:

| scene | n | min | p5 | p50 | mean | max |
|---|---|---|---|---|---|---|
| static, all frames vs last-frame ref | 311 | 44.01 | 45.70 | 46.46 | 46.95 | **53.48** |
| motion, last-frame pairs (12 runs) | 12 | 56.08 | — | 56.68 | 56.76 | 57.47 |

Read the static row carefully: the reference is the LAST frame, and the
desktop clock ticks — mid-run frames genuinely differ from the reference
in the clock pixels, so the 45.8–48 dB plateau is **content drift, not
codec softness**. The honest fidelity number is the tail, where content
matches the reference: **53.5 dB, clearing the prior gate's 50 dB bar**.
The opening IDR scores 44.0 dB — against the old first-IDR 38.6 dB
(`493b6bd`): even the worst frame of the run is ~5.4 dB better than the
old opening.

### Motion (12 × 6 s file-mode runs, testsrc2 60 fps in a 1600×1000 window)

Each run yields one valid pair (the dump is last-frame-only), so twelve
runs give twelve samples: **56.1–57.5 dB, median 56.7** — at the 20 Mbps
cap (15.1–15.3 MB per 6.1 s run ≈ 20 Mbps, 362–368 frames ≈ 60 fps
sustained in file mode). Caveat: testsrc2 is synthetic, flat-color,
encoder-friendly content; real video would land lower. Fullscreen stayed
windowed per HS-22b's direct-scanout finding (true fullscreen = zero
portal frames).

## 2. Blur check — the time-series shape

Sampled every 10th frame of the static series, in encode order:
44.0 (IDR) → 46.8, 47.9, 46.4, 45.8, 46.0, 47.2, 46.4, 46.5, 45.9, 46.1,
47.3, … (flat band ~45.8–48 through frame ~250) … → 48.9, 50.7, 49.2,
49.8, 53.5. **A flat line with no periodic dips** — the ripple is the
clock content, the rise at the end is content converging on the
reference. No 38 dB craters, no 1 Hz sawtooth. **The 1 Hz ghost stays
retired** at this build, corroborating HS-22b leg (d) (183 → 3 IDR).

## 3. Frame delivery + drops — the live-wire legs (the "choppiness" question)

Two 150 s motion sessions (same looped testsrc2 window on the host
desktop), host on 41166 from the copy, client `wire-view --audio` on the
Mac, plus one 90 s no-content leg. The A/B pair is the HS-22 lever:

| | run A (policy armed) | twin (`--no-vbv-reconfigure`) |
|---|---|---|
| host frames emitted | 5,692 | 4,830 |
| client frames decoded (+skipped) | 5,689 (+2) | 4,828 (+1) |
| **frames lost on the wire** | **~0 (≤1 + teardown in-flight)** | **~0 (≤1)** |
| video datagrams missing | 37 / 155,020 (0.024%) | 36 / 205,374 (0.018%) |
| unseal failures | 0 | 0 |
| NACK repairs | 8 asks → 2 frames repaired, 2 expired→IDR | quiet (1 IDR request) |
| IDR count (rate) | 110 (44/min) | **3 (1.2/min)** |
| encoder-vbv directives | **105** | 0 (disabled) |
| QP per-second avg: p50 / p95 / max | 21 / 47 / 50 | **17 / 18 / 18** |
| host fps/sec: min / p50 / p95 | 10 / 39 / 46 | 12 / 38 / 38 |
| client decoded-per-sec: p5 / p50 / p99 | 25 / 38 / 65 | 16 / 35 / 39 |
| video payload bitrate (avg) | 7.8 Mbps (wire 9.6 incl FEC+audio) | 10.7 Mbps (wire ~12.6) |
| estimator | 16 downshifts, 48 overuse verdicts, floor-crash to 500 kbps | 12 downshifts, 35 overuse verdicts |

Cadence method note: wire-view logs no per-frame presentation timestamps;
cadence is derived from the per-second cumulative decoded counts and the
host's 1 s books — per-second granularity, honestly labeled.

**Drop verdict: nothing drops on the wire.** Datagram loss is two-hundredths
of a percent and the repair machinery heals it (0 unseal failures, both
runs). Every frame the encoder emitted, the client decoded.

**Stutter verdict: the choppiness is real but supply-side, two mechanisms:**

1. **Offered load above the recipe.** At QP 16–18 this content wants
   ~41 kB × 60 fps ≈ 20 Mbps of payload — plus ~11% FEC and audio, over
   the 20 Mbps pacer budget. The pacer backs up (freshVideo max queue
   delay 296 ms, run A), capture supply adapts, and both runs plateau at
   **~38 fps, not 60**. The twin is the proof: QP pinned flat at 17,
   3 IDRs, perfectly smooth 38 fps — pleasant, just not 60. HS-22b's
   mild-band finding, reproduced without a shaper.
2. **The directive-IDR churn (findings (i)+(ii), live on an unimpaired
   path).** Run A's estimator overuse-verdicted its way down repeatedly —
   once to the 500 kbps floor (QP 50, 10 fps, 1.2 kB frames) — and every
   climb rung cost a directive + forced IDR: 105 directives / 110 IDR in
   150 s. QP sawtooths 16↔50. This is the thing an eyeball reads as
   pulsing/choppiness under motion.

### The 90 s "static" wire leg — contaminated, reported with the asterisk

78 directives / 79 IDR / QP 12↔50 in 90 s looks alarming, but the desktop
was NOT static: Chrome on pup was spawning renderers (one at 33% CPU)
during the leg — 979 damage frames ≈ 11 fps of real screen activity, and
plausibly real Wi-Fi contention from the same box. The QP-12,
pacer-20000 stretches between dips DID ride the opening recipe silently —
the clean-path silence rule held whenever the estimator was above the
boundary. For the true static-wire baseline, HS-22b leg (d) stands
(3 IDR / 335 s, 0.5/min).

## 4. Verdicts vs the trip-era complaints

- **"Blurry"** — not at this build, on the evidence: static fidelity
  clears the 50 dB visually-lossless gate (53.5 dB converged), the PSNR
  line is flat with no 1 Hz pulse, and clean-path stretches hold QP 12.
- **"Choppy"** — on an ordinary desktop, no: damage-driven frames deliver
  1:1 with zero wire loss. Under sustained heavy motion, **yes, two ways**:
  the 20 Mbps recipe caps this content at ~38 fps (smooth but not 60),
  and when the estimator dips — real weather or shared-medium contention,
  more of it in daytime — the directive-IDR climb ladder (finding (i))
  and the self-feeding crater (finding (ii)) make quality visibly
  sawtooth. Those two findings are the named owners of whatever choppiness
  remains; they were already queued for HS-22c and this probe hands them
  numbers: 105 directives / 110 IDR / QP p95 47 in 150 s of motion.
- **"Moderate quality"** — the encoder is not the limiter; QP 12–18 and
  56+ dB motion PSNR are excellent. The limiter is policy: rate churn
  under load.

## 5. Anomalies worth a look

- The estimator's final summary print shows absurd `delivery` figures
  (272,666–777,333 kbps) — cosmetic, but worth a glance at the formatter.
- Client audio strained during the heavy-motion runs: 94k underrun
  frames, pipe p99 ~193 ms, 280 PLC — the audio pipe shares the squeezed
  wire; fine on the quiet leg.
- ~38–40 fps supply ceiling under load is pacer backpressure into the
  capture loop, not encode cost — file mode does 60 fps on the same
  content at the same cap.

## 6. What still needs the owner's eyeball

Leg (e) stays open: numbers say the static/desktop path is clean and
sharp, and that heavy motion is smooth-but-38fps until the estimator
dips. Whether 38 fps reads as "choppy" at the glass, and how often the
daytime dips bite during real use, is the eyeball's call.

## Hygiene

- Secrets byte-identical start AND end: `portal_token dadf9a66…37cf`,
  `noise_static.key 72860390…cfed`, `paired_clients 8dc1f88a…55fd`.
- No netem, no reboots, no gsettings flipped (`clock-show-seconds` stayed
  `true`). Probe ffplay windows closed; only probe-started processes were
  killed. Port 41166 free at exit.
- `~/qprobe` removed (348 MB reclaimed — disk 99G used before and after);
  the Mac worktree `~/lyte-qprobe-wt` removed and pruned. Client-side
  evidence kept at `/tmp/qprobe-client{,2,3}.log` on the Mac.
- The owner's relaunch loop was DOWN when the probe began (no lyte-host
  process at 10:22) and came back up on 41151 mid-probe
  (`--wire-listen 41151 --ratchet --clipboard --seconds 7200`) — never
  touched. `~/src/hs22b-pre` left in place per the ledger's precedent.
