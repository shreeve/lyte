# Documentation catalog

Every current fact has one living owner. Dated records keep the reasons
behind decisions and are never edited for currency: their status lives in
this catalog (and in one status line under each title), not in their
bodies. A front door never cites a dated record as the current
specification.

## Living documents

| Document | Owns |
|---|---|
| [README.md](../README.md) | Product identity, architecture sketch, quickstart |
| [AGENTS.md](../AGENTS.md) | Repository law: ownership, doctrine, safety, change discipline |
| [HANDOFF.md](../HANDOFF.md) | Current branch, live rig state, next work |
| [TODO.md](../TODO.md) | Deferred work |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Packages, targets, dependency graph, data flow, threads |
| [PROTOCOL.md](PROTOCOL.md) | The current Lyte-UDP contract, section by section, with its vector files |
| [TESTING.md](TESTING.md) | Every gate and the exact commands |
| [OPERATIONS.md](OPERATIONS.md) | The pup rig, an installed host's layout, deploy and rollback, pairing, uninstall, safety runbook |
| [BROWSER.md](BROWSER.md) | The browser client: what the proof covers, how to run it |
| [DESIGN.md](DESIGN.md) | Product and interaction decisions, shipping vs directional |
| [COMPARISON.md](COMPARISON.md) | Lyte against other remote-display products |
| [MACOS-SIGNING.md](MACOS-SIGNING.md) | Signing, hardened runtime, the helper's security surface |
| [RELEASING.md](RELEASING.md) | Homebrew install, Sparkle updates, cutting and verifying a release |
| [THIRD-PARTY.md](THIRD-PARTY.md) | Dependency licenses and notices |
| [GLOSSARY.md](GLOSSARY.md) | Slice ids, Conductor terms, Direct Eye, postures |
| [Wire/Vectors/README.md](../Wire/Vectors/README.md) | Normative byte layouts and the vector inventory |
| [Host/README.md](../Host/README.md) | Host package: testing it and running `lyte-host` by hand |
| [Host/INSTALL.md](../Host/INSTALL.md) | Installing the host on a fresh machine |
| [Scripts/netem/README.md](../Scripts/netem/README.md) | The netem helper and the impairment gate |

## Decisions (binding, dated)

These rulings still constrain the code. Where later work changed a detail,
the status column says so.

| Record | Date | Status |
|---|---|---|
| [Lyte-UDP: the only protocol](decisions/20260720-215100-lyte-udp-decision.md) | 2026-07-20 | Binding. Wire details: [PROTOCOL.md](PROTOCOL.md) |
| [Audio continuity](decisions/20260720-145840-audio-continuity.md) | 2026-07-20 | Binding: render-thread rule, pacing doctrine. §5.1–5.2 landed (lock-free PCM ring, `AudioAccelerator`); the render-callback lock it describes is gone |
| [Clipboard sync](decisions/20260722-231500-lyte-clipboard.md) | 2026-07-22 | Binding: loop prevention, the feature-channel template |
| [Bulk-transfer channel](decisions/20260728-053300-lyte-bulk-channel.md) | 2026-07-28 | Binding. Later bounds: sender read-ahead 128 chunks, receive window clamped to 256 |
| [F-5 client roaming](decisions/20260728-121500-f5-client-roaming.md) | 2026-07-28 | Binding, with errata: the event epoch fences session events only; `ConnectionModel`'s lifecycle generation fences dial and browse results; a host `shuttingDown` teardown now roams, `takenOver` ends the window |
| [v2 rulings](decisions/20260730-115707-lyte-v2-rulings.md) | 2026-07-30 | Binding: one repository, convergence in place, always green. Directory/target shape superseded by the source-layout record |
| [Postures](decisions/20260802-013946-postures-design.md) | 2026-08-02 | Binding: announced quiet/wake postures (0x25/0x26). Warm rung and rewind deferred ([TODO.md](../TODO.md)) |
| [The Conductor](decisions/20260803-050422-metronome-playout-design.md) | 2026-08-03 | Binding: the playout laws, plus the stretch-law addendum. Its drift discussion predates the host's own 60 Hz capture grid |
| [Source layout and migration](decisions/20260803-084328-source-layout-and-migration.md) | 2026-08-03 | Binding grammar and dependency direction, with errata: targets are `HostCore`/`HostSession` (and `HostWire`, `HostIO`), Session targets may import `LyteCore`, the platform targets in §4 were never created, `LyteWireVectorGen` is now a library beside the `LyteWireVectorGenTool` CLI. Current list: [ARCHITECTURE.md](ARCHITECTURE.md) |
| [Direct Eye pixel observation](decisions/20260805-084033-direct-eye-pixel-observation.md) | 2026-08-05 | Binding: the GPU pixel fingerprint owns damage truth |
| [Wayland clipboard: GNOME blocker](decisions/20260807-015743-wayland-clipboard-gnome-blocker.md) | 2026-08-07 | Binding: host clipboard stays on Mutter RemoteDesktop until an unlock lands |
| [Browser client platform slice](decisions/20260807-021425-browser-client-platform-slice.md) | 2026-08-07 | Binding: naming, WebTransport carrier, ownership. Ladder status and §7 superseded by [BROWSER.md](BROWSER.md) |

## History (dated, superseded or closed)

Plans, studies, probes and the original protocol pillars. Read them for
reasoning and measurements, not for current behavior.

