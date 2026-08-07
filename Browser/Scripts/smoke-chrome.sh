#!/bin/sh
# Headless Chrome smoke for B-1 (see smoke.mjs).
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

if [ ! -f "${BROWSER_ROOT}/.serve/LyteClientBrowser.wasm" ]; then
    echo "browser-smoke: building first…"
    "${BROWSER_ROOT}/Scripts/build.sh"
fi

command -v node >/dev/null 2>&1 || {
    echo "browser-smoke: node is required" >&2
    exit 1
}

exec node "${BROWSER_ROOT}/Scripts/smoke.mjs"
