#!/bin/sh
set -eu

: "${LYTE_FAKE_TC_LOG:?}"
: "${LYTE_FAKE_TC_STATE:?}"

printf '%s\n' "$*" >> "$LYTE_FAKE_TC_LOG"

if [ -n "${LYTE_FAKE_TC_FAIL_CONTAINS:-}" ] \
    && printf '%s\n' "$*" | grep -Fq "$LYTE_FAKE_TC_FAIL_CONTAINS"
then
    exit 19
fi

state=$(cat "$LYTE_FAKE_TC_STATE")
case "$*" in
    "qdisc show dev "*)
        case "$state" in
            default) echo "qdisc fq_codel 0: root refcnt 2" ;;
            owned)
                echo "qdisc prio 1a7e: root refcnt 2 bands 3"
                echo "qdisc fq_codel 1a70: parent 1a7e:1"
                echo "qdisc netem 1a7f: parent 1a7e:3"
                ;;
            owned-changed) echo "qdisc prio 1a7e: root refcnt 2 bands 3" ;;
            foreign) echo "qdisc htb 7: root refcnt 2" ;;
        esac
        ;;
    "qdisc replace dev "*)
        printf '%s\n' owned > "$LYTE_FAKE_TC_STATE"
        ;;
    "qdisc del dev "*)
        printf '%s\n' default > "$LYTE_FAKE_TC_STATE"
        ;;
    "filter show dev "*) echo "filter parent 1a7e: protocol ip pref 49151 u32" ;;
    "qdisc add dev "*|"filter add dev "*) ;;
    *)
        echo "fake-tc: unexpected invocation: $*" >&2
        exit 97
        ;;
esac
