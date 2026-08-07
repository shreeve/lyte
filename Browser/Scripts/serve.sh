#!/bin/sh
# Serve Browser/.serve/ and start the same-box WebTransport↔UDP sidecar
# for the B-2 Chrome proof. Requires a prior Browser/Scripts/build.sh.
# Binds 127.0.0.1 only. Does not touch standing host UDP 41151.
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SERVE_DIR="${BROWSER_ROOT}/.serve"
PORT="${LYTE_BROWSER_PORT:-8765}"
META_OUT="${SERVE_DIR}/wt-sidecar.json"
SIDECAR_LOG="${SERVE_DIR}/wt-sidecar.log"
SIDECAR_PID=""

if [ ! -f "${SERVE_DIR}/index.html" ] \
    || [ ! -f "${SERVE_DIR}/LyteClientBrowser.wasm" ] \
    || [ ! -f "${SERVE_DIR}/webtransport-carrier.js" ]; then
    echo "browser-serve: missing staged tree — run Browser/Scripts/build.sh first" >&2
    exit 1
fi

command -v node >/dev/null 2>&1 || {
    echo "browser-serve: node is required for wt-sidecar" >&2
    exit 1
}
command -v openssl >/dev/null 2>&1 || {
    echo "browser-serve: openssl is required to mint the sidecar cert" >&2
    exit 1
}

cleanup() {
    if [ -n "${SIDECAR_PID}" ] && kill -0 "${SIDECAR_PID}" 2>/dev/null; then
        kill "${SIDECAR_PID}" 2>/dev/null || true
        wait "${SIDECAR_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "browser-serve: starting lyte-wt-sidecar (opaque WT↔UDP datagram relay)…"
node "${BROWSER_ROOT}/Scripts/wt-sidecar.mjs" --meta-out "${META_OUT}" \
    >"${SIDECAR_LOG}" 2>&1 &
SIDECAR_PID=$!

# Wait briefly for meta so the page can dial immediately.
i=0
while [ "$i" -lt 50 ]; do
    if [ -f "${META_OUT}" ]; then
        break
    fi
    if ! kill -0 "${SIDECAR_PID}" 2>/dev/null; then
        echo "browser-serve: wt-sidecar exited early — see ${SIDECAR_LOG}" >&2
        cat "${SIDECAR_LOG}" >&2 || true
        exit 1
    fi
    i=$((i + 1))
    sleep 0.1
done
if [ ! -f "${META_OUT}" ]; then
    echo "browser-serve: timed out waiting for ${META_OUT}" >&2
    exit 1
fi

echo "browser-serve: http://127.0.0.1:${PORT}/"
echo "browser-serve: open that URL in Google Chrome (primary gate)"
echo "browser-serve: expect PASS for B-1 contracts + wt-carrier/* echoes"
echo "browser-serve: sidecar meta ${META_OUT}"
echo "browser-serve: Ctrl-C to stop"
cd "$SERVE_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1
