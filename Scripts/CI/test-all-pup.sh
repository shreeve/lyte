#!/bin/bash
# The deterministic Linux gate on the reference host. This deliberately does
# not restart or deploy the owner's standing systemd service.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

pup="${LYTE_PUP_HOST:-pup}"
pup_gate_root="src/lyte-gates/deterministic"
pup_gate_lock="src/lyte-gates/.deterministic.lock"
lock_acquired=0

release_gate_lock() {
    if (( lock_acquired )); then
        ssh "$pup" rmdir -- "$pup_gate_lock" >/dev/null 2>&1 || true
    fi
}
trap release_gate_lock EXIT

if ! ssh "$pup" 'bash -se' <<'PREFLIGHT'
set -euo pipefail
namespace="$HOME/src/lyte-gates"
gate_root="$namespace/deterministic"
gate_lock="$namespace/.deterministic.lock"
mount_targets=""

if ! command -v findmnt >/dev/null 2>&1; then
    echo "pup gate FAILED: findmnt is required for deletion safety" >&2
    exit 1
fi
if ! mount_targets="$(findmnt -rn -o TARGET)"; then
    echo "pup gate FAILED: cannot inspect mounted filesystems" >&2
    exit 1
fi
refuse_mounts_below() {
    local root="$1"
    local mounted
    while IFS= read -r mounted; do
        case "$mounted" in
            "$root"|"$root"/*)
                echo "pup gate FAILED: gate mirror contains a mount: $mounted" >&2
                exit 1
                ;;
        esac
    done <<< "$mount_targets"
}

if [[ -L "$namespace" || ( -e "$namespace" && ! -d "$namespace" ) ]]; then
    echo "pup gate FAILED: fixed gate namespace is not a real directory" >&2
    exit 1
fi
refuse_mounts_below "$namespace"
mkdir -p "$namespace"
if [[ "$(readlink -f -- "$namespace")" != "$HOME/src/lyte-gates" ]]; then
    echo "pup gate FAILED: fixed gate namespace resolves elsewhere" >&2
    exit 1
fi
if [[ -L "$gate_root" || ( -e "$gate_root" && ! -d "$gate_root" ) ]]; then
    echo "pup gate FAILED: fixed gate root is not a real directory" >&2
    exit 1
fi
mkdir -p "$gate_root"
if [[ "$(readlink -f -- "$gate_root")" != "$HOME/src/lyte-gates/deterministic" ]]; then
    echo "pup gate FAILED: fixed gate root resolved outside its namespace" >&2
    exit 1
fi
for package in Client Common Wire Host SystemTests; do
    target="$gate_root/$package"
    if [[ -L "$target" ]]; then
        echo "pup gate FAILED: package mirror is a symlink: $target" >&2
        exit 1
    fi
    if [[ -e "$target" && ! -d "$target" ]]; then
        echo "pup gate FAILED: package mirror is not a directory: $target" >&2
        exit 1
    fi
    if [[ -d "$target" && "$(readlink -f -- "$target")" != "$target" ]]; then
        echo "pup gate FAILED: package mirror resolves elsewhere: $target" >&2
        exit 1
    fi
    refuse_mounts_below "$target"
    mkdir -p "$target"
done
if ! mkdir "$gate_lock"; then
    echo "pup gate FAILED: another deterministic gate holds the pup mirror" >&2
    exit 1
fi
PREFLIGHT
then
    exit 1
fi
lock_acquired=1

echo "==> sync Client, Common, Wire, Host, and SystemTests to $pup:$pup_gate_root"
# Remove only the retired client-package paths inside the validated,
# lock-owned deterministic mirror. They must not survive as a second package.
ssh "$pup" 'bash -se' <<'RETIRE_ROOT_CLIENT'
set -euo pipefail
gate_root="$HOME/src/lyte-gates/deterministic"
if ! command -v findmnt >/dev/null 2>&1; then
    echo "pup gate FAILED: findmnt is required for deletion safety" >&2
    exit 1
fi
if [[ "$(readlink -f -- "$gate_root")" != "$HOME/src/lyte-gates/deterministic" ]]; then
    echo "pup gate FAILED: refusing to retire paths outside the gate mirror" >&2
    exit 1
fi
for path in Package.swift Package.resolved Sources Tests; do
    target="$gate_root/$path"
    if [[ -L "$target" ]]; then
        echo "pup gate FAILED: stale root client path is a symlink: $target" >&2
        exit 1
    fi
done
if ! mount_targets="$(findmnt -rn -o TARGET)"; then
    echo "pup gate FAILED: cannot inspect mounted filesystems" >&2
    exit 1
fi
while IFS= read -r mounted; do
    case "$mounted" in
        "$gate_root/Sources"|"$gate_root/Sources"/*|\
        "$gate_root/Tests"|"$gate_root/Tests"/*)
            echo "pup gate FAILED: stale root client tree contains a mount: $mounted" >&2
            exit 1
            ;;
    esac
done <<< "$mount_targets"
rm -f -- "$gate_root/Package.swift" "$gate_root/Package.resolved"
for directory in "$gate_root/Sources" "$gate_root/Tests"; do
    if [[ -d "$directory" ]]; then
        find "$directory" -xdev -depth -delete
    elif [[ -e "$directory" ]]; then
        echo "pup gate FAILED: stale root client path is not a directory: $directory" >&2
        exit 1
    fi
done
RETIRE_ROOT_CLIENT
rsync -a --delete --exclude .build Client/ "$pup:$pup_gate_root/Client/"
rsync -a --delete --exclude .build Common/ "$pup:$pup_gate_root/Common/"
rsync -a --delete --exclude .build Wire/ "$pup:$pup_gate_root/Wire/"
rsync -a --delete --exclude .build Host/ "$pup:$pup_gate_root/Host/"
rsync -a --delete --exclude .build \
    SystemTests/ "$pup:$pup_gate_root/SystemTests/"
rsync -a Scripts/Tests/test-hermetic-linkage.sh \
    "$pup:$pup_gate_root/test-hermetic-linkage.sh"
ssh "$pup" mkdir -p -- "$pup_gate_root/Scripts"
rsync -a Scripts/verify-opus-upstream.sh \
    "$pup:$pup_gate_root/Scripts/verify-opus-upstream.sh"

ssh "$pup" 'bash -se' <<'REMOTE'
set -euo pipefail

export LD_LIBRARY_PATH="$HOME/.local/lib/swift-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
gate_root="$HOME/src/lyte-gates/deterministic"

protected_state_fingerprint() {
    local config="$HOME/.config/lyte-host"
    test -f "$config/portal_token"
    test -f "$config/noise_static.key"
    test -f "$config/paired_clients"
    sudo -n test -f /etc/lyte/lyte-host.conf

    {
        sha256sum \
            "$config/portal_token" \
            "$config/noise_static.key" \
            "$config/paired_clients"
        stat -c '%n %a %U %G %s' \
            "$config/portal_token" \
            "$config/noise_static.key" \
            "$config/paired_clients"
        sudo -n sha256sum /etc/lyte/lyte-host.conf
        sudo -n stat -c '%n %a %U %G %s' /etc/lyte/lyte-host.conf
    } | sha256sum | awk '{print $1}'
}

before_state="$(protected_state_fingerprint)"

verify_protected_state() {
    local after_state
    after_state="$(protected_state_fingerprint)"
    if [[ "$before_state" != "$after_state" ]]; then
        echo "pup gate FAILED: protected host state or metadata changed" >&2
        return 1
    fi
}
on_remote_exit() {
    local status=$?
    trap - EXIT
    if ! verify_protected_state; then
        exit 1
    fi
    exit "$status"
}
trap on_remote_exit EXIT

build_graph_hash="$({
    for manifest in \
        "$gate_root/Client/Package.swift" \
        "$gate_root/Client/Package.resolved" \
        "$gate_root/Common/Package.swift" \
        "$gate_root/Common/Package.resolved" \
        "$gate_root/Wire/Package.swift" \
        "$gate_root/Wire/Package.resolved" \
        "$gate_root/Host/Package.swift" \
        "$gate_root/Host/Package.resolved" \
        "$gate_root/SystemTests/Package.swift" \
        "$gate_root/SystemTests/Package.resolved"
    do
        if [[ -f "$manifest" ]]; then
            sha256sum "$manifest"
        fi
    done

    # A source-only layout change leaves Package.swift untouched, but old
    # SwiftPM workspaces can still name the removed dependency paths. Include
    # the structural source graph so the shared Linux mirror invalidates that
    # stale state before testing dependents.
    cd "$gate_root"
    for package_root in Client Common Wire Host SystemTests; do
        for tree in Sources Tests Plugins; do
            source_root="$package_root/$tree"
            if [[ -d "$source_root" ]]; then
                find "$source_root" -type f -print
            fi
        done
    done | LC_ALL=C sort
} | sha256sum | awk '{print $1}')"

run_package_tests() {
    local label="$1"
    local path="$2"
    local marker="$path/.build/.lyte-build-graph-sha256"
    local installed_hash=""

    echo "==> $label tests"
    if [[ -f "$marker" ]]; then
        installed_hash="$(<"$marker")"
    fi
    if [[ "$installed_hash" != "$build_graph_hash" ]]; then
        echo "    package or source-path graph changed; invalidating stale SwiftPM build state"
        (cd "$path" && swift package clean)
    fi
    (cd "$path" && swift package resolve \
        && swift test -Xswiftc -warnings-as-errors)
    mkdir -p "$path/.build"
    printf '%s\n' "$build_graph_hash" > "$marker"
}

run_package_tests "Common" "$gate_root/Common"
run_package_tests "Wire" "$gate_root/Wire"
run_package_tests "Host" "$gate_root/Host"

echo "==> plain Host build"
(cd "$gate_root/Host" && swift build -Xswiftc -warnings-as-errors)

echo "==> release Host build"
(cd "$gate_root/Host" \
    && swift build -c release -Xswiftc -warnings-as-errors)

host_binary="$gate_root/Host/.build/release/lyte-host"
audio_check_binary="$gate_root/Host/.build/release/lyte-audio-check"
test -x "$host_binary"
test -x "$audio_check_binary"

if ldd "$host_binary" \
    | grep -Eiq 'libav(codec|device|filter|format|util)|libswresample|libswscale'
then
    echo "pup gate FAILED: lyte-host regained a media-library dependency" >&2
    exit 1
fi

"$gate_root/test-hermetic-linkage.sh" "$host_binary" "$audio_check_binary"
for binary in "$host_binary" "$audio_check_binary"; do
    symbols="$(nm -g --defined-only "$binary")"
    if ! grep -Eq ' opus_encode_float$' <<< "$symbols"; then
        echo "pup gate FAILED: pinned Opus encoder absent from $binary" >&2
        exit 1
    fi
done

echo "==> Linux socket and pacing harnesses"
"$gate_root/Host/.build/debug/lyte-netio-check"
"$gate_root/Host/.build/debug/lyte-pace-check"

verify_protected_state
trap - EXIT

echo "pup gate PASSED; protected host state is unchanged"
REMOTE

release_gate_lock
lock_acquired=0
trap - EXIT
