# TODO — deferred work

Deferred unfinished work only; see `AGENTS.md`. Current slice and live state live in `HANDOFF.md`.

- **Wayland clipboard leaf (blocked on GNOME):** shipping host clipboard
  still requires Mutter RemoteDesktop session bus
  (`MutterClipboardLeaf`). Pup pin 2026-08-07 (GNOME Shell 50.1 /
  Mutter 50.1): no `wlr-data-control` / `ext-data-control`;
  `wl-copy`/`wl-paste` hang; portal Clipboard cannot Start headless
  (CP-5 Q1 reconfirmed). Unlock conditions and probes:
  `docs/20260807-015743-wayland-clipboard-gnome-blocker.md`.
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
