# Lyte — handoff

*Live resume point, 2026-09-24. Git owns completed history.*

## Tip

- `main` @ **#245**, the revamp: bug fixes with reproducing tests across
  every package, the shared client initiator, the host's in-process
  session loop, the XDG host layout, hardened-runtime signing, the browser
  core with native tests, invariant-only comments, these docs.
- Last gate counts, all `-warnings-as-errors`: Wire 577 (576 on wasm32),
  Common 119, Host 385, Client 434 (+1 hardware skip), SystemTests 14,
  Browser 21 (+5 page tests); Host on pup 406.

## Live rig

- **pup** is on Wi-Fi only (`10.0.0.249`; wired `enxf8e43b7ede7c` absent),
  so `host.conf` advertises on `wlp0s20f3` and mDNS finds "pup"; benchmarks
  need `LYTE_BENCHMARK_HOST=10.0.0.249` (the default is the wired `.232`).
- `lyte-host.service` serves UDP **41151**: `~/.local/bin/lyte-host` →
  `versions/1877bfeb924f` (#247 tree; previous `17fad55a8c21` kept), via
  `Host/Scripts/deploy-host.sh`. Session loop on; `host.conf` passes only
  `--wire-listen 41151 --clipboard=images --advertise-interface wlp0s20f3`.
- Identity `~/.config/lyte/`; log `~/.local/state/lyte/host.log`. Kept for
  the owner: pre-XDG `~/.config/lyte-host/`, `~/lyte-revamp-backup/`,
  `~/lyte-migration-*`, `/etc/lyte/*.pre-release-opus-*`.
- **This Mac is paired** (`lyte-cli wire-pair`; pin in `~/Library/Application
  Support/Lyte/`), but `Lyte.app` has never been granted **Local Network**
  here: it logs `Local network prohibited` and never dials. Grant it once in
  System Settings → Privacy & Security → Local Network. No benchmark or
  second app while the owner's `Lyte.app` is open.

## Next

1. Owner: grant Lyte Local Network access, then check in the app: ⌘
   shortcuts don't reach GNOME, no stuck keys, clipboard both ways, roam on
   `sudo systemctl restart lyte-host`, AirDrop back after quitting.
2. Then `LYTE_BENCHMARK_HOST=10.0.0.249 Scripts/benchmark-app.sh motion`
   (it failed only on the missing Local Network grant).
3. Deferred work: [TODO.md](TODO.md).
