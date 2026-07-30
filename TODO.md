# TODO — deferred work, deliberately

*Small items we chose not to block on. Each entry says where it lives and why
it was deferred, so the next touch of that code picks it up naturally.
(Slice-level deferred seams — VBV, repair-lane DSCP, cookie-mode
enforcement, M7 audio items, promotion slices — are tracked in `HANDOFF.md`
and the build plan, not here.)*

## Browser client + Caddy bridge (`docs/20260720-184200-browser-client-caddy-bridge.md`)

- **Post-H6 plan of record, deliberately parked.** Same Swift client protocol
  layer compiled to WASM (WebCodecs decode), reaching lyte-host through a
  Caddy module — simplified by the 2026-07-20 Lyte-UDP decision to a **dumb
  WebTransport-datagram ↔ UDP-packet relay** (CONNECT-UDP / RFC 9298 shape);
  the host-side protocol is Lyte-UDP, not GameStream, and E2E Noise keeps the
  bridge untrusted. Pick up only after the native path runs flawlessly.
  (Design consult 2026-07-20; amended per
  `docs/20260720-215100-lyte-udp-decision.md`.)

## `lyte sniff` — the key-joined decrypt half (future)

- **Mostly done.** `lyte-host sniff` (HS-5, `Host/Sources/lyte-host/Sniff.swift`)
  has pretty-printed envelopes/channels for waves. What remains is the half
  its header explicitly defers: joining a session key so payloads decrypt —
  today it dissects headers only, with Noise blinding the cargo. Pick up if
  a debugging season ever needs plaintext on the wire.
  (`docs/20260720-215100-lyte-udp-decision.md` §7.)

---

*Retired 2026-07-22 (the H2 demolition made them moot): the GameStream
stack deletion (done — commits `2018f6d`/`d5de430`), headroom-learning
duration floor (`HostHeadroom` deleted with the GameStream recents), and
the old `InputCapture.videoSize` provenance note (the deleted GameStream
capture; the Lyte path's `LyteInputCapture` takes its size from the
decoded stream's format description already).*
