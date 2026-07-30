# V-3 — the §7 corpus harness, and the banked 4:2:0 baseline (2026-07-29)

*H4 wave 1, slice V-3 (`docs/20260728-194226-lyte-h4-plan.md` §2): the
image-quality pillar's §7 acceptance machinery
(`docs/20260720-191701-lyte-protocol-image-quality.md`), built as a
standing instrument — the acceptance gate for 4:4:4 and the regression
guard for every later recipe change. Composes V-1's encode half
(`lyte-encode-check`, the production C leaf on pup) and V-2's client
half (`AnnexBAccessUnits` → `VideoRenderFactory` → `VideoReadbackTap`,
VideoToolbox hardware REQUIRED). Offline encode legs only: no capture,
no wire, no session, no secrets contact. Reference pair: pup (RTX 4050,
driver 595.84) encoding, M5 Mac decoding.*

## The instrument

One command, one summary block (`Host/Scripts/corpus-harness.sh`,
run from the Mac; the R5/Q-1 cannot-rot doctrine):

- **`lyte-cli corpus-gen`** — the §7 corpus as deterministic pure-Swift
  pixel math, versioned in code and **hash-frozen by gate tests** (a
  changed pin is a measurement-contract change, like a wire vector):
  (a) dense 5×7-bitmap-face terminal text, white-on-black + saturated
  syntax colors, at 100/125/200% zoom (fractional 125% via
  nearest-neighbor dst→src mapping — deterministic uneven strokes,
  like real display scaling); (b) 1-px checkerboard + seven 1-px color
  gratings; (c) 256/16-step gray + primary ramps; (d) black/white/
  primary/gray flat patches; (e) one procedural photographic frame
  (seeded value noise — natural statistics without a binary in the
  repo). 2048×1280 BGRX, the session geometry.
- **`lyte-encode-check --static 240`** on pup — the shipped recipe
  (sessionDefault p4, capped-CQ cq12 / cap 50 Mbps), per chroma leg:
  420 = today's path; 444 = `--profile rext --rgb-mode yuv444`, the
  owner-decision-2 posture. Per-frame size books ride along.
- **`lyte-cli decode-probe --pixel-format bgra --require-hardware
  --dump-frames 0,59,last`** — V-2's tap grew a frame selector: the
  cold IDR (frame 0), the active phase 1 s into the walk (frame 59),
  and the post-ratchet plateau (frame 239), instead of a 2.5 GB dump.
- **`lyte-cli corpus-gate`** — the §7 math with **thresholds pinned in
  code** (`CorpusGates`, test-pinned): text-region RGB PSNR
  (per-channel min) ≥ 40 dB active / ≥ 50 dB post-ratchet; SSIM ≥
  0.995 post-ratchet on (a)–(c); grating edges ≤ ±2 codes; range
  patches byte-exact +1 code under the shipped `limited601` posture
  (owner decision 2's ruling verbatim: byte-exact is NAMED-AND-QUEUED
  with the full-range row — the raw deltas stay reported); ratchet
  convergence ≤ 180 frames (3 s) from the encoder's size books, with
  a ±⅛ keepalive-hover tolerance (natural content wiggles a few bytes
  at converged QP — measured on the photo frame, gate-tested);
  visual goldens diffed (non-empty diff = human looks, never a silent
  absorb).
- **Goldens**: decoded post-ratchet PNGs of corpus (a), committed at
  `Goldens/corpus/` for BOTH chroma legs (the 444 set is the offline
  rgb_mode path — V-4's Work mode diffs against it). *(Moved to
  `Tests/goldens/corpus/` 2026-07-30 — owner tidy; the harness's
  `GOLDEN_DIR` moved with it.)*

