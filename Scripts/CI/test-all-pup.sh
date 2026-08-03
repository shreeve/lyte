#!/bin/bash
# The deterministic Linux gate on the reference host. This deliberately does
# not restart or deploy the owner's standing systemd service.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

pup="${LYTE_PUP_HOST:-pup}"

echo "==> sync Common, Wire, and Host to $pup"
rsync -a --delete --exclude .build Common/ "$pup:src/Common/"
rsync -a --delete --exclude .build Wire/ "$pup:src/Wire/"
rsync -a --delete --exclude .build Host/ "$pup:src/lyte-host/"

ssh "$pup" 'bash -se' <<'REMOTE'
set -euo pipefail

export LD_LIBRARY_PATH="$HOME/.local/lib/swift-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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

echo "==> Common tests"
(cd "$HOME/src/Common" && swift test)

echo "==> Wire tests"
(cd "$HOME/src/Wire" && swift test)

echo "==> Host tests"
(cd "$HOME/src/lyte-host" && swift test)

echo "==> plain Host build"
(cd "$HOME/src/lyte-host" && swift build)

host_binary="$HOME/src/lyte-host/.build/debug/lyte-host"
test -x "$host_binary"

if ldd "$host_binary" \
    | grep -Eiq 'libav(codec|device|filter|format|util)|libswresample|libswscale'
then
    echo "pup gate FAILED: lyte-host regained a media-library dependency" >&2
    exit 1
fi

echo "==> Linux socket and pacing harnesses"
"$HOME/src/lyte-host/.build/debug/lyte-netio-check"
"$HOME/src/lyte-host/.build/debug/lyte-pace-check"

after_state="$(protected_state_fingerprint)"
if [[ "$before_state" != "$after_state" ]]; then
    echo "pup gate FAILED: protected host state or metadata changed" >&2
    exit 1
fi

echo "pup gate PASSED; protected host state is unchanged"
REMOTE
