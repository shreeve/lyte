# Lyte — session handoff

*Current as of 2026-08-04. This is the live resume point, not a historical
ledger. Update it whenever the branch, verification state, live rig, or next
action changes. Completed detail belongs in Git history.*

## Resume here

- **Branch:** `commissioning/truthful-stall-stage`, based on `origin/main`;
  temporary PR branches are deleted after landing so the repository returns
  to one local and one remote branch.
- **GitHub:** no open PRs; #159 landed the explicit link-health epoch seam.
- **Repository:** one worktree; `main` plus the temporary current PR branch.
  Stale migration, cleanup, ledger, and agent pointers were audited and
  retired after their merged or superseding work was confirmed present.
- **Documents:** README, AGENTS, HANDOFF, and TODO have one responsibility
  each; `CLEANUP.md` and `LYTE-PLAN.md` are retired to Git history.

The architecture-cleanup train is frozen after #155. The authoritative
projection inventory is closed; remaining candidates are diagnostic-only or
moderate-risk abstractions, not owed debt. Commission the current tree before
reopening structural cleanup.

## Last green gates

At committed HEAD before this documentation-only work:

| Suite | macOS | pup/Linux |
|---|---:|---:|
| Wire | 513 | 513 |
| Common | 83 | 84 |
| Host | 338 | 339 |
| Client | 262 | — |
| SystemTests | 17 | — |
| Analyzer | 25 | — |

Benchmark safety and both signed products also passed. The pup build was
plain—no ffmpeg environment—and protected identity state survived.

For this root-document pass, the required gates are dangling-reference and
Markdown-link inspection, `git diff --check`, and the repository's structural
checks. Source comments may change, but executable behavior must not.

## Current live result

The ordinary Lyte client is streaming successfully from pup. A direct launch
of the signed bundle executable with `LYTE_AUTOCONNECT=10.0.0.232` sustained
video beyond the earlier two-second failure point and continued receiving
frames without a transport error.

The commissioning client now computes the warning pill from an exact ring of
60 tagged one-second buckets using client-monotonic event times. The 1 Hz UI
heartbeat ages the window even when damage-driven capture emits no frames.
An explicit epoch seam resets that window and its warm-up on every reconnect,
including equal or leapfrogged frame ordinals, while preserving sitting-wide
totals. Focused LinkHealth tests passed 15/15, the full Client suite passed
266/266, SystemTests passed 17/17, and the complete macOS and pup deterministic
gates passed for the underlying ring. The current slice renames the unproven
"network" cause to its measured boundary, **pre-render delivery**, and pins
stage migration within a coalesced episode; focused tests passed 24/24, Client
267/267, and SystemTests 17/17. The complete macOS and pup deterministic gates
also passed; pup finished 339 Host tests plus the kernel socket and pacing
harnesses with protected state unchanged. The signed #158 release is live
against pup; replacing the prior client ended the one-session host cleanly
and systemd restarted it successfully (`Result=success`, not a crash).

Two launch problems were distinguished:

1. LaunchServices (`open .build/Lyte.app`) can receive macOS's Local Network
   denial and fail UDP with `socketFailed(errno: 65)` even while the app is
   enabled in Privacy settings. Cycling Wi-Fi did not reliably clear it.
   Directly launching the signed executable from a shell worked.
2. `Scripts/benchmark-app.sh handshake-only` launches a diagnostic app with
   the same bundle identity. Running it alongside the owner's client can
   replace the interactive instance; the banner
   `handshake-only-20260804T233542Z-23925` identified that event. Do not run
   benchmark app modes while the owner is using Lyte.

The re-sign performed during diagnosis affected only the ignored
`.build/Lyte.app` artifact; there is no tracked signing change. Packaging,
Local Network permission messaging/recovery, and benchmark-instance isolation
remain product follow-ups rather than a wire failure.

## Next action

1. Run the final commissioning campaign against the frozen code tree:
   deterministic/structural gates, live quality, scoped impairment, soak,
   and owner feel.
2. Reopen cleanup only for a concrete commissioning finding or a clearly
   earned shared owner.

The remaining owner-visible quality check is the two-column stats ledger
overlay. The GNOME Shell 10-second source-stall comb is an established pup
environment limitation, not a Lyte host-loop defect.

