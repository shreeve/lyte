# TODO — deferred work, deliberately

*Small items we chose not to block on. Each entry says where it lives and why
it was deferred, so the next touch of that code picks it up naturally.*

## Headroom learning (`Sources/Lyte/ConnectionModel.swift`, `HostHeadroom`)

- **`recordClean` needs a minimum session duration.** Today a 15-second clean
  connect earns the same 10% ceiling raise as an hour of streaming, so a burst
  of short sessions can re-inflate a ceiling the network genuinely can't
  sustain. Add a duration floor (e.g. only sessions longer than ~60s teach
  anything) when next touching the headroom code. (From the 2026-07-20 review
  of the M5.5 seed commit `762efc7`.)

## Input capture (`Sources/LyteUI/InputCapture.swift`)

- **`videoSize` should come from the decoded stream, not the request.** It is
  currently set from policy (requested) dimensions in `StreamView`. Sunshine
  honors the requested resolution in practice, but the robust source is the
  video format description the decoder actually produces — if a host ever
  negotiates a different size, the absolute-mouse aspect-fit mapping would be
  subtly off. Wire the decoded dimensions through when next touching the video
  or input path. (Same review, commit `214dabe`.)
