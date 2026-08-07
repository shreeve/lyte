# docs/ — the map

*Two kinds of document live here. Dated files are FROZEN records — the
repo convention is annotate, never rewrite (supersession notices and
closure banners go at the top; the body stays as authored). Living docs
update freely. Retired records live in git history — the big retirement
was 2026-08-02, post-E5 (`git show 4bb3e11:docs/<name>` recovers any of
them: the H-era build plans, HOST-PLAN, the H1/H2 gate reports, the
H3/H4 plans, the HANDOFF archive, the estimator/squeeze/Rext/wifi
studies, and the Sunshine/Moonlight/moonshine reference reads).*

The former root `LYTE-PLAN.md` was retired after its durable product
direction moved to `README.md` and its engineering law to `AGENTS.md`.
Historical references inside frozen records still name the plan as it
existed when they were authored. Recover its final form with
`git show 59e8bb4:LYTE-PLAN.md`.

## Living

- [BROWSER.md](BROWSER.md) — current browser-client direction: the proven
  WASM boundary, WebTransport carrier, WebCodecs/WebGPU canvas path,
  Conductor ownership, and the commissioning ladder.
- [DESIGN.md](DESIGN.md) — product and interaction decisions, with shipping
  behavior distinguished from directional intent.
- [MACOS-SIGNING.md](MACOS-SIGNING.md) — signing, bundling, and
  helper-registration reference for the Mac app.
- [THIRD-PARTY.md](THIRD-PARTY.md) — dependency licenses, pinned source
  provenance, and binary-notice obligations.
- [COMPARISON.md](COMPARISON.md) — where Lyte stands against
  conferencing share, remote desktop, and game streaming, with dated Lyte
  evidence kept distinct from qualitative product comparisons.

## The protocol spec (frozen; reference, don't restate)

- [20260720-191701 image quality](20260720-191701-lyte-protocol-image-quality.md) ·
  […191702 timing](20260720-191702-lyte-protocol-timing.md) ·
  […191703 resiliency](20260720-191703-lyte-protocol-resiliency.md) ·
  […191704 transport](20260720-191704-lyte-protocol-transport.md)
- [20260720-193000 overview](20260720-193000-lyte-protocol-overview.md) —
  the capstone that reconciles the pillars.
- [20260720-215100 Lyte-UDP decision](20260720-215100-lyte-udp-decision.md) —
  THE decision record: one protocol, ours, no GameStream ever. Overrides
  QUIC/compat assumptions anywhere else.

## Plans and law (frozen records of active or settled programs)

- [20260730-115707 v2 rulings](20260730-115707-lyte-v2-rulings.md) —
  one repo + `v1-final` tag, the Client/Common/Host target shape,
  LyteCore/LyteIO/LyteTestKit naming, spec-before-code.
- [20260803-084328 source layout and migration](20260803-084328-source-layout-and-migration.md) —
  the owner-approved SwiftPM filesystem grammar, cross-platform target
  hierarchy, dependency law, equivalence contract, and always-green move
  sequence; supersedes the v2 ruling's directory/target-shape section only.
- [20260801-105800 direct-eye plan](20260801-105800-direct-eye-plan.md) —
  the capture rearchitecture, phases E0–E5. **COMPLETE** (see banner):
  the portal demolition landed 2026-08-02, tag `self-hosted`.
- [20260805-084033 direct-eye pixel observation](20260805-084033-direct-eye-pixel-observation.md) —
  the correction record: KMS framebuffer identity is an import-cache key,
  while a 60 Hz full-screen GPU fingerprint owns damage truth and preserves
  encode-on-change silence.
- [20260802-004559 E5 readiness audit](20260802-004559-e5-readiness-audit.md) —
  the flip-day capability matrix and punch list. CLOSED (see banner).
- [20260802-013946 postures design](20260802-013946-postures-design.md) —
  announced quiet/wake postures, tripwire audio + pre-roll, the REWIND,
  and the Lyte OS north star. Settled direction; `TODO.md` owns the remaining
  refinements.
- [20260803-050422 THE CONDUCTOR](20260803-050422-metronome-playout-design.md) —
  one score, one clock, many instruments: the six laws of on-beat
  playout (cue/beat/late/hole/slip/chain), audio + video on one
  model, the automatic cushion law, rubato filed, and three-tier
  convergence into LyteCore. Video's metronome playout turned the #82
  witness's red cell green in #83.
- [20260728-165538 video supremacy plan](20260728-165538-lyte-video-supremacy-plan.md) —
  the HS-wave strategy source (§R3/§7).

## Feature designs (frozen; the law their code still enforces)

- [20260720-145840 audio continuity](20260720-145840-audio-continuity.md) —
  the render-thread rule and pacing doctrine.
- [20260722-231500 clipboard](20260722-231500-lyte-clipboard.md) —
  loop-prevention discipline; the template for every feature channel.
- [20260807-015743 Wayland clipboard GNOME blocker](20260807-015743-wayland-clipboard-gnome-blocker.md) —
  pup pin: no compositor-independent host clipboard on Ubuntu GNOME 50;
  Mutter RD leaf remains; unlock conditions named.
- [20260728-053300 bulk channel](20260728-053300-lyte-bulk-channel.md) —
  file transfer / drag-and-drop.
- [20260728-121500 F-5 client roaming](20260728-121500-f5-client-roaming.md).
- [20260728-164746 video quality probe](20260728-164746-lyte-video-quality-probe.md) —
  Q-1, the Beauty Bar's instrument.
- [20260729-032500 V-3 corpus harness](20260729-032500-lyte-v3-corpus-harness.md) —
  the goldens gate (goldens live in
  `Client/Tests/LyteTransportTests/Fixtures/Goldens/`; corpus-gen/gate
  ride lyte-cli).

## Studies and scoping (banked, not scheduled)

- [20260720-184200 browser client + Caddy bridge](20260720-184200-browser-client-caddy-bridge.md) —
  frozen first bridge consult; [BROWSER.md](BROWSER.md) owns current direction.
- [20260728-054139 browser viewer scoping](20260728-054139-lyte-browser-viewer-scoping.md) —
  frozen WASM/browser survey and original slice ladder; its first WASM proof
  has landed, while [BROWSER.md](BROWSER.md) owns what remains uncommissioned.
- [20260728-175200 wire v2 study](20260728-175200-lyte-wire-v2-study.md) —
  the pre-written v2 batch (fec group-index rides it).
- [20260801-075746 pup scan-stall study](20260801-075746-lyte-pup-scan-stall-study.md) —
  the network campaign's conviction record (gateway 6 GHz radio); pup
  is wired at 10.0.0.232 because of it.
- [20260806-115922 harsh-path control plane](20260806-115922-harsh-path-control-plane.md) —
  detection/mitigation inventory, Conductor-aligned architecture, and the
  harsh-network recovery fixes (floor, FEC-aware ceiling, IDR ownership,
  mild post-FEC climb).
