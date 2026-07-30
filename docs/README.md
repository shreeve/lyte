# docs/ — the map

*Three kinds of document live here. Dated files are FROZEN records —
the repo convention is annotate, never rewrite (supersession notices
and closure banners go at the top; the body stays as authored). Living
docs update freely. Reference studies are one-time deep reads of
outside code.*

## Living

- [DESIGN.md](DESIGN.md) — product design decisions (the 2×2
  intent×network grid, D1–D6ff); update as decisions land.
- [HOST-PLAN.md](HOST-PLAN.md) — host strategy recommendation. Its
  wire-protocol mandate is superseded (see its own notice); the
  capture fork, encode facade, and platform-risk sections remain
  authoritative.
- [MACOS-SIGNING.md](MACOS-SIGNING.md) — signing, bundling, and
  helper-registration reference for the Mac app.

## Frozen records (dated; annotate, never rewrite)

**The protocol spec** (the four pillars + capstone are THE spec —
reference them, don't restate them):
- [20260720-191701 image quality](20260720-191701-lyte-protocol-image-quality.md) ·
  […191702 timing](20260720-191702-lyte-protocol-timing.md) ·
  […191703 resiliency](20260720-191703-lyte-protocol-resiliency.md) ·
  […191704 transport](20260720-191704-lyte-protocol-transport.md)
- [20260720-193000 overview](20260720-193000-lyte-protocol-overview.md) —
  the capstone that reconciles the pillars.
- [20260720-215100 Lyte-UDP decision](20260720-215100-lyte-udp-decision.md) —
  THE decision record: one protocol, ours, no GameStream ever. Overrides
  QUIC/compat assumptions anywhere else.

**Build plans and wave plans:**
- [20260720-222500 build plan (master)](20260720-222500-lyte-build-plan.md)
  with companions [core](20260720-221101-build-plan-core.md) ·
  [host](20260720-221102-build-plan-host.md) ·
  [client](20260720-221103-build-plan-client.md).
- [20260723 H3 plan](20260723-051223-lyte-h3-plan.md) — CLOSED (feature
  channel + clipboard shipped).
- [20260728 H4 plan](20260728-194226-lyte-h4-plan.md) — CLOSED (4:4:4
  live, all-green bar; P-2/P-3 dropped).
- [20260728 video supremacy plan](20260728-165538-lyte-video-supremacy-plan.md) —
  the HS-wave strategy source (§R3/§7).
- [20260729 estimator honesty plan](20260729-121027-lyte-estimator-honesty-plan.md).

**Feature designs:**
- [20260720-145840 audio continuity](20260720-145840-audio-continuity.md) —
  the render-thread rule and pacing doctrine.
- [20260722-231500 clipboard](20260722-231500-lyte-clipboard.md) —
  loop-prevention discipline; the template for every feature channel.
- [20260728-053300 bulk channel](20260728-053300-lyte-bulk-channel.md) —
  file transfer / drag-and-drop.
- [20260728-121500 F-5 client roaming](20260728-121500-f5-client-roaming.md).
- [20260728-164746 video quality probe](20260728-164746-lyte-video-quality-probe.md) —
  Q-1, the Beauty Bar's instrument.
- [20260729-032500 V-3 corpus harness](20260729-032500-lyte-v3-corpus-harness.md) —
  the §7 goldens gate (goldens live in `Tests/Goldens/`).

**Studies and scoping (banked, not scheduled):**
- [20260720-184200 browser client + Caddy bridge](20260720-184200-browser-client-caddy-bridge.md) —
  parked post-H6 plan of record.
- [20260728-054139 browser viewer scoping](20260728-054139-lyte-browser-viewer-scoping.md) —
  B-2+ waits on the owner's QUIC posture decision (§6).
- [20260728-175200 wire v2 study](20260728-175200-lyte-wire-v2-study.md) —
  the pre-written v2 batch (fec group-index rides it).
- [20260728-201150 wifi throughput study](20260728-201150-lyte-wifi-throughput-study.md).
- [20260729-002000 V-1 Rext probe](20260729-002000-lyte-v1-rext-probe.md) ·
  [20260729-160421 squeeze review](20260729-160421-lyte-squeeze-review.md).

**Gate reports and run records:**
- [20260722 H1 joint gate](20260722-h1-joint-gate.md) ·
  [20260722 H2 joint gate](20260722-h2-joint-gate.md).
- [20260727-015500 pup catch-up](20260727-015500-pup-catchup.md) —
  a catch-up worker's run report.

**Archives:**
- [20260722 GameStream client plan](20260722-gamestream-client-plan-historical.md) —
  the pre-Lyte-UDP client blueprint, retired.
- [20260730 HANDOFF archive H2→H4](20260730-handoff-archive-h2-h4.md) —
  every wave entry and the Beauty Bar's full per-row forensics, frozen
  at the HANDOFF overhaul.

## Reference studies (outside code, one-time deep reads)

- [sunshine-v2026.715.205118.md](sunshine-v2026.715.205118.md) — the
  Sunshine host tree; still LIVE reference for Linux capture/encode/
  input quirks (H5/H6 territory).
- [moonshine.md](moonshine.md) — the Rust Sunshine-compatible host;
  same territory, second opinion.
- [moonlight-common-c.md](moonlight-common-c.md) ·
  [moonlight-macos.md](moonlight-macos.md) — GameStream-era client
  studies (see their banners): platform knowledge stands, protocol
  halves are archaeology.
