# TODO — deferred work, deliberately

*Small items we chose not to block on. Each entry says where it lives and why
it was deferred, so the next touch of that code picks it up naturally.
(Slice-level work is tracked in `HANDOFF.md` and the build plan, not here.)*

## Audit-sweep verification caveats (2026-07-30, post-REMAINING.md)

*The 19-PR audit sweep (#1–#19) landed and was verified end to end by a
five-agent read pass plus all four suite legs; REMAINING.md was then
retired. These are the advisory findings that pass surfaced — none are
live bugs; each is armed only by a future change to its seam.*

- **VideoAssembler threshold invariant** (`Wire/Sources/LyteWire/VideoAssembler.swift`,
  walk early-out in `sweepLossPresumption`) — the early-out compares absent
  slots against `reorderThresholdPackets` only, while write-off uses
  `fecImpossibleThresholdPackets`; safe only while
  `fecImpossible >= reorder`. Every in-tree config satisfies it, but
  `VideoAssemblerConfig.init` accepts an inverted pair, which would skip a
  group forever and suppress its `fecImpossible` report. Next touch: use
  `min(reorder, fecImpossible)` in the early-out, or assert the invariant.
  Also: PR #10 shipped source-only — `sweepSettled`, `contiguousPrefix`,
  and the `seqAdvanced || openedGroup` gate have no dedicated pins.

- **encode() `-2` resend path** (`Host/Sources/lyte-host/main.swift`) —
  `encode(data: nil)` consumes the forced-IDR demand *before* the send, so
  a `-2` (nothing retained) return would silently drop it. Unreachable
  today (one encoder per Sink lifetime ⇒ `framesIn > 0` implies retained);
  becomes a real trap if encoder re-open / resolution renegotiation is ever
  added. Fix shape: take the demand after the `-2` check, or re-arm on `-2`.

- **ARQ PTO sleep-forever guard has no pin**
  (`Sources/LyteTransport/ReliableCtrlEndpoint.swift`, `timerFired()`
  clearing `armedDeadlineMicros` before service) — the only sweep change
  whose correctness invariant is held by code + comment alone. Worth a
  virtual-time pin next time that file is open.

- **Residual under-lock prints** (`Host/Sources/lyte-host/SessionWire.swift`) —
  PR #8 buffered the 48 event-log lines, but a few rare paths still print
  while the session lock is held: the `flushOutbox` path-challenge lines,
  `notePeerGone`, `driveBulkShell`'s bulk-send failure, and `awaitClient`'s
  connect-failed line. A wedged stdout can still block the wire through
  those; route them through `emit` on the next touch.

- **FROZEN exit one-beat deferral** (`Sources/LyteTransport/LyteUdpSession.swift`) —
  a datagram landing inside the exact `applyMachine` critical section that
  enters FROZEN reads `machineFrozen == false`, skips the immediate exit,
  and is delivered by the next beat instead (≤100 ms in production;
  lossless — the atomic stamp retains it). Bounded and by design, but
  "datagram-immediate FROZEN exit" carries that one caveat.

- **quality-probe unwritten grep dependencies** (`Host/Scripts/quality-probe.sh`
  ↔ `WireViewCommand.swift`) — beyond the documented item-19 contract,
  `parse_wire` also relies on the final summary block being the *last*
  `render:`/`wire:` lines in the client log, and on `head -1` winning a
  same-line second `delivery …` match in the host log. Inserting a clause
  after `missing` or adding a later `render:` line rots the greps without
  violating the written contract; fold these into the annotations on the
  next probe touch.

*Still owed live (not code): watch #6's `rate: fall purge` line and #16's
`hole-recused` count on the next evening-air session; optional rtprio
grant on the host machine (`Host/README.md` prerequisites item 3); ⌘W a
live stream window (PR #25) and watch for the host's peer-goodbye line +
awdl0 release; a live monitor-mode change mid-session (PR #24) should now
end in a typed teardown, not a crash — worth one deliberate flip.*

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
