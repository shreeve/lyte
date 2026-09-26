# Lyte — handoff

*Live resume point, 2026-09-26. Git owns completed history.*

## Tip

- `main` @ **#259**, the fourth revamp pass (typed host address, pixel-exact
  pointer, quiet-screen rate recovery, slow-clock audio, 100 ms wake
  pre-roll), listed under Unreleased in [CHANGELOG.md](CHANGELOG.md).
  **0.7.0 is the latest release** (`v0.7.0`, notarized; the enclosure is
  EdDSA-signed, the feed is not). Install: `brew install --cask
  shreeve/tap/lyte` or `Scripts/install.sh` ([README.md](README.md));
  Sparkle updates.
- Gates (`-warnings-as-errors`): Wire 469 (468 wasm32), Common 113, Host
  396, Client 530, SystemTests 13, Browser 38 (+10 page); pup Host 466,
  Client 162, Browser 38, Wire release 469 at 25,000 ARQ trials.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`, advertised on `wlp0s20f3`).
- `lyte-host.service` serves UDP **41151** from `versions/8607948882fd`
  (#259's host). #256's host is the rollback: `cd ~/src/lyte-host &&
  ./Scripts/deploy-host.sh --rollback --restart` (→ `8d5e83fcc831`).
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: `~/.config/lyte-host/`, `~/lyte-revamp-backup/`, `~/lyte-migration-*`.
  `libinput-tools` is installed on pup (pointer checks).
- **This Mac is paired**; its one Lyte is Homebrew's `/Applications/Lyte.app`
  (0.7.0). #259's client features reach it with the next release.

## Next

1. Owner: try the typed-address field in a dev build (unit-tested only),
   and run the macOS gate once with `LYTE_HARDWARE_TESTS=1`.
2. Audio at session start and after a wake ([TODO.md](TODO.md#client)),
   then the daily-driver browser client ([TODO.md](TODO.md#browser)).
3. Owner decisions in [TODO.md](TODO.md): signing the update feed, netem
   reordering, enforcing the gates, pairing enforcement before 1.0.
