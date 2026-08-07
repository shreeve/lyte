#!/bin/sh
# Serve Browser/.serve/ for the B-1 Chrome proof.
# Requires a prior Browser/Scripts/build.sh. Binds 127.0.0.1 only.
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SERVE_DIR="${BROWSER_ROOT}/.serve"
PORT="${LYTE_BROWSER_PORT:-8765}"

if [ ! -f "${SERVE_DIR}/index.html" ] \
    || [ ! -f "${SERVE_DIR}/LyteClientBrowser.wasm" ]; then
    echo "browser-serve: missing staged tree — run Browser/Scripts/build.sh first" >&2
    exit 1
fi

echo "browser-serve: http://127.0.0.1:${PORT}/"
echo "browser-serve: open that URL in Google Chrome (primary gate)"
echo "browser-serve: expect PASS for envelope-v1 + noise-v1 frozen contracts"
echo "browser-serve: Ctrl-C to stop"
cd "$SERVE_DIR"
exec python3 -m http.server "$PORT" --bind 127.0.0.1
