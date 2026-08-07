#!/bin/sh
# Serve Browser/.serve/ with lyte-control-peer + lyte-wt-sidecar for the
# B-3 Chrome proof. Requires a prior Browser/Scripts/build.sh.
# Binds 127.0.0.1 only. Never touches standing host UDP 41151.
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO_ROOT="$(cd "${BROWSER_ROOT}/.." && pwd -P)"
SERVE_DIR="${BROWSER_ROOT}/.serve"
PORT="${LYTE_BROWSER_PORT:-8765}"
PEER_PORT="${LYTE_CONTROL_PEER_PORT:-41234}"
META_OUT="${SERVE_DIR}/wt-sidecar.json"
PEER_META="${SERVE_DIR}/control-peer.json"
SIDECAR_LOG="${SERVE_DIR}/wt-sidecar.log"
PEER_LOG="${SERVE_DIR}/control-peer.log"
SIDECAR_PID=""
PEER_PID=""

if [ ! -f "${SERVE_DIR}/index.html" ] \
    || [ ! -f "${SERVE_DIR}/LyteClientBrowser.wasm" ] \
    || [ ! -f "${SERVE_DIR}/webtransport-carrier.js" ] \
    || [ ! -f "${SERVE_DIR}/control-session.js" ]; then
    echo "browser-serve: missing staged tree — run Browser/Scripts/build.sh first" >&2
    exit 1
fi

if [ "$PEER_PORT" = "41151" ]; then
    echo "browser-serve: refusing standing host UDP 41151" >&2
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

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

cleanup() {
    if [ -n "${SIDECAR_PID}" ] && kill -0 "${SIDECAR_PID}" 2>/dev/null; then
        kill "${SIDECAR_PID}" 2>/dev/null || true
        wait "${SIDECAR_PID}" 2>/dev/null || true
    fi
    if [ -n "${PEER_PID}" ] && kill -0 "${PEER_PID}" 2>/dev/null; then
        kill "${PEER_PID}" 2>/dev/null || true
        wait "${PEER_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "browser-serve: building lyte-control-peer (HostWire, no DRM)…"
(
    cd "${REPO_ROOT}/Host"
    swift build -c release --product lyte-control-peer
)
PEER_BIN="${REPO_ROOT}/Host/.build/release/lyte-control-peer"
[ -x "$PEER_BIN" ] || {
    echo "browser-serve: missing ${PEER_BIN}" >&2
    exit 1
}

rm -f "$PEER_META" "$META_OUT"
echo "browser-serve: starting lyte-control-peer on UDP ${PEER_PORT}…"
"$PEER_BIN" --listen "$PEER_PORT" --bind 127.0.0.1 --meta-out "$PEER_META" \
    --seconds 600 >"${PEER_LOG}" 2>&1 &
PEER_PID=$!

i=0
while [ "$i" -lt 50 ]; do
    if [ -f "${PEER_META}" ]; then
        break
    fi
    if ! kill -0 "${PEER_PID}" 2>/dev/null; then
        echo "browser-serve: control-peer exited early — see ${PEER_LOG}" >&2
        cat "${PEER_LOG}" >&2 || true
        exit 1
    fi
    i=$((i + 1))
    sleep 0.1
done
[ -f "${PEER_META}" ] || {
    echo "browser-serve: timed out waiting for ${PEER_META}" >&2
    exit 1
}

echo "browser-serve: starting lyte-wt-sidecar → UDP ${PEER_PORT}…"
node "${BROWSER_ROOT}/Scripts/wt-sidecar.mjs" \
    --meta-out "${META_OUT}" \
    --udp-peer "127.0.0.1:${PEER_PORT}" \
    >"${SIDECAR_LOG}" 2>&1 &
SIDECAR_PID=$!

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
[ -f "${META_OUT}" ] || {
    echo "browser-serve: timed out waiting for ${META_OUT}" >&2
    exit 1
}

PIN="$(python3 -c 'import json; print(json.load(open("'"${PEER_META}"'"))["pin"])')"
echo "browser-serve: http://127.0.0.1:${PORT}/"
echo "browser-serve: open that URL in Google Chrome (primary gate)"
echo "browser-serve: expect PASS for B-1 + control-session/* (B-3)"
echo "browser-serve: control PIN ${PIN} (also in ${PEER_META})"
echo "browser-serve: Ctrl-C to stop"
cd "$SERVE_DIR"
python3 -m http.server "$PORT" --bind 127.0.0.1
