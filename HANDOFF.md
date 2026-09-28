# Lyte — handoff

*Live resume point, 2026-09-27. Git owns completed history.*

## Tip

- `main` @ **#260** (idle feedback, key 17; Unreleased in
  [CHANGELOG.md](CHANGELOG.md)) on **0.7.1**, the latest release
  (notarized; enclosure EdDSA-signed, feed not). Install: `brew install
  --cask shreeve/tap/lyte` (tap #12) or `Scripts/install.sh`.
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
- **This Mac (pop) is paired**; its one Lyte is Homebrew's 0.7.1 in
  `/Applications` (Sparkle-updated). #260's client half reaches it in 0.7.2.
- Still desktop: Mac → pup 8.0 kbps (was 25.0); pup → Mac ~46 kbps is the
  screen (pup's clock shows seconds, so the quiet ladder never engages;
  one-shard frames carry two parity copies).

## Next

1. Owner: release 0.7.2 for #260; decide whether pup's clock shows
   seconds, and whether one-shard frames keep two parity copies (the
   capped-CQ FEC ruling in [AGENTS.md](AGENTS.md)); try the typed-address
   field (unit-tested only).
2. Audio at session start and after a wake ([TODO.md](TODO.md#client)),
   then the daily-driver browser client ([TODO.md](TODO.md#browser)).
3. Owner decisions in [TODO.md](TODO.md): signing the update feed, netem
   reordering, enforcing the gates, pairing enforcement before 1.0.
