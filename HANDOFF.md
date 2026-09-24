# Lyte — handoff

*Live resume point, 2026-09-24. Git owns completed history.*

## Tip

- `main` @ **#250**: the second revamp pass (#248), the app icon (#249),
  Homebrew + Sparkle releases (#250, [docs/RELEASING.md](docs/RELEASING.md)).
  0.6.0 is dated in `CHANGELOG.md` and dry-run clean (notarized, feed
  signed) but **not released**.
- Gates (`-warnings-as-errors`): Wire 573 (572 wasm32), Common 116, Host 435,
  Client 525, SystemTests 15, Browser 36 (+7 page); pup Host 495, Client 154.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`; wired `enxf8e43b7ede7c` absent),
  so `host.conf` advertises on `wlp0s20f3` and mDNS finds "pup"; benchmarks
  need `LYTE_BENCHMARK_HOST=10.0.0.249` (the default is the wired `.232`).
- `lyte-host.service` serves UDP **41151**: `~/.local/bin/lyte-host` →
  `versions/7188d8b60f68` (#248's host; `1877bfeb924f` from #247 is kept), via
  `Host/Scripts/deploy-host.sh`. `host.conf` passes only
  `--wire-listen 41151 --clipboard=images --advertise-interface wlp0s20f3`.
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: `~/.config/lyte-host/`, `~/lyte-revamp-backup/`, `~/lyte-migration-*`.
- **This Mac is paired**, but `Lyte.app` lacks the **Local Network** grant
  (`Local network prohibited`); `lyte-cli wire-view 0 --host 10.0.0.249
  --host-port 41151` works from a terminal.

## Next

1. Release: `Scripts/release.sh 0.6.0` from a clean `main`, then the `lyte`
   cask in `shreeve/homebrew-tap` (template in
   [docs/RELEASING.md](docs/RELEASING.md#the-cask)) as a pull request.
2. Owner: install that release (one physical Lyte: remove `.build/Lyte.app`
   or never run it alongside), grant Local Network once, then check ⌘
   shortcuts, held keys across a Wi-Fi hitch, clipboard both ways, roam on
   `sudo systemctl restart lyte-host`, AirDrop after quit; then
   `LYTE_BENCHMARK_HOST=10.0.0.249 Scripts/benchmark-app.sh motion`.
3. Owner decisions in [TODO.md](TODO.md): ⌘ chords, secure input,
   `--wire-out`, netem reordering.
