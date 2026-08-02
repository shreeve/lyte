#!/bin/sh
# H2 joint gate netem helper (as run on pup for the H2 joint gate; report in git history):
# the lo-netem.sh prio+u32 pattern on the LAN interface, scoped STRICTLY to
# udp dport 41091 (the gate port); "apply video ..." further scopes to
# dsfield 0xa0 so audio/CTRL ride untouched. blackout-in adds/removes an
# iptables INPUT drop for the reverse direction of a full blackout.
# Sunshine (47998-48010) is never matched by anything here.
set -eu
DEV=wlp0s20f3
PORT=41091
cmd=$1
case "$cmd" in
apply)
    # apply <netem-args...> [video]  — "video" scopes to dsfield 0xa0
    shift
    scope=all
    if [ "${1:-}" = "video" ]; then scope=video; shift; fi
    existing=$(tc qdisc show dev "$DEV" | head -1)
    case "$existing" in
    "qdisc noqueue 0: root"*|"qdisc pfifo_fast 0: root"*|"qdisc fq_codel"*) ;;
    "qdisc prio 1: root"*)
        echo "h2netem: profile already applied — remove first" >&2; exit 1 ;;
    *)
        echo "h2netem: unexpected root qdisc: $existing" >&2; exit 1 ;;
    esac
    tc qdisc add dev "$DEV" root handle 1: prio bands 3 \
        priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    tc qdisc add dev "$DEV" parent 1:3 handle 30: netem "$@"
    if [ "$scope" = video ]; then
        tc filter add dev "$DEV" parent 1: protocol ip u32 \
            match ip protocol 17 0xff \
            match ip dsfield 0xa0 0xff \
            match ip dport $PORT 0xffff \
            flowid 1:3
    else
        tc filter add dev "$DEV" parent 1: protocol ip u32 \
            match ip protocol 17 0xff \
            match ip dport $PORT 0xffff \
            flowid 1:3
    fi
    echo "h2netem: applied ($scope) — netem $*"
    ;;
blackout-in)
    iptables -I INPUT -p udp --dport $PORT -j DROP
    echo "h2netem: INPUT drop udp dport $PORT inserted"
    ;;
blackout-in-remove)
    iptables -D INPUT -p udp --dport $PORT -j DROP
    echo "h2netem: INPUT drop removed"
    ;;
remove)
    if tc qdisc show dev "$DEV" | head -1 | grep -q "^qdisc prio 1: root"; then
        tc qdisc del dev "$DEV" root
        echo "h2netem: removed — $DEV restored"
    else
        echo "h2netem: nothing to remove"
    fi
    ;;
status)
    tc qdisc show dev "$DEV"; iptables -L INPUT -n | grep 41091 || true
    ;;
*) echo "usage: apply <args> [video] | blackout-in | blackout-in-remove | remove | status" >&2; exit 2 ;;
esac
