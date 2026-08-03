# THE CONDUCTOR — one score, one clock, many instruments, everything on the beat

**Status: ADOPTED 2026-08-03 (owner design session; the Conductor term
and the law names are the owner's — use them verbatim). The model is
medium-agnostic: audio already lives it (jitter buffer = cushion,
lattice = score, recenter = re-cue); video adopts it via the metronome
playout below, which owns the standing red cell (client presentation
lateness p99 ~18 ms vs the 8 ms bar, measured by the #82 witness) and
A-20's quality mandate. Video's part LANDED (#83, 2026-08-03,
VideoBeatConductor): the witness's verdict went PASS with
presentation gap p50 = p95 = p99 = 16.667 ms exactly and steady
lateness p99 0.4–4.6 ms — the red cell is green. Remaining tiers:
audio migrates onto the shared primitives; LyteCore convergence in
v2; rubato stays filed.**

## The vocabulary

- **The score** — the host's capture timeline, stamped on every part
  at birth. The music as authored. The host writes it; the client
  only performs it — the Conductor never rewrites the score.
- **The conductor** — the client's clock, disciplined to the score
  through HostClockModel (sub-millisecond residuals).
- **The instruments** — audio, video, and whatever media come later.
  Each plays its own part with its own packet sizes, timings, and
  verbs, but nobody plays off the beat.
- **The cushion** — the parts held in reserve, quantized in beats.
- **Rubato** — audio's superpower: pitch-preserving time-stretch
  (WSOLA), the one instrument allowed to bend tempo, provided it
  lands back on the conductor's beat. (Future work — see the audio
  refinement section.)

Because every instrument cues from the SAME score, A/V sync stops
being an accident and becomes a law.

## The six laws

```
cue   = score + path_delay_p99 + cushion × beat_period
beat  = at every beat, play the newest part whose time has come
late  = ingest always, play never (its beat has passed)
hole  = cushion empty: video holds, audio conceals; re-cue +1 beat, once
slip  = one scheduled beat-slip when the cushion leaves its band
chain = parts may depend on parts — chained parts are always
        ingested even when their beat is lost
```

The cue in one sentence: *the score, plus the time it takes the parts
to reach us, plus the cushion we hold in reserve.*

Every part that ever reaches the glass or the speaker lands on a
beat. Nothing is ever played off-grid. The cushion breathes; the
cadence never does.

## Per-instrument verbs

| Law | Audio (the ear needs continuity) | Video (the eye needs punctuality) |
|---|---|---|
| beat | play the next 5 ms slice at the DAC pull | show the newest ready frame at vsync |
| late | today: drop; future: bend it back on-beat (rubato) | hold the last frame — free, invisible |
| hole | conceal (PLC), declick to silence after grace | no enqueue = no change |
| chain | at the decoder: Opus prediction state — feeding late parts keeps the next decode clean | reference chains — decode always |

## Why (the finding that forced it)

The #82 quality witness measured the client presenting frames with a
clean 16.69 ms p50 gap but an 18 ms p99 lateness and ~23 ms p99 gap —
a visible micro-stutter the owner independently observed on the glass.
Transport is not the cause (stretch p99 ≈ 6 ms); the host's cadence is
clean. The artifact is the playout policy: `AdaptiveVideoPlayout`
schedules `capture + targetDelay` but lets any frame that misses its
slot present AT ARRIVAL (`max(..., arrivalMicroseconds)`), and its
target delay decays to a 15 ms floor that leaves no headroom for the
measured tail. The display then rounds off-grid schedules to vsync,
turning ±1 ms of wobble into whole skipped beats.

This is the push model's classic low-latency compromise. It was the
right bias when the pipeline fought 100 ms problems; with the wire
healthy it is now the dominant remaining artifact.

## The model (industry standard, with a better clock)

The pull model: the display is the metronome; frames serve the beat.
WebRTC calls it the video jitter buffer + playout delay; game
streaming clients call it frame pacing; every audio stack since the
90s works this way — including Lyte's own audio path (target depth +
recenter). Video joins the pattern it already trusts.

Lyte's edge over the generic implementations: both endpoints are
ours, both run at a locked 60 Hz, and HostClockModel maps the score
with sub-millisecond residuals — so the conductor cues directly from
the score instead of statistically inferring it, and the cushion can
stay tighter for the same smoothness.

## Law-by-law notes (video's part)

- **cue** — size the cushion from the measured path-delay TAIL
  (p95/p99), never the mean: a cushion sized off the average stutters
  once a second at 60 fps. Path delay per frame is already measured
  (`arrival − mappedCapture`).
