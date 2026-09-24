# Netem rig

Impairment tooling for the measured gates. Everything here is scoped so
nothing else on the box is impaired: one IPv4 UDP flow enters netem and all
other traffic keeps the interface's normal `fq_codel` behavior.

## `port-netem.sh`

The one netem helper. It shapes a single `(UDP source port, destination
/32)` flow on one interface and owns distinctive qdisc handles (`1a7e:`
root, `1a70:` plain band, `1a7f:` netem) plus an ownership record under
`/run`, so `remove` deletes only a topology it can prove it installed.
`apply` refuses a foreign root qdisc and rolls back a partial install.
Needs root.

```sh
sudo Scripts/netem/port-netem.sh apply <iface> <client-ipv4> <udp-source-port> <delay-ms> <jitter-ms> <loss-pct>
sudo Scripts/netem/port-netem.sh remove <iface>
Scripts/netem/port-netem.sh status <iface>
```

Loopback development (a local sender to a local receiver) uses the same
helper: `apply lo 127.0.0.1 <sender-udp-port> 20 0 1` shapes that sender's
datagrams with 20 ms delay and 1% loss. It matches the sender's source port,
not the receiver's destination port.

## `Scripts/benchmark-netem.sh`

The real-client impairment SLO leg. It uploads `port-netem.sh` to pup,
shapes host→client egress for `LYTE_BENCHMARK_PORT`, runs one
`benchmark-app.sh motion` leg against that same port, and judges the
impairment SLOs. Feedback toward the host is not shaped; bidirectional
impairment needs an ingress/ifb design and is a separate future gate.

The impaired port and the benchmarked port are one value, and both scripts
refuse to run unless `lyte-host.service` owns it on pup. The app dials its
pinned host on the standing port, so today the only measurable flow is
41151, which also requires `LYTE_BENCHMARK_ALLOW_STANDING_PORT=1`:

```sh
LYTE_BENCHMARK_PORT=41151 LYTE_BENCHMARK_ALLOW_STANDING_PORT=1 \
    Scripts/benchmark-netem.sh moderate
```

The cleanup trap is armed before the remote apply, so an interrupted run or
a dropped ssh still removes the qdisc; the run refuses to start if a
`port-netem` qdisc is already present. `LYTE_PUP_HOST` selects the host for
both the shaping and the benchmark.
