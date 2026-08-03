# The Metronome Playout — video presentation on the beat

**Status: ADOPTED 2026-08-03 (owner design session). Owns the standing
red cell (client presentation lateness p99 ~18 ms vs the 8 ms bar,
measured by the #82 witness) and A-20's quality mandate. Implementation
is the direct-leg quality refinement PR.**

## The five laws

```
anchor  = host_capture_grid  +  path_delay_p99  +  cushion_frames × 16.667ms
display = at every vsync beat, present the newest frame whose time has come
late    = decode always, display never (its beat has passed)
dry     = hold last frame; re-anchor +1 beat; refill happens on its own
drift   = one scheduled beat-slip when cushion leaves its band
```

Every frame that ever reaches the glass lands on a beat. No frame is
ever presented off-grid. The cushion breathes; the cadence never does.

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

## Law-by-law notes

- **anchor** — size the cushion from the measured path-delay TAIL
  (p95/p99), never the mean: a cushion sized off the average stutters
  once a second at 60 fps. Path delay per frame is already measured
  (`arrival − mappedCapture`).
- **display** — quantize presentation to the vsync grid with ~half a
  beat of bias so rounding works for us, not against us. At each beat
  present the newest frame whose time has come; older undisplayed
  frames retire silently.
- **late** — video frames are references: a late frame always enters
  the decoder (frame N+1 is built on it); it just may never be shown.
  Skip display, never decode.
- **dry** — an empty cushion means the glass holds the last frame
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
