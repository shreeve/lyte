#!/bin/sh
# Loopback netem helper (HS-4): apply/remove a delay/loss profile on lo,
# scoped to ONE UDP destination port so nothing else on the machine is
# touched — in particular the Sunshine service, which speaks on the LAN
# interface and is never impaired by anything this script does.
#
# Runs on the host machine, as root:
#   sudo Scripts/netem/lo-netem.sh apply <udp-port> [delay-ms] [loss-pct]
#   sudo Scripts/netem/lo-netem.sh remove
#   Scripts/netem/lo-netem.sh status
# or from the dev machine:
#   ssh pup 'sudo -n sh -s -- apply 47999 20' < Scripts/netem/lo-netem.sh
#
# Mechanism: a prio qdisc on lo's root whose priomap sends ALL traffic to
# band 1 (plain pfifo, unimpaired); a u32 filter steers only UDP datagrams
# to the given destination port into band 3, where netem lives. Removal
# deletes the root qdisc, restoring lo's default (noqueue).
#
# The full per-gate profiles (R-G1..G8, on the LAN interface with client-IP
# filters and ifb for the reverse direction) come with the congestion
# slices; this is only the loopback variant for pre-client development.

set -eu

DEV=lo

usage() {
    echo "usage: $0 apply <udp-port> [delay-ms] [loss-pct] | remove | status" >&2
    exit 2
}

[ $# -ge 1 ] || usage
cmd=$1

case "$cmd" in
apply)
    [ $# -ge 2 ] || usage
    port=$2
    delay_ms=${3:-20}
    loss_pct=${4:-0}

    # Refuse to clobber a root qdisc we did not install.
    existing=$(tc qdisc show dev "$DEV" | head -1)
    case "$existing" in
    "qdisc noqueue 0: root"*|"qdisc pfifo_fast 0: root"*) ;;
    "qdisc prio 1: root"*)
        echo "lo-netem: a profile is already applied — run '$0 remove' first" >&2
        exit 1
        ;;
    *)
        echo "lo-netem: unexpected root qdisc on $DEV: $existing" >&2
        exit 1
        ;;
    esac

    netem_args="delay ${delay_ms}ms"
    [ "$loss_pct" != "0" ] && netem_args="$netem_args loss ${loss_pct}%"

    # priomap of all zeros: every packet defaults to band 1 (1:1, pfifo,
    # untouched); only the filter below diverts anything into netem.
    tc qdisc add dev "$DEV" root handle 1: prio bands 3 \
        priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$DEV" parent 1:3 handle 30: netem $netem_args
    tc filter add dev "$DEV" parent 1: protocol ip u32 \
        match ip protocol 17 0xff \
        match ip dport "$port" 0xffff \
        flowid 1:3

    echo "lo-netem: applied to $DEV udp dport $port — $netem_args"
    ;;
remove)
    if tc qdisc show dev "$DEV" | head -1 | grep -q "^qdisc prio 1: root"; then
        tc qdisc del dev "$DEV" root
        echo "lo-netem: removed — $DEV restored to default"
    else
        echo "lo-netem: nothing to remove on $DEV"
    fi
    ;;
status)
    tc qdisc show dev "$DEV"
    tc filter show dev "$DEV" 2>/dev/null || true
    ;;
*)
    usage
    ;;
esac
