# Lyte — handoff

*Live resume point, 2026-09-24. Git owns completed history.*

## Tip

- `main` @ #247. Local branch **`revamp`** (unpushed, unmerged) is the
  second revamp pass over `main`: remote-crash and hostile-input fixes on
  both ends, video sealed at pacer release, shared client policy adopted by
  the browser, verified helper registration, real shell assertions and
  stricter gates. Land it per [AGENTS.md](AGENTS.md#change-discipline).
- Gate counts on `revamp`, all `-warnings-as-errors`: Wire 573 (572 on
  wasm32), Common 116, Host 435, Client 521 (+1 hardware skip),
  SystemTests 15, Browser 36 (+7 page tests); on pup Host 495, Client 154.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`; wired `enxf8e43b7ede7c` absent),
  so `host.conf` advertises on `wlp0s20f3` and mDNS finds "pup"; benchmarks
  need `LYTE_BENCHMARK_HOST=10.0.0.249` (the default is the wired `.232`).
- `lyte-host.service` serves UDP **41151**: `~/.local/bin/lyte-host` →
  `versions/7188d8b60f68` (`revamp`; `main`'s `1877bfeb924f` is kept), via
  `Host/Scripts/deploy-host.sh`. `host.conf` passes only
  `--wire-listen 41151 --clipboard=images --advertise-interface wlp0s20f3`.
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: pre-XDG `~/.config/lyte-host/`, `~/lyte-revamp-backup/`,
  `~/lyte-migration-*`, `/etc/lyte/*.pre-release-opus-*`.
- **This Mac is paired**, but `Lyte.app` lacks the **Local Network** grant
  (`Local network prohibited`); `lyte-cli wire-view 0 --host 10.0.0.249
  --host-port 41151` works from a terminal.

## Next

1. Owner: grant Lyte Local Network (Privacy & Security), then check in the
   app: ⌘ shortcuts, held keys survive a short Wi-Fi hitch, clipboard both
   ways, roam on `sudo systemctl restart lyte-host`, AirDrop after quit.
2. Then `LYTE_BENCHMARK_HOST=10.0.0.249 Scripts/benchmark-app.sh motion`.
3. Owner decisions in [TODO.md](TODO.md): ⌘ chords, secure input,
   `--wire-out`, netem reordering. Then land `revamp`.
