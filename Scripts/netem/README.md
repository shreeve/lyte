# Netem rig

Impairment scripts for the measured gates (host build plan §5, retired
to git history). Everything here runs on the
host machine and is scoped so nothing else on the box is ever impaired:
loopback profiles touch only `lo` and only one UDP port; the LAN profiles
filter on the Lyte port (and DSCP class where a leg needs it).

## Current contents

- `port-netem.sh` — the reusable LAN-flow helper. It preserves `fq_codel`
  for unmatched traffic and sends only one IPv4 UDP source-port/client-IP
  pair through netem. Its distinctive qdisc handles make apply/remove
  ownership verifiable. `benchmark-netem.sh` uploads and invokes it on pup;
  direct use requires root.

- `lo-netem.sh` — the loopback variant, for pre-client development
  (pacer/FEC/netio work against a local test receiver). Applies a
  port-scoped netem delay/loss profile on `lo`, removes it, or shows
  status. See the header comment for usage; needs root for apply/remove.

  ```sh
  sudo Scripts/netem/lo-netem.sh apply 41099 20     # 20 ms delay
  sudo Scripts/netem/lo-netem.sh apply 41099 20 1   # + 1% loss
  sudo Scripts/netem/lo-netem.sh remove
  ```

`LYTE_BENCHMARK_PORT=<41xxx> Scripts/benchmark-netem.sh moderate` is the
real-client egress SLO leg against a fresh test host. It matches that host
UDP source port and the resolved client `/32`; it does not shape feedback
toward the host. The script refuses to default to standing 41151 (set
`LYTE_BENCHMARK_ALLOW_STANDING_PORT=1` only for an explicit standing-leg).
Bidirectional impairment remains a distinct future gate requiring an
ingress/ifb design.