## Live rig

### Host

- `pup` is wired at `10.0.0.232` and advertises the standing system service
  on UDP **41151**.
- Unit: `lyte-host.service`, `User=shreeve`,
  `AmbientCapabilities=CAP_SYS_ADMIN`, `Restart=always`.
- Binary: `~/src/lyte-host/.build/debug/lyte-host`.
- Operator config: `/etc/lyte/lyte-host.conf`.
- Session log: `/tmp/lyte-host-session.log`.
- Effective posture: direct KMS eye, native VAAPI, 4:4:4 Best supported,
  Opus audio, image clipboard, ratchet flag accepted as a legacy no-op.

Deploy with a build followed by:

```sh
sudo -n systemctl restart lyte-host
systemctl is-active lyte-host
```

The system service receives DRM privilege through its ambient capability;
do not apply file capabilities to the service binary. Hand-run hardware
probes still need an exact-path `setcap`.

### Client

- Bundle: `.build/Lyte.app`
- Host and client are paired; a healthy reconnect shows no PIN.
- The currently proven fallback launch is the bundle executable from a shell
  with `LYTE_AUTOCONNECT=10.0.0.232`.
- `open .build/Lyte.app` remains the intended product launch, but its Local
  Network authorization is not presently reliable on this Mac.

If a six-digit pairing sheet appears, temporarily add `--pair` to the
operator-owned host arguments, restart the service, pair once, then remove
the flag and restart again. Three wrong guesses consume the PIN.

### Safety

- Never touch pup's
  `~/.config/lyte-host/{portal_token,noise_static.key,paired_clients}`.
- Never stop or replace the owner's 41151 service for a test. Use a fresh
  41xxx port plus `--no-advertise`.
- Warn the owner before any live test host captures the physical screen.
- Scope every netem rule to the exact test port and remove it after the leg.

## Build and deployment recipe

Mac tests require the full Xcode toolchain:

```sh
cd Wire && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Common && DEVELOPER_DIR=/Applications/Xcode.app swift test
cd Host && DEVELOPER_DIR=/Applications/Xcode.app swift test
DEVELOPER_DIR=/Applications/Xcode.app swift test \
  --package-path Client --scratch-path .build
cd SystemTests && DEVELOPER_DIR=/Applications/Xcode.app swift test
```

Sync and build pup:

```sh
rsync -a --delete --exclude .build Wire/ pup:src/Wire/
rsync -a --delete --exclude .build Common/ pup:src/Common/
rsync -a --delete --exclude .build Host/ pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift test'
ssh pup 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build'
```

Do not pipe `swift test` into `grep`; it masks the exit code. Capture the
status after redirection. `status` is read-only in zsh, so use another name.

## Quality gate

`Scripts/benchmark-app.sh` is the current glass-quality instrument. Run
motion legs with the panel at 60 Hz and pin the requested tier with
`LYTE_BENCHMARK_CHROMA_TIER=good|best`.

| Tier | Active floor | Converged floor | SSIM floor |
|---|---:|---:|---:|
| 4:2:0 | 28 dB | 30 dB | 0.995 |
| 4:4:4 | 45 dB | 50 dB | 0.9995 |

Best-tier baseline from 2026-08-03:

- static: 57.6 dB minimum channel, SSIM 0.999994;
- motion: 56.8 dB, SSIM 0.99999, 59.97 fps;
- gap p50/p95/p99: exactly 16.667 ms;
- lateness p99: 1.92 ms.

An AWDL re-engage can create an environmental ~100 ms audio window. Check
stderr for `awdl0 UP while streaming` before attributing that failure to the
wire. Never soften a red threshold at HEAD; a failure is a finding.

## Recovery pointers

- Pre-normalization handoff: `git show 59e8bb4:HANDOFF.md`
- H2–H4 wave ledger and historical Beauty Bar:
  `git show 4bb3e11:docs/20260730-103326-handoff-archive-h2-h4.md`
- Pre-slim portal-era operations: `git show 0753cbc:HANDOFF.md`
- Retired analysis ledger: `git show 860369a:ANALYSIS.md`
- Retired overall strategy: `git show 59e8bb4:LYTE-PLAN.md`
