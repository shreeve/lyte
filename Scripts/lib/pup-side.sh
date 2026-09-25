#!/bin/bash
# Functions that run on pup, sent ahead of the command that uses them
# (pup_run in lib/pup.sh; the pup gate sends this file inline). Every
# failure is an explicit return, so they hold without `set -e`.

# lyte_protected_state_fingerprint: one digest of everything a run that
# approaches host identity must leave byte-identical: the identity and the
# service's knobs (XDG and pre-XDG), the system config, the installed unit
# and the deployed link. The XDG identity and host.conf must exist.
lyte_protected_state_fingerprint() {
    local config="$HOME/.config/lyte" file
    for file in noise_static.key paired_clients host.conf; do
        if [[ ! -f "$config/$file" ]]; then
            echo "protected state: required $config/$file is missing" >&2
            return 1
        fi
    done
    local listing="" line
    for file in \
        "$config/noise_static.key" \
        "$config/paired_clients" \
        "$config/host.conf" \
        "$HOME/.config/lyte-host/noise_static.key" \
        "$HOME/.config/lyte-host/paired_clients" \
        /etc/lyte/lyte-host.conf \
        /etc/systemd/system/lyte-host.service
    do
        if [[ ! -e "$file" ]]; then
            line="absent $file"
        elif [[ -r "$file" ]]; then
            line="$(sha256sum "$file" && stat -c '%n %a %U %G %s' "$file")" \
                || line=""
        else
            line="$(sudo -n sha256sum "$file" \
                && sudo -n stat -c '%n %a %U %G %s' "$file")" || line=""
        fi
        # A file that exists but cannot be read is a fingerprint that
        # cannot prove it unchanged: refuse rather than leave it out.
        if [[ -z "$line" ]]; then
            echo "protected state: cannot read $file" >&2
            return 1
        fi
        listing+="$line"$'\n'
    done
    listing+="link $(readlink -- "$HOME/.local/bin/lyte-host" || echo absent)"
    printf '%s\n' "$listing" | sha256sum | awk '{print $1}'
}

# lyte_host_main_pid: the MainPID of an active lyte-host.service.
lyte_host_main_pid() {
    local pid
    systemctl is-active --quiet lyte-host || return 1
    pid="$(systemctl show lyte-host --property MainPID --value)" || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

# lyte_host_owns_port PORT PID: PID has UDP PORT open.
lyte_host_owns_port() {
    local sockets
    sockets="$(sudo -n ss -H -lunp "sport = :$1")" || return 1
    grep -q "pid=$2," <<< "$sockets"
}

# lyte_host_exe_sha PID: the SHA-256 of PID's executable. A capability-tagged
# host refuses same-uid readers of /proc/PID/exe; sudo -n reads it then.
lyte_host_exe_sha() {
    { sha256sum "/proc/$1/exe" 2>/dev/null \
        || sudo -n sha256sum "/proc/$1/exe"; } | awk '{print $1}'
}

# lyte_deployed_host_sha: the SHA-256 of the binary ~/.local/bin/lyte-host
# names.
lyte_deployed_host_sha() {
    sha256sum "$(readlink -f "$HOME/.local/bin/lyte-host")" | awk '{print $1}'
}

# lyte_host_snapshot: evidence of the service at one instant: the time, its
# process and executable digest, the deployed digest, UDP sockets and link
# counters.
lyte_host_snapshot() {
    local pid
    date -u +%FT%TZ
    if pid="$(lyte_host_main_pid)"; then
        ps -o pid,lstart,args -p "$pid"
        lyte_host_exe_sha "$pid"
    fi
    lyte_deployed_host_sha
    ss -u -a -n -p
    ip -s link show
}

# lyte_restart_host PORT: restarts lyte-host.service and waits for a fresh
# MainPID that owns UDP PORT and runs the deployed binary; prints
# "BEFORE AFTER".
lyte_restart_host() {
    local before after running _
    before="$(lyte_host_main_pid)" || {
        echo "lyte-host.service is not active" >&2
        return 1
    }
    sudo -n systemctl restart lyte-host || return 1
    for _ in $(seq 100); do
        if after="$(lyte_host_main_pid)" && [[ "$after" != "$before" ]] \
            && lyte_host_owns_port "$1" "$after"
        then
            running="$(lyte_host_exe_sha "$after")"
            if [[ -z "$running" || "$running" != "$(lyte_deployed_host_sha)" ]]
            then
                echo "fresh service process is not the deployed host" >&2
                return 1
            fi
            printf '%s %s\n' "$before" "$after"
            return 0
        fi
        sleep 0.1
    done
    echo "lyte-host.service did not publish a fresh active MainPID" >&2
    return 1
}
