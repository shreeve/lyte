# TODO — deferred work

This file contains only deliberately deferred, actionable work. The current
slice and live verification state belong in `HANDOFF.md`; settled decisions
belong in `AGENTS.md` or `docs/`; completed work belongs in Git history.

## Verification debt

- **VideoAssembler threshold invariant**
  (`Wire/Sources/LyteWire/Video/VideoAssembler.swift`):
  `sweepLossPresumption` assumes
  `fecImpossibleThresholdPackets >= reorderThresholdPackets`, although the
  initializer accepts the inverse. On the next touch, enforce the invariant
  or early-out against the minimum. Add direct pins for `sweepSettled`,
  `contiguousPrefix`, and the `seqAdvanced || openedGroup` gate.
- **ARQ PTO sleep-forever pin**
  (`Client/Sources/LyteTransport/ReliableCtrlEndpoint.swift`): add a
  virtual-time test for `timerFired()` clearing `armedDeadlineMicros` before
  service.
- **Residual under-lock diagnostics**
  (`Host/Sources/lyte-host/SessionWire.swift`): move the remaining rare
  path-challenge, peer-gone, bulk-send-failure, and connect-failed prints
  through the buffered emitter when this seam is next open.
- **FROZEN exit latency**
  (`Client/Sources/LyteTransport/LyteUdpSession.swift`): a datagram arriving
  during the exact transition into FROZEN exits on the next beat rather than
  immediately. This is bounded to 100 ms and lossless; revisit only if the
  product requires a stricter guarantee.

Live checks still owed:

- Observe `rate: fall purge` and `hole-recused` during an impaired session.
- Close a live stream with ⌘W and verify peer-goodbye plus AWDL release.
- Change monitor geometry during a session and verify typed teardown.
- Decide whether pup should receive the optional realtime-priority grant.

The closed 2026-07-30 analysis ledger is available at
`git show 860369a:ANALYSIS.md`; it is not active backlog.

## Product backlog

- **Printing:** receive a host print job as PDF and hand it to the client's
  native print flow, with its own negotiated capability and consent.
- **Wayland clipboard leaf:** replace the remaining Mutter session-bus
  dependency; capture and input are already compositor-independent.
- **Posture refinements:** an Opus DTX warm rung, DSP fades, and the 2–5 second
  instant-replay ring remain demand-gated. Video cushion stays automatic under
  the Conductor; it is not deferred UI work.
- **Native packaging:** make Linux installation a single coherent product
  experience, then add the macOS host role. Windows/Linux role shells follow
  only after the shared session boundaries are IO-free.
- **Browser client:** after native commissioning, bring the IO-free client
  session boundary into the already-attested WASM path, then use WebTransport,
  WebCodecs, WebGPU, and AudioWorklet through an untrusted browser carrier.
  Current direction: `docs/BROWSER.md`; the dated studies linked there retain
  the original research and measurements.

## Diagnostic backlog

- **Key-joined `lyte sniff`:** `lyte-host sniff` already dissects envelopes
  and channels. Add session-key joining and payload decryption only when a
  debugging campaign needs plaintext inspection. See the one-protocol
  decision §7.

## Codec and hardware backlog

- **AV1:** add a negotiated codec field, OBU writers/parsers and packetizer
  boundaries, a hardware encode seat, and the matching client format path.
  AV1 remains a 4:2:0 WAN-efficiency lane; HEVC Rext remains the 4:4:4 text
  lane. Start only after the direct HEVC path is fully commissioned.
- **NVENC direct seat:** wait for a machine whose display is physically
  owned by NVIDIA. Then extract an encoder seam from `DirectEyeLeg`, register
  the scanout-owned GL resource with CUDA/NVENC without a cross-adapter copy,
  map the scanout CRTC to the correct CUDA device, restore live encoder
  recipes, and add an NVENC capability probe. Pup is a no-MUX Optimus system
  whose connectors belong to Intel, so this work cannot be honestly gated
  there.
