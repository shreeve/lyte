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

## Browser client + Caddy bridge (`docs/20260720-184200-browser-client-caddy-bridge.md`)

- **Post-H6 plan of record, deliberately parked.** Same Swift client protocol
  layer compiled to WASM (WebCodecs decode), reaching lyte-host through a
  Caddy module — simplified by the 2026-07-20 Lyte-UDP decision to a **dumb
  WebTransport-datagram ↔ UDP-packet relay** (CONNECT-UDP / RFC 9298 shape);
  the host-side protocol is Lyte-UDP, not GameStream, and E2E Noise keeps the
  bridge untrusted. Pick up only after the native path runs flawlessly.
  (Design consult 2026-07-20; amended per
  `docs/20260720-215100-lyte-udp-decision.md`.)

## Client GameStream stack deletion (`Sources/` protocol layer)

- **Delete the frozen GameStream scaffolding once Lyte-UDP is load-bearing.**
  Per the 2026-07-20 Lyte-UDP decision the client's GameStream stack is
  frozen scaffolding — zero new work — kept compiling only as the working
  path against Sunshine during the transition. Delete it when the Lyte-UDP
  client path streams the desktop end-to-end (H0b/H1 target), at the absolute
  latest at H2 parity; uninstall Sunshine from `pop` at the same moment.
  Deletion is the default, not a decision point — git history preserves it.
  (`docs/20260720-215100-lyte-udp-decision.md`.)

## `lyte sniff` debug tool (future `Host/` or shared tooling)

- **Build a small wire dissector for Lyte-UDP, eventually.** Dropping the
  GameStream dialect means Wireshark understands nothing on our wire (and
  E2E Noise would blind it anyway). A `lyte sniff` mode that joins a session
  key and pretty-prints envelopes/channels is the recorded mitigation — not
  needed for H0b, wanted before the protocol surface grows past H2.
  (`docs/20260720-215100-lyte-udp-decision.md` §7.)

## Input capture (`Sources/LyteUI/InputCapture.swift`)

- **`videoSize` should come from the decoded stream, not the request.** It is
  currently set from policy (requested) dimensions in `StreamView`. Sunshine
  honors the requested resolution in practice, but the robust source is the
  video format description the decoder actually produces — if a host ever
  negotiates a different size, the absolute-mouse aspect-fit mapping would be
  subtly off. Wire the decoded dimensions through when next touching the video
  or input path. (Same review, commit `214dabe`.)
