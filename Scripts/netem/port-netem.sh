#!/bin/sh
# Apply netem to one IPv4 UDP flow without impairing unrelated traffic.
# The helper owns distinctive qdisc handles and refuses to remove any
# topology it cannot prove is its own.
set -eu

TC=${LYTE_TC:-tc}
ROOT_HANDLE=1a7e:
PLAIN_HANDLE=1a70:
NETEM_HANDLE=1a7f:
STATE_DIR=${LYTE_NETEM_STATE_DIR:-/run}

usage() {
    echo "usage: $0 apply <interface> <client-ipv4> <udp-source-port> <delay-ms> <jitter-ms> <loss-pct> | remove <interface> | status <interface>" >&2
    exit 2
}

valid_interface() {
    case "$1" in
        ""|*[!A-Za-z0-9_.:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    '
}

valid_uint() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

root_qdisc() {
    "$TC" qdisc show dev "$1" | head -1
}

state_path() {
    printf '%s/lyte-port-netem-%s.state\n' "$STATE_DIR" "$1"
}

[ $# -ge 1 ] || usage
command=$1
shift

case "$command" in
apply)
    [ $# -eq 6 ] || usage
    interface=$1
    client_ip=$2
    source_port=$3
    delay_ms=$4
    jitter_ms=$5
    loss_pct=$6

    valid_interface "$interface" || usage
    valid_ipv4 "$client_ip" || usage
    valid_uint "$source_port" && [ "$source_port" -ge 1 ] \
        && [ "$source_port" -le 65535 ] || usage
    valid_uint "$delay_ms" && valid_uint "$jitter_ms" \
        && valid_uint "$loss_pct" && [ "$loss_pct" -le 100 ] || usage
    state=$(state_path "$interface")
    [ ! -e "$state" ] || {
        echo "port-netem: ownership record already exists: $state" >&2
        exit 1
    }

    existing=$(root_qdisc "$interface")
    case "$existing" in
        "qdisc fq_codel 0: root"*|"qdisc noqueue 0: root"*) ;;
        "qdisc prio $ROOT_HANDLE root"*)
            echo "port-netem: profile already installed on $interface" >&2
            exit 1
            ;;
        *)
            echo "port-netem: refusing foreign root qdisc on $interface: $existing" >&2
            exit 1
            ;;
    esac

    rollback=1
    trap '
        if [ "$rollback" -eq 1 ]; then
            "$TC" qdisc del dev "$interface" root 2>/dev/null || true
            rm -f "$state"
        fi
    ' EXIT HUP INT TERM

    # Unmatched traffic retains pup's normal fq_codel behavior in band 1.
    # Only the exact Lyte host→client flow enters band 3/netem.
    "$TC" qdisc replace dev "$interface" root handle "$ROOT_HANDLE" \
        prio bands 3 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    "$TC" qdisc add dev "$interface" parent "${ROOT_HANDLE}1" \
        handle "$PLAIN_HANDLE" fq_codel
    "$TC" qdisc add dev "$interface" parent "${ROOT_HANDLE}3" \
        handle "$NETEM_HANDLE" netem \
        delay "${delay_ms}ms" "${jitter_ms}ms" loss "${loss_pct}%"
    "$TC" filter add dev "$interface" parent "$ROOT_HANDLE" \
        protocol ip priority 49151 u32 \
        match ip protocol 17 0xff \
        match ip sport "$source_port" 0xffff \
        match ip dst "$client_ip/32" \
        flowid "${ROOT_HANDLE}3"

    installed=$(root_qdisc "$interface")
    case "$installed" in
        "qdisc prio $ROOT_HANDLE root"*) ;;
        *)
            echo "port-netem: installed topology failed ownership check" >&2
            exit 1
            ;;
    esac
    umask 077
    mkdir -p "$STATE_DIR"
    printf '%s %s %s %s %s\n' \
        "$client_ip" "$source_port" "$delay_ms" "$jitter_ms" "$loss_pct" \
        > "$state"
    rollback=0
    trap - EXIT HUP INT TERM
    echo "port-netem: $interface udp sport $source_port to $client_ip — delay ${delay_ms}ms ${jitter_ms}ms loss ${loss_pct}%"
    ;;
remove)
    [ $# -eq 1 ] || usage
    interface=$1
    valid_interface "$interface" || usage
    state=$(state_path "$interface")
    existing=$(root_qdisc "$interface")
    case "$existing" in
        "qdisc prio $ROOT_HANDLE root"*)
            [ -f "$state" ] || {
                echo "port-netem: refusing unowned $ROOT_HANDLE topology on $interface" >&2
                exit 1
            }
            qdiscs=$("$TC" qdisc show dev "$interface")
            filters=$("$TC" filter show dev "$interface" \
                parent "$ROOT_HANDLE" 2>/dev/null || true)
            case "$qdiscs" in
                *"qdisc fq_codel $PLAIN_HANDLE"*"parent ${ROOT_HANDLE}1"*) ;;
                *)
                    echo "port-netem: refusing changed owned topology on $interface" >&2
                    exit 1
                    ;;
            esac
            case "$qdiscs" in
                *"qdisc netem $NETEM_HANDLE"*"parent ${ROOT_HANDLE}3"*) ;;
                *)
                    echo "port-netem: refusing changed owned topology on $interface" >&2
                    exit 1
                    ;;
            esac
            [ -n "$filters" ] || {
                echo "port-netem: refusing topology without its flow filter" >&2
                exit 1
            }
            "$TC" qdisc del dev "$interface" root
            rm -f "$state"
            restored=$(root_qdisc "$interface")
            case "$restored" in
                *"$ROOT_HANDLE"*)
                    echo "port-netem: owned qdisc remains on $interface" >&2
                    exit 1
                    ;;
            esac
            echo "port-netem: removed from $interface — default root restored"
            ;;
        *)
            [ ! -e "$state" ] || {
                echo "port-netem: stale ownership record without owned qdisc: $state" >&2
                exit 1
            }
            echo "port-netem: nothing owned on $interface"
            ;;
    esac
    ;;
status)
    [ $# -eq 1 ] || usage
    interface=$1
    valid_interface "$interface" || usage
    "$TC" qdisc show dev "$interface"
    "$TC" filter show dev "$interface" parent "$ROOT_HANDLE" 2>/dev/null || true
    state=$(state_path "$interface")
    if [ -f "$state" ]; then
        echo "ownership: $(cat "$state")"
    fi
    ;;
*)
    usage
    ;;
esac
