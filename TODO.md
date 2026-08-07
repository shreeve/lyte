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
- **Browser client (active platform slice):** B-0…B-5 landed (`Browser/`,
  `docs/BROWSER.md`): Chrome WASM contracts, WT carrier, control session,
  and sealed corpus Conductor video (binary media ingest; FEC assemble →
  Conductor → WebCodecs → WebGPU via `lyte-control-peer --emit-corpus`).
  Next code is **B-6** — AudioWorklet, input, clipboard, product UI. Not
  live Direct Eye / not full RD yet. Do not scaffold empty
  `Applications/` product stubs until composition earns them.
- **Native role shells:** after the shared client-session boundary is
  IO-free, add the macOS host role, then the Windows host/client and Linux
  client shells. The Linux host already has one verified image and a coherent
  install lifecycle.
