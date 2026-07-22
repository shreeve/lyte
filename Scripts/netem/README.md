# Netem rig

Impairment scripts for the measured gates (host plan
`docs/20260720-221102-build-plan-host.md` §5). Everything here runs on the
host machine and is scoped so nothing else on the box is ever impaired:
loopback profiles touch only `lo` and only one UDP port; the LAN profiles
filter on the Lyte port (and DSCP class where a leg needs it).

## Current contents

- `lo-netem.sh` — the loopback variant, for pre-client development
  (pacer/FEC/netio work against a local test receiver). Applies a
  port-scoped netem delay/loss profile on `lo`, removes it, or shows
  status. See the header comment for usage; needs root for apply/remove.

  ```sh
  sudo Scripts/netem/lo-netem.sh apply 47999 20     # 20 ms delay
  sudo Scripts/netem/lo-netem.sh apply 47999 20 1   # + 1% loss
  sudo Scripts/netem/lo-netem.sh remove
  ```

## To come

One script per gate row — the R-G1..R-G8 profiles on the LAN interface
(egress netem with a u32 filter matched to the client IP, plus an `ifb`
redirect for gates needing impairment toward the host). Each will print
its exact profile and duration, per the host plan.
