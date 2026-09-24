#!/bin/bash
# The deterministic Linux gate on the reference host. This deliberately does
# not restart or deploy the owner's standing systemd service.
#
# One ssh session runs the whole remote side. It validates the mirror, takes
# an flock on it, waits while this side rsyncs the tree, then builds and
# tests. The lock is held by that session's processes and dies with them,
# and the session terminates its workload as soon as its control channel
# (this script's fd 3) closes, so an interrupted gate never leaves
# `swift test` running in a mirror that the next gate enters.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

pup="${LYTE_PUP_HOST:-pup}"
pup_gate_root="src/lyte-gates/deterministic"
# The packages pup builds. Browser needs Swift 6.2 (JavaScriptKit) and
# SystemTests needs the macOS client, so neither is mirrored.
packages="Client Common Wire Host"
local_state="$(mktemp -d)"
trap 'rm -rf -- "$local_state"' EXIT
lock_token="lyte-pup-gate-locked-$$-$RANDOM$RANDOM"
mkfifo "$local_state/control"

# Remote stdout passes through, except the token line that says the mirror
# is locked and ready to sync.
{
    status=0
    ssh -o ConnectTimeout=10 "$pup" 'bash -s' < "$local_state/control" \
        || status=$?
    echo "$status" 2>/dev/null > "$local_state/remote-status" || true
} | while IFS= read -r line; do
    if [[ "$line" == "$lock_token" ]]; then
        : > "$local_state/locked"
    else
        printf '%s\n' "$line"
    fi
done &
remote_job=$!
exec 3> "$local_state/control"

{
    printf 'lock_token=%q\n' "$lock_token"
    printf 'gate_owner=%q\n' "$(hostname -s):$repo_root (pid $$)"
    printf 'packages=%q\n' "$packages"
    cat <<'REMOTE'
set -euo pipefail
shopt -s inherit_errexit

export LD_LIBRARY_PATH="$HOME/.local/lib/swift-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
namespace="$HOME/src/lyte-gates"
gate_root="$namespace/deterministic"
gate_lock="$namespace/.deterministic.flock"
# Gates from older checkouts lock the mirror with this directory instead.
legacy_lock="$namespace/.deterministic.lock"
holds_legacy_lock=0
package_image_parent=""
watchdog=""
before_state=""
mount_targets=""

fail() {
    echo "pup gate FAILED: $*" >&2
    exit 1
}

# descendants PID: every live process below PID. SwiftPM starts test
# runners in their own process group, so a group signal would miss them.
descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        echo "$child"
        descendants "$child"
    done
}

