# Lyte — handoff

*Live resume point, 2026-09-29. Git owns completed history.*

## Tip

- `main` @ **pass 5** (root-owned host, clean audio start, signed feed,
  browser viewer; Unreleased in [CHANGELOG.md](CHANGELOG.md)) on
  **0.7.1**, the latest release. Install: `brew install --cask
  shreeve/tap/lyte` or `Scripts/install.sh`.
- Gates (`-warnings-as-errors`): Wire 476 (475 wasm32), Common 113, Host
  398, Client 537, SystemTests 13, Browser 44 (+26 page); pup Host 468,
  Client 167, Browser 44, Wire release 476 at 25,000 ARQ trials.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`). Avahi publishes IPv4 only
  (backup `/etc/avahi/avahi-daemon.conf.pre-ipv4only`). Identity
  `~/.config/lyte/`; log `~/.local/state/lyte/host.log`.
- `lyte-host.service` serves UDP **41151** from the root-owned
  `/usr/local/lib/lyte/versions/578219f1366f` (#260's host, current for
  pass 5; the only root-owned version), knobs in `/etc/lyte/host.conf`.
  Undo the root move with the unit saved in
  `~/lyte-root-migration-20260928T191035Z` (old `~/.local` versions kept).
- **Browser:** Janus `1.19.0-dev` (an uncommitted `capability/webtransport`
  build) runs as the user `janus.service` in `lan` mode. The site
  `~/.config/janus/sites/lyte.caddy` serves `https://lyte.local/` from
  `~/lyte-www` (viewer staged by hand) and relays `/lyte` to
  `udp/127.0.0.1:41151`.
- **This Mac (pop)** is paired and runs Homebrew's 0.7.1 (Sparkle).
- Still desktop: Mac → pup 8.0 kbps. pup → Mac is about 46 kbps because
  pup's clock shows seconds, so the quiet ladder never engages.

## Next

1. Owner: release 0.7.2 (signed feed, #260's client, pass 5), then 0.7.3
   (`SURequireSignedFeed`).
2. Janus: land 1.19.0 in `~/Data/Code/janus`, then replace pup's dev build.
3. Browser daily driver ([TODO.md](TODO.md#browser)). Owner calls: pup's
   seconds clock, one-shard double parity, pup's sudo, pairing before 1.0.
