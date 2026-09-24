# Lyte — handoff

*Live resume point, 2026-09-23. Git owns completed history.*

## Branch

- Work is on **`revamp`** (not yet on `main`): bug fixes with reproducing
  tests across every package, the shared client initiator, the host's
  in-process session loop, the XDG host layout, hardened-runtime signing,
  the browser core with native tests, and this documentation restructure.
- Last macOS gate counts: Wire 576, Common 111, Host 349, Client 423 (+1
  hardware test skipped), SystemTests 14, Browser 17; Host on pup 362.
  Browser smoke 10/10 PASS with paced presentation.

## Live rig

- **pup** (standing host) is reachable on Wi-Fi only, `10.0.0.249`. The
  wired `enxf8e43b7ede7c` leg is absent, and `host.conf` advertises on it,
  so mDNS discovery finds nothing: dial `10.0.0.249` directly, and set
  `LYTE_BENCHMARK_HOST=10.0.0.249` for benchmarks.
- `lyte-host.service` serves UDP **41151** from the XDG layout:
  `~/.local/bin/lyte-host` → `versions/e600dbe53c98`, deployed with
  `Host/Scripts/deploy-host.sh`. The in-process session loop is on (no
  `--seconds`); the PID survives client reconnects.
- Identity is `~/.config/lyte/`; the pre-XDG `~/.config/lyte-host/` and
  `/etc/lyte/lyte-host.conf` remain as leftovers the owner may delete
  ([OPERATIONS](docs/OPERATIONS.md#pre-xdg-leftovers)). Log:
  `~/.local/state/lyte/host.log`.
- The Mac client reaches pup over Wi-Fi. Do not launch a benchmark or a
  second app while the owner's `Lyte.app` is open.

## Next

1. Land `revamp` on `main`: Mac and pup gates, PR, merge
   ([TESTING](docs/TESTING.md)).
2. Live checks the revamp could not run unattended: host session loop
   (reconnect cycles, fd/thread/GEM counts flat, held input released),
   roam on host restart, ⌘ shortcuts not reaching GNOME, helper SIGTERM
   restore, one `benchmark-app.sh motion` pass.
3. Deferred work: [TODO.md](TODO.md).
