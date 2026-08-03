# THE CONDUCTOR — one clock, many instruments, everything on the beat

**Status: ADOPTED 2026-08-03 (owner design session; law names and the
Conductor term are the owner's). The model is medium-agnostic: audio
already lives it (jitter buffer = cushion, lattice = anchor, recenter
= re-anchor); video adopts it via the metronome playout below, which
owns the standing red cell (client presentation lateness p99 ~18 ms
vs the 8 ms bar, measured by the #82 witness) and A-20's quality
mandate. Implementation is the direct-leg quality refinement PR.**

One conductor — the receiver's clock, disciplined to the host's
capture grid through HostClockModel — and many instruments: audio,
video, and whatever media come later. Each instrument plays its own
part with its own packet sizes, timings, and verbs, but nobody plays
off the beat. Because every instrument anchors to the SAME grid, A/V
sync stops being an accident and becomes a law.

## The six laws

```
anchor       = host_capture_grid + path_delay_p99 + cushion × beat_period
beat         = at every beat, play the newest part whose time has come
miss         = ingest always, play never (its beat has passed)
hole         = cushion empty: video holds the frame, audio conceals;
               re-anchor +1 beat, once — refill happens on its own
drift        = one scheduled beat-slip when cushion leaves its band
entanglement = parts may depend on parts (video frames reference,
               audio packets are free) — entangled parts are always
               ingested even when their beat is lost
```

Every part that ever reaches the glass or the speaker lands on a
beat. Nothing is ever played off-grid. The cushion breathes; the
cadence never does.

## Per-instrument verbs

| Law | Audio (the ear needs continuity) | Video (the eye needs punctuality) |
|---|---|---|
| beat | play the next 5 ms slice at the DAC pull | show the newest ready frame at vsync |
| miss | conceal (PLC), declick toward silence | hold the last frame — free, invisible |
| hole | synthesize; silence after grace | no enqueue = no change |
| entanglement | none — Opus packets + FEC stand alone | reference chains — decode always |

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
ours, both run at a locked 60 Hz, and HostClockModel maps the host
capture clock with sub-millisecond residuals — so the metronome
anchors directly to the host's capture grid instead of being
statistically inferred, and the cushion can stay tighter for the
same smoothness.

## Law-by-law notes (video's part)

- **anchor** — size the cushion from the measured path-delay TAIL
  (p95/p99), never the mean: a cushion sized off the average stutters
  once a second at 60 fps. Path delay per frame is already measured
  (`arrival − mappedCapture`).
- **beat** — quantize presentation to the vsync grid with ~half a
  beat of bias so rounding works for us, not against us. At each beat
  present the newest frame whose time has come; older undisplayed
  frames retire silently.
- **miss** — video frames are entangled: a late frame always enters
  the decoder (frame N+1 is built on it); it just may never be shown.
  Skip the beat, never the ingest.
- **hole** — an empty cushion means the glass holds the last frame
  (no enqueue = no change, visually free). The refill is ONE
  deliberate re-anchor (+1 beat), not per-frame smearing: one
  scheduled hiccup instead of ten random ones. Audio calls this a
  recenter.
- **drift** — pup's 60.0007 Hz and the client display's 60 Hz are
  different crystals; the grids part by a frame over minutes. When
  the cushion leaves its band, do one scheduled beat-slip (show a
  frame twice / retire one unshown). A metronome that hiccups once
  every five minutes on purpose beats one that wobbles every second
  by accident.

## Standardization — three tiers, no massive rewrite

The Conductor converges audio and video on shared plumbing by
REPLACEMENT, never by big-bang rewrite — the direct-eye playbook
(build the new path alongside, flip, then demolish the old; E5 is
the precedent) applied to timing:

1. **Now (this doc): one vocabulary, one set of laws.** The six laws
   are the model of record for every medium; instruments differ only
   in verbs and constants.
2. **The metronome-playout PR: extract the primitives that are
   literally identical** — the anchor math (HostClockModel is already
   shared), the tail estimator (path-delay p99), the cushion-band
   governor (depth target, re-anchor, drift slip). Audio's buffer
   migrates onto them without behavior change; its existing test pins
   prove nothing moved.
3. **v2 (`Common/Core` → `LyteCore`, per the v2 rulings): the
   Conductor becomes a real shared module.** Laws and primitives in
   LyteCore (sans-IO, injected time, WASM-buildable); each instrument
   implements its verbs. This is A-26's landing zone and the owner's
   standing directive: find the common themes, build clean unifying
   data structures — optimized, efficient, flexible enough to reuse
   and profile — then retire the old code path by path. The effect of
   a rewrite, without ever performing one.

## The cushion is the user's dial

Depth is quantized in frames — every setting stays perfectly on-beat;
only latency changes:

| cushion | added latency | posture |
|---|---|---|
| 1 frame | ~17 ms | fast (interactive default candidate) |
| 2 frames | ~33 ms | smooth |
| 3 frames | ~50 ms | silk (movie-watching) |

Today's measured tail (~1 beat) is covered by 1–2 frames.

## Acceptance (the witness proves it)

`Scripts/benchmark-app.sh motion` on the 60 Hz rig:
- presentation gap p99 → ~16.7 ms (from ~23 ms)
- steady presentation lateness p99 → < 8 ms (from ~18 ms; bar green)
- fidelity/fps/churn cells stay green (30.8 dB / 0.999 / ~60 fps / 0 IDR)

Never massage a red cell: if the metronome cannot hold the beat, that
is a finding, not a rounding choice.
