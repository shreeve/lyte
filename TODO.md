# TODO — deferred work

Deferred unfinished work only; see `AGENTS.md`. Current slice and live state live in `HANDOFF.md`.

- **Wayland clipboard leaf:** replace the remaining Mutter session-bus
  dependency; capture and input are already compositor-independent.
- **Posture refinements:** an Opus DTX warm rung, DSP fades, and the 2–5
  second instant-replay ring remain demand-gated. Video cushion stays
  automatic under the Conductor; it is not deferred UI work.
- **Printing:** receive a host print job as PDF and hand it to the client's
  native print flow, with its own negotiated capability and consent.
- **Native role shells:** after the shared client-session boundary is
  IO-free, add the macOS host role, then the Windows host/client and Linux
  client shells. The Linux host already has one verified image and a coherent
  install lifecycle.
- **Browser client:** after native commissioning, bring the IO-free client
  session boundary into the already-attested WASM path, then use
  WebTransport, WebCodecs, WebGPU, and AudioWorklet through an untrusted
  browser carrier. Current direction: `docs/BROWSER.md`.
