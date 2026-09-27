# Lyte — handoff

*Live resume point, 2026-09-27. Git owns completed history.*

## Tip

- `main` @ **#260**: capability key 17 (idle feedback) on top of **0.7.1**,
  the latest release (`v0.7.1`, notarized; the enclosure is EdDSA-signed,
  the feed is not). #260 is under Unreleased in
  [CHANGELOG.md](CHANGELOG.md). Install: `brew install --cask
  shreeve/tap/lyte` (tap #12 is 0.7.1) or `Scripts/install.sh`
  ([README.md](README.md)); Sparkle updates.
- Gates (`-warnings-as-errors`): Wire 476 (475 wasm32), Common 113, Host
  398, Client 534, SystemTests 13, Browser 38 (+10 page); pup Host 468,
  Client 164, Browser 38, Wire release 476 at 25,000 ARQ trials.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`, advertised on `wlp0s20f3`).
- `lyte-host.service` serves UDP **41151** from `versions/578219f1366f`
  (#260's host; it declares key 17). 0.7.1's host is the rollback:
  `cd ~/src/lyte-host && ./Scripts/deploy-host.sh --rollback --restart`
  (→ `8607948882fd`).
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: `~/.config/lyte-host/`, `~/lyte-revamp-backup/`, `~/lyte-migration-*`.
  `libinput-tools` is installed on pup (pointer checks).
- **This Mac (pop) is paired** and streams with `.build/Lyte.app`, a
  release build of #260 (it reports 0.7.1). Homebrew's
  `/Applications/Lyte.app` (0.7.1) is also installed; a 0.7.2 release
  brings #260 to it and returns the Mac to one copy.
- Still desktop, live: Mac → pup 8.0 kbps (was 25.0). pup → Mac ~46 kbps
  is the screen itself: pup's clock shows seconds
  (`clock-show-seconds true`), so the video quiet ladder never engages,
  and one-shard frames carry two parity copies.

## Next

1. Owner: release 0.7.2 for #260; decide whether pup's clock shows
   seconds, and whether one-shard frames keep two parity copies (the
   capped-CQ FEC ruling in [AGENTS.md](AGENTS.md)); try the typed-address
   field (unit-tested only).
2. Audio at session start and after a wake ([TODO.md](TODO.md#client)),
   then the daily-driver browser client ([TODO.md](TODO.md#browser)).
3. Owner decisions in [TODO.md](TODO.md): signing the update feed, netem
   reordering, enforcing the gates, pairing enforcement before 1.0.
