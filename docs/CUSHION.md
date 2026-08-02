# The Stall Cushion

*How Lyte's adaptive playout delay absorbs network weather — captured
2026-08-01, the night the Wi-Fi heisenbug was convicted and buried.
The mechanism is general: it applies to any real-time stream that
would rather pay a little latency than show a stutter.*

## The idea in one line

Schedule every frame to present at `capture + delay`, grow `delay`
instantly when a frame misses that deadline, and shrink it so slowly
during calm that nobody can feel it leaving.

A stall is only visible when a frame is not there at the moment the
glass needs it. The cushion pre-pays a small, deliberate delay so that
late frames are still *early enough*. It is not a frame buffer being
hoarded — it is a scheduling offset, and frames simply wait a few
milliseconds in the queue for their beat.

## The knobs (Lyte's values)

| Knob | Value | Meaning |
|---|---|---|
| Start | 20 ms | delay at connect, before any evidence |
| Floor | 15 ms | never decays below — the everyday jitter sponge (~1 frame at 60 fps) |
| Ceiling | 0–150 ms, user slider (default 50) | how far the delay is *allowed* to grow — permission, not payment |
| Grow | instant | `delay += max(lateness, jitter EWMA)`, capped at ceiling |
| Proof of calm | 600 punctual frames (10 s) | required before any shrink begins |
| Shrink | 0.1 ms per second | glacial drip toward the floor; one late frame resets the proof |

The whole grow/shrink core is about fifteen lines of code. The
philosophy is the asymmetry: **up like an elevator, down like a
leak** — going up you are visibly stuttering *right now*; coming down
is a luxury with no deadline.

## A walkthrough with real numbers

60 fps stream (a frame every 16.7 ms), transit normally ~3 ms,
ceiling set to **120 ms**. Track one number: `delay`.

### Connect (t = 0) — `delay = 20 ms`

A frame captured at 10.000 s arrives at 10.003 and is scheduled to
show at 10.020. It sits 17 ms in the queue on purpose. Every frame
does this — arrive early, wait, present exactly on the
20-ms-after-capture beat. Cost: 20 ms latency. Result: metronome
smoothness.

### Weather — first gust (t = 30 s), radio deaf for 90 ms

Frame F₁, captured at 30.000, should have arrived at 30.003 — the AP
holds it. It lands at 30.093 in a burst with five buffered brothers.

- F₁'s deadline was 30.000 + 20 ms = **30.020**. It arrived at
  30.093 → **73 ms late**. The glass held the previous frame those
  extra 73 ms: **one visible hitch.** That miss is the lesson.
- Grow, one step: `delay = 20 + 73 = 93 ms` (fits under the 120
  ceiling).
- The burst brothers were captured 16.7 ms apart, so their new
  deadlines fan out 30.110, 30.127, 30.143… — the backlog drains one
  per vsync and pacing is correct again within a few frames.

### Second gust (t = 41 s) — the exact same weather

Frame captured at 41.000 arrives at 41.093. Its deadline is now
41.000 + 93 ms = **41.093**. It walks in *right on time*. Lateness:
zero. **Nothing visible.** The first gust stings once; every
identical gust afterward lands inside the pocket the first one dug.

### Contrast — same storm, ceiling at 50

First gust tries to grow 20 → 93 but clamps at **50**. The second
gust arrives 90 ms after capture against a 50 ms deadline → still
**40 ms late — every gust, forever**. The ceiling, not the algorithm,
decides which storms you feel. (This is why the slider exists: the
measured Wi-Fi roam-scan deaf-windows were 75–115 ms, and the old
hard-coded 50 ms cap let every one of them break through.)

### The storm passes (t = 60 s)

Frames arrive 3 ms after capture again but present at capture +
93 ms — each waits ~90 ms in queue. Perfectly smooth, but carrying
93 ms of latency that is no longer needed.

### Calm — the descent

The policy demands **600 consecutive punctual frames** (10 s of
proof) before trusting the calm at all. Then it drips **0.1 ms per
second**, never below the 15 ms floor. From 93 down to 15 is 78 ms of
altitude ≈ **13 minutes of unbroken calm**. Glacial by design —
nobody can perceive 0.1 ms of latency leaving, so the descent is
invisible; and if one frame is late at minute 7, the proof resets and
the delay jumps straight back up by the size of the miss.

### The floor

The delay never leaks to zero on its own — 15 ms remains as the
everyday sponge, absorbing the ±2–4 ms of ordinary jitter without
ever re-teaching. About one frame's width of humility.

## The live slider

The ceiling moves mid-stream (applied on the client's 1 Hz
housekeeping tick):

- **Sliding down** clamps the learned delay immediately — set 0 and
  the next frame presents the instant it arrives (raw wire; also the
  honest A/B mode for feeling what the link really does).
- **Sliding up** grants permission, not delay — nothing changes until
  the next late frame teaches the cushion how much altitude to take.
  Raising it never adds latency by itself.

At 0 the floor and starting delay collapse with the ceiling: no delay
is ever learned, every frame shows at arrival.

## Guards at the edges

The core is simple; the subtlety lives in two guards, not the
machinery:

- **Retained frames are not evidence.** A host quality-ratchet
  re-encode carries its *original* capture timestamp; scheduling it
  against that old instant would fake a lateness episode and trigger
  a feedback loop. Repeats ride from arrival, at the current depth,
  contributing nothing to jitter.
- **Blackouts are not weather.** A genuinely compressed catch-up
  train (arrival intervals collapsing below half the source
  intervals) is a *debt* episode with its own bounded recovery
  (bounded by `arrival + ceiling`, one flush per episode) — the
  cushion never tries to "learn" a 2-second outage.

## One line to remember

One storm, one hitch, one lesson — then silence until the weather
outlasts the memory.