- **beat** — quantize presentation to the vsync grid with ~half a
  beat of bias so rounding works for us, not against us. At each beat
  present the newest frame whose time has come; older undisplayed
  frames retire silently.
- **late** — video frames are chained: a late frame always enters
  the decoder (frame N+1 is built on it); it just may never be shown.
  Skip the beat, never the ingest.
- **hole** — an empty cushion means the glass holds the last frame
  (no enqueue = no change, visually free). The refill is ONE
  deliberate re-cue (+1 beat), not per-frame smearing: one scheduled
  hiccup instead of ten random ones. Audio calls this a recenter.
- **slip** — pup's 60.0007 Hz and the client display's 60 Hz are
  different crystals; the grids part by a frame over minutes. When
  the cushion leaves its band, do one scheduled beat-slip (show a
  frame twice / retire one unshown) — "controlled slip" is the
  telecom term of art for exactly this move. A metronome that hiccups
  once every five minutes on purpose beats one that wobbles every
  second by accident.

## Audio refinement (filed, not scheduled): the late part's afterlife

Today audio drops late packets outright (`latePacketsDropped`) and
conceals with Opus PLC. A late audio part actually has three uses,
ranked by psychoacoustic value:

1. **FEC heal** (we do this) — RS-FEC rebuilds the loss before the
   buffer ever sees a hole; a healed loss costs nothing.
2. **Late-but-bent** (future: rubato) — play the late part
   time-compressed (~1.05×, WSOLA pitch-preserving) to rejoin the
   beat; the ear barely notices ±5% tempo but always notices a click.
   NetEQ-style accelerate/expand. Also: crossfade the PLC seam when
   the real part arrives mid-conceal, and feed late parts to the
   decoder for prediction-state continuity (audio's chain law).
3. **PLC extrapolation** (we do this) — synthetic continuation;
   excellent under ~20 ms, degrades gracefully to ~100 ms.
4. **Declicked fade to silence** (we do this) — honest quiet.
5. **Zeros / raw click** — never acceptable; we never do this.

## Standardization — three tiers, no massive rewrite

The Conductor converges audio and video on shared plumbing by
REPLACEMENT, never by big-bang rewrite — the direct-eye playbook
(build the new path alongside, flip, then demolish the old; E5 is
the precedent) applied to timing:

1. **Now (this doc): one vocabulary, one set of laws.** The six laws
   are the model of record for every medium; instruments differ only
   in verbs and constants.
2. **Shared primitives — DONE (#86, 2026-08-03,
   ConductorPrimitives.swift).** What proved literally identical and
   was extracted: the tail ring (`BeatTailRing` — video's private
   p99 estimator retired for it), the proof-before-shed law
   (`ProofCounter` — video's slip proof and audio's decay
   hold/step/retarget cadence were one law spelled four ways),
   audio's private copy of the 5 ms beat constant (now the wire's),
   and `LatencyHistogram`'s home (moved out of InputSender.swift).
   What measured DIFFERENT and stays by doctrine: audio's clock of
   record is the DAC, never HostClockModel (the ear forgives slow
   drift, never a click — lattice detrend, not stamp mapping), and
   audio sizes its cushion from the detrended window SPREAD, not a
   percentile (the former p99 discarded exactly the late/PLC
   events; a measured fix). Both instruments' full pin suites
   passed unchanged across the migration — nothing moved.
3. **v2 (`Common/Core` → `LyteCore`, per the v2 rulings): the
   Conductor becomes a real shared module.** Laws and primitives in
   LyteCore (sans-IO, injected time, WASM-buildable); each instrument
   implements its verbs. This is A-26's landing zone and the owner's
   standing directive: find the common themes, build clean unifying
   data structures — optimized, efficient, flexible enough to reuse
   and profile — then retire the old code path by path. The effect of
   a rewrite, without ever performing one.

## The cushion is the user's dial

Depth is quantized in beats — every setting stays perfectly on-beat;
only latency changes:

| cushion | added latency | posture |
|---|---|---|
| 1 beat | ~17 ms | fast (interactive default candidate) |
| 2 beats | ~33 ms | smooth |
| 3 beats | ~50 ms | silk (movie-watching) |

Today's measured tail (~1 beat) is covered by 1–2 beats.

## Acceptance (the witness proves it)

`Scripts/benchmark-app.sh motion` on the 60 Hz rig:
- presentation gap p99 → ~16.7 ms (from ~23 ms)
- steady presentation lateness p99 → < 8 ms (from ~18 ms; bar green)
- fidelity/fps/churn cells stay green (30.8 dB / 0.999 / ~60 fps / 0 IDR)

Never massage a red cell: if the conductor cannot hold the beat, that
is a finding, not a rounding choice.
