#!/bin/sh
# Cross-build LyteClientBrowser for the browser with the official Swift Wasm
# SDK and JavaScriptKit PackageToJS, and stage a self-contained tree under
# Browser/.serve/ (the WASM package, the page, and the video corpus the
# control peer emits). Idempotent; incremental after the first build.
#
# Toolchain pins: Scripts/lib/wasm-toolchain.sh. Nothing is auto-installed.
# Environment: LYTE_BROWSER_CONFIGURATION (release|debug; default release).
set -eu

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO_ROOT="$(cd "${BROWSER_ROOT}/.." && pwd -P)"
. "${REPO_ROOT}/Scripts/lib/wasm-toolchain.sh"
lyte_wasm_require browser-build

cd "$BROWSER_ROOT"
CONFIGURATION="${LYTE_BROWSER_CONFIGURATION:-release}"
SERVE_DIR="${BROWSER_ROOT}/.serve"
CORPUS_DIR="${REPO_ROOT}/Wire/Vectors/video-corpus-v1"

echo "browser-build: Swift ${LYTE_WASM_TOOLCHAIN_VERSION}, SDK ${LYTE_WASM_SDK}, config ${CONFIGURATION}"
swiftly run swift package "+${LYTE_WASM_TOOLCHAIN_VERSION}" \
    --swift-sdk "$LYTE_WASM_SDK" \
    --allow-writing-to-package-directory \
    js -c "$CONFIGURATION" --use-cdn --product LyteClientBrowser

PACKAGE_OUT="${BROWSER_ROOT}/.build/plugins/PackageToJS/outputs/Package"
[ -f "${PACKAGE_OUT}/LyteClientBrowser.wasm" ] || {
    echo "browser-build: missing ${PACKAGE_OUT}/LyteClientBrowser.wasm after PackageToJS" >&2
    exit 1
}
ls "${CORPUS_DIR}"/frame-00?-*.annexb >/dev/null 2>&1 || {
    echo "browser-build: missing video corpus under ${CORPUS_DIR}" >&2
    exit 1
}

rm -rf "$SERVE_DIR"
mkdir -p "$SERVE_DIR/corpus"
cp -R "${PACKAGE_OUT}/." "$SERVE_DIR/"
cp "${BROWSER_ROOT}"/Page/index.html "${BROWSER_ROOT}"/Page/*.js "$SERVE_DIR/"
# lyte-control-peer --emit-corpus reads frames from here.
cp "${CORPUS_DIR}"/frame-00?-*.annexb "$SERVE_DIR/corpus/"

SIZE="$(wc -c < "${SERVE_DIR}/LyteClientBrowser.wasm" | tr -d ' ')"
echo "browser-build: staged ${SERVE_DIR} (LyteClientBrowser.wasm ${SIZE} bytes)"