Modes: the 420 leg runs `--mode baseline` — same math, REF rows, never
fails (the pillar's "4:2:0 recorded alongside" rule); the 444 leg runs
`--mode work` and ENFORCES. Root suite grew 8 gate tests (corpus
freeze pins, threshold pins, damage-detection proofs, golden
round-trip, convergence-detector books).

## The banked table (both legs, one run)

```
=============== LYTE §7 CORPUS HARNESS — 2026-07-29 @ e98c686 ===============
recipe: sessionDefault (p4) capped-CQ cq12 / cap 50 Mbps, static x240 @ 2048x1280
encode: pup production C leaf · decode: VideoToolbox HARDWARE (required) · math: pinned in code
frame      chroma idr-dB act@1s-dB/conv-dB   text a/c dB  white/syn dB     SSIM     special    cv   idr/keep B golden verdict
text-100   420    16.25     19.91/19.91     19.65/19.65   46.43/16.65  0.97425           -  cv37    578146/98  clean REF
text-125   420    16.24     19.76/19.76     19.45/19.45   45.21/16.44  0.97734           -  cv36   490225/113  clean REF
text-200   420    17.34     23.09/23.09     22.83/22.83   46.79/19.83  0.97090           -  cv36   302845/106  clean REF
gratings   420     6.15      6.15/6.15                -             -  0.89507 grating ±255  cv13   101691/101      - REF
gradients  420    37.56     37.56/37.56               -             -  0.99685           -   cv4     8321/129      - REF
patches    420    36.25     36.25/36.25               -             -        -   patch ±2   cv1      1148/95      - REF
photo      420    45.25     45.27/45.27               -             -        -           -   cv5    84542/929      - REF
text-100   444    15.72     42.00/42.00     41.74/41.74   46.35/39.56  0.99990           -  cv55    479778/95  clean FAIL
text-125   444    15.46     42.42/42.42     42.11/42.11   46.18/40.05  0.99981           -  cv52   393014/143  clean FAIL
text-200   444    17.79     44.54/44.54     44.28/44.28   46.76/42.71  0.99953           -  cv49   290222/120  clean FAIL
gratings   444    46.39     46.44/46.44               -             -  0.99995 grating ±5  cv13   111381/101      - FAIL
gradients  444    49.68     49.71/49.71               -             -  0.99932           -   cv5    10586/114      - PASS
patches    444    48.11     48.12/48.12               -             -        -   patch ±2   cv2      1218/95      - PASS
photo      444    45.21     45.29/45.29               -             -        -           -   cv7    86994/931      - PASS
bars: text ≥40 active(@1 s) / ≥50 conv (per-ch min) · SSIM ≥0.995 · gratings ≤±2 · patches exact+1 (limited601, owner decision 2;
      byte-exact named-and-queued) · converge ≤180 fr · cold IDR reported unmetered (VBV posture, the ratchet heals it)
420 rows are the REFERENCE (recorded alongside, gates never fail it — gratings CANNOT pass there, which is the point)
offline scope: live-ratchet halves (zero frames post-convergence, bytes ≤ surplus) wait for V-4/J-G4a
verdict: 420 PASS · 444 FAIL   (logs: /tmp/corpus-harness/gates-*.log, encode-*.log)
==============================================================================
```

(text a/c = pooled text-region per-channel-min PSNR, active/converged;
white/syn = the white-on-black vs saturated-syntax split, converged;
cv = convergence frame; idr/keep B = opening IDR / keepalive bytes.
act@1s equals conv on this corpus because the walk plateaus before
frame 59 and post-convergence keepalives are all-skip — the decoded
frames are bit-identical, itself a measurement.)

## The 4:4:4-vs-baseline delta, measurable today

**The headline the wave was chartered for is now a number.** Same
corpus, same recipe, same silicon, the only change `--profile rext
--rgb-mode yuv444`:

- **Text (pooled region, converged): 19.5–22.8 dB → 41.7–44.3 dB
  (+19.6 to +22.2 dB).** The split says why: white-on-black glyphs are
  luma and already sit at ~46 dB under 4:2:0; the saturated syntax
  block is chroma and 4:2:0 murders it (16.4–19.8 dB) while 4:4:4
  carries it at 39.6–42.7 dB (+23 dB). Crisper still: 4:4:4 spends
  FEWER bits doing it (IDR 480 KB vs 578 KB on text-100 — chroma
  subsampling wasn't even saving bytes on this content).
- **Gratings: ±255-code garbage → ±5 codes; SSIM 0.895 → 0.99995.**
  The 1-px chroma gratings are literally unrepresentable at 4:2:0
  (whole-region failure, 262,656/262,656 px beyond the bar); at 4:4:4
  the worst channel error is 5 codes.
- **Photo: 45.27 vs 45.29 dB — a wash**, exactly as the pillar
  predicts: Play mode loses nothing by staying 4:2:0.
- **Ratchet posture holds at 4:4:4**: convergence cv49–55 on text
  (≤ 1 s, bar is 180), keepalives 95–143 B (same class as 4:2:0's),
  cold-IDR mass within the V-1 Q4 distribution.

## What the gates say about today's recipe (V-4's homework, with numbers)

The 444 leg **fails two §7 bars, and both failures are the cq12
floor, not the chroma path**:

1. **text-psnr-converged 41.7–44.3 dB vs ≥ 50**: even the pure-luma
   white block converges at 46.3–46.8 dB — QP 12 caps this corpus
   below 50 dB regardless of chroma. The capped-CQ floor (`cq12`) is
   the shipped Play posture; the pillar's 50 dB post-ratchet bar
   effectively asks Work mode's ratchet to walk BELOW it (or to the
   pillar's alternative, byte-identical glyph rows). That is a
   one-knob recipe decision (Work-specific cq / qmin floor) that
   belongs to V-4, which now has the exact before-number.
2. **gratings ±5 vs ≤ ±2**: 3.8–9.4% of grating pixels sit beyond ±2
   at QP 12 (the 601-limited quantization contributes ~±1; the rest is
   codec residual on the hardest possible content). Same lever.

Passing today at 4:4:4: SSIM (all three kinds), range patches under
the decision-2 posture (max ±2 = the +1 allowance boundary; raw
byte-exact deltas: white ±1, red ±2 — identical at 4:2:0, so this is
the 601-limited round trip's floor, not a 4:4:4 regression),
convergence, active-phase text ≥ 40.

**Deliberate gate shapes** (pinned in code, argued here once):
- *Active phase* is measured 1 s into the static walk (frame 59), not
  at the cold IDR — frame 0 is VBV-constrained by design (15–18 dB on
  BOTH chromas; the HS-25/decision-3 posture) and is reported
  separately as `idr-dB`, unmetered: the ratchet heals it and J-G4a's
  live leg owns the input→photon consequence.
- *Range gate* implements owner decision 2's ruling verbatim:
  `--range-posture limited601` allows +1 code and prints the
  named-and-queued line; `--range-posture full` keeps the pillar's
  byte-exact bar for the day the full-range row lands.
- *Convergence* tolerates the ±⅛ keepalive hover natural content
  shows at converged QP (photo: 923–934 B forever); synthetic frames
  remain byte-identical and the detector still flags any real
  excursion (gate-tested both ways).

## What waits for V-4/J-G4a (stated once, honestly)

- The live-session ratchet halves: **zero frames sent after
  convergence** and **ratchet bytes ≤ the congestion sibling's
  surplus** — need a Work-mode wire session (V-4's mode plumbing),
  land at J-G4a.
- The end-to-end negotiated path (chroma `[444]` declaration → session
  branches → VUI assert client-side) — V-4/V-5; the harness measures
  the same silicon offline today.
- The delta table above is offline-static; J-G4a re-runs the harness
  gates END-TO-END live and publishes the shipping delta table.

## Determinism, hygiene, suites

- **Rerunnability proven**: a full independent re-run (fresh corpus
  gen → pup encode → VT decode → PNG) diffed **clean against all six
  committed goldens** — encoder, hardware decoder, and PNG round trip
  are deterministic end-to-end. The goldens are honest regression
  tripwires.
- Corpus frozen by FNV-64 pins in `CorpusHarnessGateTests`; PNG
  round-trip byte-exactness gate-tested; thresholds test-pinned.
- Hygiene: offline only — the owner's 41151 loop untouched, no
  secrets contact by construction, pup work dir (`~/corpus-harness`,
  ~73 MB corpus + bitstreams) removed by the script's default
  cleanup; Mac artifacts under `/tmp/corpus-harness/` (scratch:
  summary.txt, gates-/encode- logs, decoded dumps).
- Suites at the V-3 tree: root **175/175** Mac (167 + 8 new gates);
  Host **180/180 Mac AND pup** (Host code untouched — scripts only);
  Wire untouched.