# real_directory PATH: PATH is a directory (created if absent) that is not a
# symlink, resolves to itself and contains no mount.
real_directory() {
    local path="$1" mounted
    if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
        fail "gate path is not a real directory: $path"
    fi
    while IFS= read -r mounted; do
        case "$mounted" in
            "$path"|"$path"/*) fail "gate path contains a mount: $mounted" ;;
        esac
    done <<< "$mount_targets"
    mkdir -p "$path"
    [[ "$(readlink -f -- "$path")" == "$path" ]] \
        || fail "gate path resolves elsewhere: $path"
}

# Identity, the service's knobs, the deployed version and the installed unit
# must be byte-identical after the gate. The XDG identity and host.conf are
# required; pre-XDG copies are covered whenever they exist.
protected_state_fingerprint() {
    local config="$HOME/.config/lyte" file
    for file in noise_static.key paired_clients host.conf; do
        if [[ ! -f "$config/$file" ]]; then
            echo "pup gate FAILED: required $config/$file is missing" >&2
            return 1
        fi
    done
    {
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
                echo "absent $file"
            elif [[ -r "$file" ]]; then
                sha256sum "$file"
                stat -c '%n %a %U %G %s' "$file"
            else
                sudo -n sha256sum "$file"
                sudo -n stat -c '%n %a %U %G %s' "$file"
            fi
        done
        echo "link $(readlink -- "$HOME/.local/bin/lyte-host" || echo absent)"
    } | sha256sum | awk '{print $1}'
}

verify_protected_state() {
    local after_state
    after_state="$(protected_state_fingerprint)" || return 1
    if [[ "$before_state" != "$after_state" ]]; then
        echo "pup gate FAILED: protected host state or metadata changed" >&2
        return 1
    fi
}

on_remote_exit() {
    local status=$?
    trap - EXIT
    trap '' PIPE
    set +e
    if [[ -n "$watchdog" ]]; then
        kill "$watchdog" 2>/dev/null
    fi
    if [[ -n "$package_image_parent" && -d "$package_image_parent" ]]; then
        case "$(readlink -f -- "$package_image_parent")" in
            /tmp/lyte-host-image.*)
                find "$package_image_parent" -xdev -depth -delete
                ;;
            *)
                echo "pup gate FAILED: package-image cleanup escaped /tmp" >&2
                status=1
                ;;
        esac
    fi
    if [[ -n "$before_state" ]] && ! verify_protected_state; then
        status=1
    fi
    if (( holds_legacy_lock )); then
        rmdir -- "$legacy_lock"
    fi
    exit "$status"
}
trap on_remote_exit EXIT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 141' PIPE

# run_package_tests PACKAGE [--build-only TARGET...]: resolve PACKAGE, then
# test it (or build only TARGETs), cleaning its build state first when its
# build graph changed.
run_package_tests() {
    local package="$1" path="$gate_root/$1" target
    shift
    local marker="$path/.build/.lyte-build-graph-sha256"
    local build_graph_hash installed_hash=""
    build_graph_hash="$(lyte_build_graph_hash "$gate_root" "$package")"

    if [[ "${1:-}" == --build-only ]]; then
        shift
        echo "==> $package builds: $*"
    else
        echo "==> $package tests"
    fi
    if [[ -f "$marker" ]]; then
        installed_hash="$(<"$marker")"
    fi
    if [[ "$installed_hash" != "$build_graph_hash" ]]; then
        echo "    package or source-path graph changed; invalidating stale SwiftPM build state"
        (cd "$path" && swift package clean)
    fi
    (cd "$path" && swift package resolve)
    if (( $# )); then
        for target in "$@"; do
            (cd "$path" \
                && swift build --target "$target" -Xswiftc -warnings-as-errors)
        done
    else
        (cd "$path" && swift test -Xswiftc -warnings-as-errors)
    fi
    mkdir -p "$path/.build"
    printf '%s\n' "$build_graph_hash" > "$marker"
}

main() {
    local go="" package

    command -v findmnt >/dev/null 2>&1 \
        || fail "findmnt is required for deletion safety"
    command -v flock >/dev/null 2>&1 || fail "flock is required to lock the mirror"
    mount_targets="$(findmnt -rn -o TARGET)" \
        || fail "cannot inspect mounted filesystems"
    real_directory "$namespace"
    exec 9>>"$gate_lock"
    if ! flock -n 9; then
        fail "another deterministic gate holds the pup mirror: $(cat "$gate_lock")"
    fi
    printf '%s, since %s\n' "$gate_owner" "$(date -u +%FT%TZ)" > "$gate_lock"
    if ! mkdir -- "$legacy_lock" 2>/dev/null; then
        fail "a gate from an older checkout holds $legacy_lock" \
            "(rmdir it if no such gate is running)"
    fi
    holds_legacy_lock=1
    real_directory "$gate_root"
    for package in $packages Scripts docs; do
        real_directory "$gate_root/$package"
    done

    # The mirror is ours: let the local side sync it, then run. From here on
    # the end of the control channel means the local gate is gone.
    echo "$lock_token"
    read -r go || true
    [[ "$go" == go ]] || fail "the local gate ended before its sync finished"
    exec 8<&0
    (
        exec 9>&-
        while read -r _ <&8; do :; done
        kill -TERM $(descendants $$ | grep -vx "$BASHPID") $$
    ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
    exec 8<&-

    source "$gate_root/Scripts/lib/build-graph.sh"
    before_state="$(protected_state_fingerprint)"

    run_package_tests Common
    run_package_tests Wire
    # Client's manifest declares its macOS targets on every platform, so
    # only the IO-free policy targets build here.
    run_package_tests Client
    run_package_tests Host

    echo "==> plain Host build"
    (cd "$gate_root/Host" && swift build -Xswiftc -warnings-as-errors)

    echo "==> release Host build"
    (cd "$gate_root/Host" \
        && swift build -c release -Xswiftc -warnings-as-errors)

    local host_binary="$gate_root/Host/.build/release/lyte-host"
    local audio_check_binary="$gate_root/Host/.build/release/lyte-audio-check"
    local tests="$gate_root/Scripts/Tests"
    [[ -x "$host_binary" ]] || fail "no release lyte-host"
    [[ -x "$audio_check_binary" ]] || fail "no release lyte-audio-check"

    echo "==> rootless Linux host release image"
    package_image_parent="$(mktemp -d -t lyte-host-image.XXXXXX)"
    local package_image="$package_image_parent/root"
    LYTE_REPOSITORY_ROOT="$gate_root" \
        "$gate_root/Host/Scripts/stage-host-image.sh" "$package_image"
    "$tests/test-host-package-image.sh" "$package_image"
    "$tests/test-host-installer.sh" "$package_image"
    "$tests/test-host-installer.sh" --self-test
    "$tests/test-hermetic-linkage.sh" "$package_image/bin/lyte-host"
    find "$package_image_parent" -xdev -depth -delete
    package_image_parent=""

    # Output is captured before grep: with pipefail, `grep -q` exiting early
    # can SIGPIPE the producer and turn a match into a failed pipeline.
    local libraries symbols binary
    libraries="$(ldd "$host_binary")"
    if grep -Eiq 'libav(codec|device|filter|format|util)|libswresample|libswscale' \
        <<< "$libraries"
    then
        fail "lyte-host regained a media-library dependency"
    fi

    "$tests/test-hermetic-linkage.sh" "$host_binary" "$audio_check_binary"
    for binary in "$host_binary" "$audio_check_binary"; do
        symbols="$(nm -g --defined-only "$binary")"
        grep -Eq ' opus_encode_float$' <<< "$symbols" \
            || fail "pinned Opus encoder absent from $binary"
    done

    echo "==> Linux socket and pacing harnesses"
    "$gate_root/Host/.build/debug/lyte-netio-check"
    "$gate_root/Host/.build/debug/lyte-pace-check"

    verify_protected_state || exit 1
    before_state=""
    echo "pup gate PASSED; protected host state is unchanged"
}

main; exit
REMOTE
} >&3

until [[ -e "$local_state/locked" || -e "$local_state/remote-status" ]]; do
    sleep 0.1
done
if [[ ! -e "$local_state/locked" ]]; then
    wait "$remote_job" || true
    exit 1
fi

echo "==> sync $packages and Scripts to $pup:$pup_gate_root"
for package in $packages; do
    rsync -a --delete --exclude .build \
        "$package/" "$pup:$pup_gate_root/$package/"
done
rsync -a --delete Scripts/ "$pup:$pup_gate_root/Scripts/"
rsync -a LICENSE "$pup:$pup_gate_root/LICENSE"
rsync -a docs/THIRD-PARTY.md "$pup:$pup_gate_root/docs/THIRD-PARTY.md"
echo go >&3

wait "$remote_job" || true
remote_status="$(cat "$local_state/remote-status" 2>/dev/null || echo 1)"
exit "$remote_status"
