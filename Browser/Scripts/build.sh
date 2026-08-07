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
# Diagnostic host page + B-2…B-6 pumps (control + video + interaction).
cp "${BROWSER_ROOT}/Page/index.html" "$SERVE_DIR/index.html"
cp "${BROWSER_ROOT}/Page/webtransport-carrier.js" "$SERVE_DIR/webtransport-carrier.js"
cp "${BROWSER_ROOT}/Page/control-session.js" "$SERVE_DIR/control-session.js"
cp "${BROWSER_ROOT}/Page/frame-present.js" "$SERVE_DIR/frame-present.js"
cp "${BROWSER_ROOT}/Page/conductor-video.js" "$SERVE_DIR/conductor-video.js"
cp "${BROWSER_ROOT}/Page/interaction.js" "$SERVE_DIR/interaction.js"
cp "${BROWSER_ROOT}/Page/audio-ring-worklet.js" "$SERVE_DIR/audio-ring-worklet.js"
# Frozen corpus prefix — staged from Wire vectors (not duplicated in git).
CORPUS_DIR="${BROWSER_ROOT}/../Wire/Vectors/video-corpus-v1"
[ -d "$CORPUS_DIR" ] || fail "missing video corpus ${CORPUS_DIR}"
for f in \
    frame-000-idr.annexb \
    frame-001-p.annexb frame-002-p.annexb frame-003-p.annexb \
    frame-004-p.annexb frame-005-p.annexb frame-006-p.annexb \
    frame-007-p.annexb frame-008-p.annexb frame-009-p.annexb
do
    [ -f "${CORPUS_DIR}/${f}" ] || fail "missing corpus frame ${CORPUS_DIR}/${f}"
    cp "${CORPUS_DIR}/${f}" "${SERVE_DIR}/${f}"
done
# Convenience copy for peer --emit-corpus (same bytes; peer reads DIR).
mkdir -p "${SERVE_DIR}/corpus"
cp \
    "${SERVE_DIR}/frame-000-idr.annexb" \
    "${SERVE_DIR}/frame-001-p.annexb" \
    "${SERVE_DIR}/frame-002-p.annexb" \
    "${SERVE_DIR}/frame-003-p.annexb" \
    "${SERVE_DIR}/frame-004-p.annexb" \
    "${SERVE_DIR}/frame-005-p.annexb" \
    "${SERVE_DIR}/frame-006-p.annexb" \
    "${SERVE_DIR}/frame-007-p.annexb" \
    "${SERVE_DIR}/frame-008-p.annexb" \
    "${SERVE_DIR}/frame-009-p.annexb" \
    "${SERVE_DIR}/corpus/"

SIZE="$(wc -c < "${SERVE_DIR}/LyteClientBrowser.wasm" | tr -d ' ')"
IDR_SIZE="$(wc -c < "${SERVE_DIR}/frame-000-idr.annexb" | tr -d ' ')"
echo "browser-build: staged ${SERVE_DIR}"
echo "browser-build: LyteClientBrowser.wasm is ${SIZE} bytes"
echo "browser-build: corpus IRAP is ${IDR_SIZE} bytes; frames 000–009 staged"
echo "browser-build: next — Browser/Scripts/serve.sh  (then open in Chrome; B-6)"
