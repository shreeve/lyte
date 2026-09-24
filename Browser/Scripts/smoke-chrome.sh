#!/bin/sh
# Headless Chrome smoke (see smoke.mjs): rebuilds and restages the page and
# WASM, then drives the full session proof against lyte-control-peer
# --emit-corpus through lyte-wt-sidecar --udp-peer on a fresh local port.
# Never uses the standing host UDP 41151.
#
# Environment: LYTE_WT_RUNTIME (node|bun), LYTE_CHROME, LYTE_CONTROL_PEER_PORT,
# LYTE_BROWSER_SMOKE_TIMEOUT_S, LYTE_BROWSER_CONFIGURATION.
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

WT_RUNTIME="${LYTE_WT_RUNTIME:-node}"
case "$WT_RUNTIME" in
    node|bun) ;;
    *)
        echo "browser-smoke: LYTE_WT_RUNTIME must be node or bun (got ${WT_RUNTIME})" >&2
        exit 1
        ;;
esac
for tool in node "$WT_RUNTIME" openssl swift; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "browser-smoke: ${tool} is required" >&2
        exit 1
    }
done
export LYTE_WT_RUNTIME="$WT_RUNTIME"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Always restage: a smoke must never pass against a stale .serve/.
"${BROWSER_ROOT}/Scripts/build.sh"
# build.sh may pick an older host SDK for the pinned wasm toolchain; the
# control peer builds with the Xcode toolchain and its own default SDK.
unset SDKROOT

exec node "${BROWSER_ROOT}/Scripts/smoke.mjs"