| Record | Date | Status | Current truth |
|---|---|---|---|
| [Browser client via Caddy bridge](history/20260720-184200-browser-client-caddy-bridge.md) | 2026-07-20 | Superseded (sidecar relay) | [BROWSER.md](BROWSER.md) |
| [Protocol pillar: image quality](history/20260720-191701-lyte-protocol-image-quality.md) | 2026-07-20 | Superseded: the color path is BT.709 limited, not full-range; NVENC retired | [PROTOCOL.md](PROTOCOL.md) |
| [Protocol pillar: timing](history/20260720-191702-lyte-protocol-timing.md) | 2026-07-20 | Superseded: no PipeWire master clock | [PROTOCOL.md](PROTOCOL.md) |
| [Protocol pillar: resiliency](history/20260720-191703-lyte-protocol-resiliency.md) | 2026-07-20 | Superseded | [PROTOCOL.md](PROTOCOL.md) |
| [Protocol pillar: transport](history/20260720-191704-lyte-protocol-transport.md) | 2026-07-20 | Superseded: QUIC rejected | [PROTOCOL.md](PROTOCOL.md) |
| [Protocol overview (capstone)](history/20260720-193000-lyte-protocol-overview.md) | 2026-07-20 | Superseded | [PROTOCOL.md](PROTOCOL.md) |
| [Browser viewer scoping](history/20260728-054139-lyte-browser-viewer-scoping.md) | 2026-07-28 | Historical survey | [BROWSER.md](BROWSER.md) |
| [Video quality probe (Q-1)](history/20260728-164746-lyte-video-quality-probe.md) | 2026-07-28 | Historical measurement | [TESTING.md](TESTING.md) |
| [Video supremacy plan](history/20260728-165538-lyte-video-supremacy-plan.md) | 2026-07-28 | Historical plan | [ARCHITECTURE.md](ARCHITECTURE.md) |
| [Wire v2 study](history/20260728-175200-lyte-wire-v2-study.md) | 2026-07-28 | Banked, unscheduled | [PROTOCOL.md](PROTOCOL.md) |
| [V-3 corpus harness](history/20260729-032500-lyte-v3-corpus-harness.md) | 2026-07-29 | Historical; the goldens live in `Client/Tests/LyteCorpusTests/Fixtures/Goldens/` | [TESTING.md](TESTING.md) |
| [pup scan-stall study](history/20260801-075746-lyte-pup-scan-stall-study.md) | 2026-08-01 | Closed investigation | [OPERATIONS.md](OPERATIONS.md) |
| [Direct Eye plan](history/20260801-105800-direct-eye-plan.md) | 2026-08-01 | Complete (E5, `self-hosted` tag); its damage premise is corrected by the pixel-observation record | [ARCHITECTURE.md](ARCHITECTURE.md) |
| [E5 readiness audit](history/20260802-004559-e5-readiness-audit.md) | 2026-08-02 | Closed | [ARCHITECTURE.md](ARCHITECTURE.md) |
| [Harsh-path control plane](history/20260806-115922-harsh-path-control-plane.md) | 2026-08-06 | Closed campaign | [ARCHITECTURE.md](ARCHITECTURE.md) |

## Retired records

Removed from the tree; older records and code comments still cite them.
Recover any of them from git:

| Path | Recover with |
|---|---|
| `LYTE-PLAN.md` (the original master strategy) | `git show d6a8108^:LYTE-PLAN.md` |
| `docs/20260720-222500-lyte-build-plan.md` ("master plan") | `git show 4bb3e11:docs/20260720-222500-lyte-build-plan.md` |
| `docs/20260720-221101-build-plan-core.md` ("core plan") | `git show 4bb3e11:docs/20260720-221101-build-plan-core.md` |
| `docs/20260720-221102-build-plan-host.md` ("host build plan") | `git show 4bb3e11:docs/20260720-221102-build-plan-host.md` |
| `docs/20260720-221103-build-plan-client.md` ("client build plan") | `git show 4bb3e11:docs/20260720-221103-build-plan-client.md` |
| `docs/HOST-PLAN.md` | `git show 4bb3e11:docs/HOST-PLAN.md` |
| `docs/20260723-051223-lyte-h3-plan.md` | `git show 4bb3e11:docs/20260723-051223-lyte-h3-plan.md` |
| `docs/20260728-194226-lyte-h4-plan.md` | `git show 4bb3e11:docs/20260728-194226-lyte-h4-plan.md` |
| `docs/20260728-201150-lyte-wifi-throughput-study.md` | `git show 4bb3e11:docs/20260728-201150-lyte-wifi-throughput-study.md` |
| `docs/20260730-103326-handoff-archive-h2-h4.md` | `git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md` |
| `docs/sunshine-v2026.715.205118.md` | `git show 4bb3e11:docs/sunshine-v2026.715.205118.md` |
| `docs/moonlight-common-c.md` | `git show 4bb3e11:docs/moonlight-common-c.md` |

The same commit holds the other retired records (the H1/H2 gate reports,
the estimator, squeeze and Rext studies, the Moonlight and moonshine
reference reads): `git ls-tree --name-only 4bb3e11 docs/`.

## Adding a document

- A new fact belongs in the living document that owns its subject.
- A dated record (`YYYYMMDD-HHMMSS-slug.md`) goes in `decisions/` when it
  is a ruling that will keep binding, otherwise in `history/`. Give it one
  status line under the title and a row here. When its status changes,
  change this catalog and the status line, not the body.
