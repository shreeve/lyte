# Lyte — handoff

*Live resume point, 2026-09-24. Git owns completed history.*

## Branch

- Work is on **`revamp`** (not yet on `main`): bug fixes with reproducing
  tests across every package, the shared client initiator, the host's
  in-process session loop, the XDG host layout, hardened-runtime signing,
  the browser core with native tests, invariant-only comments, these docs.
- Last gate counts, all `-warnings-as-errors`: Wire 577 (576 on wasm32),
  Common 119, Host 385, Client 434 (+1 hardware skip), SystemTests 14,
  Browser 21 (+5 page tests); Host on pup 406.

## Live rig

- **pup** (standing host) is reachable on Wi-Fi only, `10.0.0.249`. The
  wired `enxf8e43b7ede7c` leg is absent, and `host.conf` advertises on it,
  so mDNS discovery finds nothing: dial `10.0.0.249` directly, and set
  `LYTE_BENCHMARK_HOST=10.0.0.249` for benchmarks.
- `lyte-host.service` serves UDP **41151** from the XDG layout:
  `~/.local/bin/lyte-host` → `versions/<id>`, redeployed from the `revamp`
  tip with `Host/Scripts/deploy-host.sh`. The in-process session loop is on
  (no `--seconds`); the PID survives client reconnects. `host.conf` passes
  only `--wire-listen 41151 --clipboard=images --advertise-interface …`.
- Identity is `~/.config/lyte/`; the pre-XDG `~/.config/lyte-host/` and
  `/etc/lyte/lyte-host.conf` are leftovers the owner may delete
  ([OPERATIONS](docs/OPERATIONS.md#pre-xdg-leftovers)). Log:
  `~/.local/state/lyte/host.log`. No benchmark or second app while the
  owner's `Lyte.app` is open.

## Next

1. Land `revamp` on `main`: Mac and pup gates, PR, merge
   ([TESTING](docs/TESTING.md)).
2. Live checks the revamp could not run unattended: session loop reconnect
   cycles (fd/thread/GEM counts flat, held input released), an abandoned
   handshake redials at once, roam on host restart, ⌘ shortcuts not
   reaching GNOME, helper SIGTERM restore, one `benchmark-app.sh motion`.
3. Deferred work: [TODO.md](TODO.md).
