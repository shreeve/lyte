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

- **pup** (standing host) is reachable on Wi-Fi only, `10.0.0.249`. The
  wired `enxf8e43b7ede7c` leg is absent, and `host.conf` advertises on it,
  so `Lyte.app` (mDNS only) can't see pup until `host.conf` advertises
  on `wlp0s20f3` ([OPERATIONS](docs/OPERATIONS.md#the-rig)); `wire-view`
  dials `10.0.0.249`; benchmarks need `LYTE_BENCHMARK_HOST=10.0.0.249`.
- `lyte-host.service` serves UDP **41151** from the XDG layout:
  `~/.local/bin/lyte-host` → `versions/17fad55a8c21` (the #245 tree),
  deployed with `Host/Scripts/deploy-host.sh`. The in-process session loop is on
  (no `--seconds`); the PID survives client reconnects. `host.conf` passes
  only `--wire-listen 41151 --clipboard=images --advertise-interface …`.
- Identity is `~/.config/lyte/`; the pre-XDG `~/.config/lyte-host/` and
  `/etc/lyte/lyte-host.conf` are leftovers the owner may delete
  ([OPERATIONS](docs/OPERATIONS.md#pre-xdg-leftovers)). Log:
  `~/.local/state/lyte/host.log`. No benchmark or second app while the
  owner's `Lyte.app` is open.

## Next

1. Live checks only a person at the Mac can run: pair this Mac (discovery
   needs `--advertise-interface wlp0s20f3` while pup is Wi-Fi only), ⌘
   shortcuts not reaching GNOME, no stuck keys, app clipboard both ways,
   roam on `systemctl restart lyte-host`, helper restores awdl0 on quit,
   one `benchmark-app.sh motion`.
2. Deferred work: [TODO.md](TODO.md).
