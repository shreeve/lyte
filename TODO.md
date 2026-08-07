# TODO — deferred work

Deliberately deferred, actionable work only. Current slice and live
verification state belong in `HANDOFF.md`; settled decisions belong in
`AGENTS.md` or `docs/`; completed work belongs in Git history — never leave
“done” narrative here.

## Verification debt

- **Residual under-lock diagnostics**
  (`Host/Sources/lyte-host/SessionWire.swift`): move the remaining rare
  path-challenge, peer-gone, bulk-send-failure, and connect-failed prints
  through the buffered emitter when this seam is next open.

The closed 2026-07-30 analysis ledger is at `git show 860369a:ANALYSIS.md`;
it is not active backlog.

## Product backlog

- **Printing:** receive a host print job as PDF and hand it to the client's
  native print flow, with its own negotiated capability and consent.
- **Wayland clipboard leaf:** replace the remaining Mutter session-bus
  dependency; capture and input are already compositor-independent.
- **Posture refinements:** an Opus DTX warm rung, DSP fades, and the 2–5
  second instant-replay ring remain demand-gated. Video cushion stays
  automatic under the Conductor; it is not deferred UI work.
- **Native role shells:** after the shared client-session boundary is
  IO-free, add the macOS host role, then the Windows host/client and Linux
  client shells. The Linux host already has one verified image and a coherent
  install lifecycle.
- **Browser client:** after native commissioning, bring the IO-free client
  session boundary into the already-attested WASM path, then use
  WebTransport, WebCodecs, WebGPU, and AudioWorklet through an untrusted
  browser carrier. Current direction: `docs/BROWSER.md`.
