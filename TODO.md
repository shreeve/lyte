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
- **Browser client (active platform slice):** B-0 naming/carrier, B-1
  Chrome WASM + frozen-contract JS boundary, and B-2 opaque WebTransport
  datagram carriage (same-box `lyte-wt-sidecar`, measured ceiling ≥ 1152 B)
  are landed (`Browser/`, `docs/BROWSER.md`). Next code is **B-3** —
  control-only pup session (pair/Noise/capabilities) over the WT carrier —
  then WebCodecs/WebGPU (B-4), live Conductor video (B-5), and
  AudioWorklet/input/clipboard/UI (B-6). Do not claim streaming before B-5;
  do not scaffold empty `Applications/` product stubs until composition
  earns them.
- **Native role shells:** after the shared client-session boundary is
  IO-free, add the macOS host role, then the Windows host/client and Linux
  client shells. The Linux host already has one verified image and a coherent
  install lifecycle.
