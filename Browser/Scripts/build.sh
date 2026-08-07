#!/bin/sh
# Cross-build LyteClientBrowser for the browser (Chrome B-1/B-2 proof)
# using the official Swift Wasm SDK and JavaScriptKit PackageToJS.
# Stages a self-contained tree under Browser/.serve/ for Scripts/serve.sh.
#
# Pins match Wire/Scripts/wasm-test.sh: swiftly toolchain 6.3.3 +
# swift-6.3.3-RELEASE_wasm. Nothing is auto-installed.
set -eu

TOOLCHAIN_VERSION="6.3.3"
WASM_SDK="swift-${TOOLCHAIN_VERSION}-RELEASE_wasm"

fail() {
    echo "browser-build: $1" >&2
    echo "" >&2
    echo "Install (user-local — same pins as Wire/Scripts/wasm-test.sh):" >&2
    cat >&2 <<'EOF'
  # swiftly + swift.org 6.3.3 toolchain
  curl -sLO https://download.swift.org/swiftly/darwin/swiftly.pkg
  installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
  ~/.swiftly/bin/swiftly init --assume-yes --skip-install --no-modify-profile
  . ~/.swiftly/env.sh && swiftly install 6.3.3 --use

  # the official Wasm SDK matching the toolchain
  swift sdk install \
    https://download.swift.org/swift-6.3.3-release/wasm-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_wasm.artifactbundle.tar.gz \
    --checksum cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7
EOF
    exit 1
}

if [ -f "$HOME/.swiftly/env.sh" ]; then
    . "$HOME/.swiftly/env.sh"
fi
command -v swiftly >/dev/null 2>&1 \
    || fail "swiftly not found (looked for ~/.swiftly/env.sh and PATH)"

swiftly list 2>/dev/null | grep -q "Swift ${TOOLCHAIN_VERSION}" \
    || fail "swift.org toolchain ${TOOLCHAIN_VERSION} not installed under swiftly"

swiftly run swift sdk list "+${TOOLCHAIN_VERSION}" 2>/dev/null \
        | grep -qx "$WASM_SDK" \
    || fail "Swift SDK ${WASM_SDK} not installed for toolchain ${TOOLCHAIN_VERSION}"

BROWSER_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$BROWSER_ROOT"

CONFIGURATION="${LYTE_BROWSER_CONFIGURATION:-release}"
SERVE_DIR="${BROWSER_ROOT}/.serve"

echo "browser-build: toolchain ${TOOLCHAIN_VERSION}, SDK ${WASM_SDK}, config ${CONFIGURATION}"
echo "browser-build: packaging LyteClientBrowser for browser (CDN WASI shim)"

swiftly run swift package "+${TOOLCHAIN_VERSION}" \
    --swift-sdk "$WASM_SDK" \
    --allow-writing-to-package-directory \
    js -c "$CONFIGURATION" --use-cdn --product LyteClientBrowser

PACKAGE_OUT="${BROWSER_ROOT}/.build/plugins/PackageToJS/outputs/Package"
[ -f "${PACKAGE_OUT}/LyteClientBrowser.wasm" ] \
    || fail "missing ${PACKAGE_OUT}/LyteClientBrowser.wasm after PackageToJS"

rm -rf "$SERVE_DIR"
mkdir -p "$SERVE_DIR"
# PackageToJS output (wasm + JS loader + WASI browser shim via CDN).
cp -R "${PACKAGE_OUT}/." "$SERVE_DIR/"
# Diagnostic host page + B-2 WebTransport carrier pump.
cp "${BROWSER_ROOT}/Page/index.html" "$SERVE_DIR/index.html"
cp "${BROWSER_ROOT}/Page/webtransport-carrier.js" "$SERVE_DIR/webtransport-carrier.js"

SIZE="$(wc -c < "${SERVE_DIR}/LyteClientBrowser.wasm" | tr -d ' ')"
echo "browser-build: staged ${SERVE_DIR}"
echo "browser-build: LyteClientBrowser.wasm is ${SIZE} bytes"
echo "browser-build: next — Browser/Scripts/serve.sh  (then open in Chrome)"
