#!/bin/sh
# Headless Chrome smoke for B-1 + B-3 (see smoke.mjs).
# Spawns lyte-control-peer + lyte-wt-sidecar --udp-peer; never uses UDP 41151.
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

if [ ! -f "${BROWSER_ROOT}/.serve/LyteClientBrowser.wasm" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/webtransport-carrier.js" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/control-session.js" ]; then
    echo "browser-smoke: building first…"
    "${BROWSER_ROOT}/Scripts/build.sh"
fi

command -v node >/dev/null 2>&1 || {
    echo "browser-smoke: node is required" >&2
    exit 1
}
command -v openssl >/dev/null 2>&1 || {
    echo "browser-smoke: openssl is required for wt-sidecar cert" >&2
    exit 1
}
command -v swift >/dev/null 2>&1 || {
    echo "browser-smoke: swift is required to build lyte-control-peer" >&2
    exit 1
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

exec node "${BROWSER_ROOT}/Scripts/smoke.mjs"
