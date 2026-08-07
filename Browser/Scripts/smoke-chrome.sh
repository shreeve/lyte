#!/bin/sh
# Headless Chrome smoke for B-1…B-6 (see smoke.mjs).
# Spawns lyte-control-peer --emit-corpus + lyte-wt-sidecar --udp-peer;
# never uses UDP 41151.
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

if [ ! -f "${BROWSER_ROOT}/.serve/LyteClientBrowser.wasm" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/webtransport-carrier.js" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/control-session.js" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/conductor-video.js" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/interaction.js" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/audio-ring-worklet.js" ] \
    || [ ! -f "${BROWSER_ROOT}/.serve/corpus/frame-000-idr.annexb" ]; then
    echo "browser-smoke: building first…"
    "${BROWSER_ROOT}/Scripts/build.sh"
fi

WT_RUNTIME="${LYTE_WT_RUNTIME:-node}"
case "$WT_RUNTIME" in
    node|bun) ;;
    *)
        echo "browser-smoke: LYTE_WT_RUNTIME must be node or bun (got ${WT_RUNTIME})" >&2
        exit 1
        ;;
esac
command -v node >/dev/null 2>&1 || {
    echo "browser-smoke: node is required" >&2
    exit 1
}
command -v "$WT_RUNTIME" >/dev/null 2>&1 || {
    echo "browser-smoke: ${WT_RUNTIME} is required for wt-sidecar (LYTE_WT_RUNTIME)" >&2
    exit 1
}
export LYTE_WT_RUNTIME="$WT_RUNTIME"
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
