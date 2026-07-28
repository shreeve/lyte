#!/bin/sh
# The wasm attestation leg: cross-build the ENTIRE Wire test suite for
# wasm32-unknown-wasip1 and execute it under wasmtime. What it proves:
# wasm32 is the THIRD attested platform for the frozen wire contracts —
# every codec, FEC, Noise, PAKE, ARQ, video, session, and bulk suite runs
# and every frozen vector file under Vectors/ verifies byte-exact, the
# same bytes gate W-G1 pins on macOS and Linux. The sans-IO, no-Foundation
# doctrine (AGENTS.md; core plan §1 "LyteWire must stay WASM-compilable")
# is what makes this a build-and-run, not a port; this script keeps it a
# repeatable check instead of a one-time probe. Scoping + probe record:
# docs/20260728-054139-lyte-browser-viewer-scoping.md §1.
#
# Pins: swift.org toolchain 6.3.3 (swiftly, user-local) + the official
# swift-6.3.3-RELEASE_wasm SDK + wasmtime. Nothing is auto-installed —
# missing pieces fail with the exact install commands.
#
# Usage: Wire/Scripts/wasm-test.sh   (no arguments; exits nonzero on any
# build failure, test failure, or an empty test run)
set -eu

TOOLCHAIN_VERSION="6.3.3"
WASM_SDK="swift-${TOOLCHAIN_VERSION}-RELEASE_wasm"
TRIPLE="wasm32-unknown-wasip1"

fail() {
    echo "wasm-test: $1" >&2
    echo "" >&2
    echo "Install (user-local, repo-untouched — the scoping doc's exact commands):" >&2
    cat >&2 <<'EOF'
  # swiftly + swift.org 6.3.3 toolchain
  curl -sLO https://download.swift.org/swiftly/darwin/swiftly.pkg
  installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
  ~/.swiftly/bin/swiftly init --assume-yes --skip-install --no-modify-profile
  . ~/.swiftly/env.sh && swiftly install 6.3.3 --use

  # the official Wasm SDK matching the toolchain (swift.org, checksum pinned)
  swift sdk install \
    https://download.swift.org/swift-6.3.3-release/wasm-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_wasm.artifactbundle.tar.gz \
    --checksum cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7

  # wasmtime
  curl https://wasmtime.dev/install.sh -sSf | bash
EOF
    exit 1
}

# --- locate the toolchain, SDK, and runtime (never auto-install) ---------

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

if command -v wasmtime >/dev/null 2>&1; then
    WASMTIME="wasmtime"
elif [ -x "$HOME/.wasmtime/bin/wasmtime" ]; then
    WASMTIME="$HOME/.wasmtime/bin/wasmtime"
else
    fail "wasmtime not found (PATH and ~/.wasmtime/bin)"
fi

# --- build the suite ------------------------------------------------------

# Resolve the package root PHYSICALLY (pwd -P): the tests locate the frozen
# vectors via #filePath, and on macOS a symlinked working directory (/tmp →
# /private/tmp is the classic) bakes paths into the binary that a WASI
# preopen of the logical path never satisfies. Building from — and
# preopening — the resolved path closes that gap.
WIRE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$WIRE_ROOT"

echo "wasm-test: toolchain ${TOOLCHAIN_VERSION}, SDK ${WASM_SDK}, $("$WASMTIME" --version)"
echo "wasm-test: building tests for ${TRIPLE} in ${WIRE_ROOT}"
swiftly run swift build "+${TOOLCHAIN_VERSION}" --swift-sdk "$WASM_SDK" --build-tests

# --- run under wasmtime ---------------------------------------------------

# `swift test` cannot drive XCTest on WASI (its in-process runner only
# speaks swift-testing there and reports 0 tests); the built .xctest wasm
# module is invoked directly instead.
TEST_MODULE=".build/${TRIPLE}/debug/LyteWirePackageTests.xctest"
[ -f "$TEST_MODULE" ] || fail "test module missing after build: $TEST_MODULE"

OUTPUT_LOG="$(mktemp -t lyte-wasm-test)"
trap 'rm -f "$OUTPUT_LOG"' EXIT

echo "wasm-test: running the suite under wasmtime"
STATUS=0
"$WASMTIME" run --dir . --dir "${WIRE_ROOT}::${WIRE_ROOT}" "$TEST_MODULE" \
    >"$OUTPUT_LOG" 2>&1 || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    cat "$OUTPUT_LOG" >&2
    echo "wasm-test: FAILED (exit $STATUS)" >&2
    exit "$STATUS"
fi

# XCTest's exit status already failed us above on any assertion; this
# guards the other failure mode — a runner that executed nothing.
grep -E '^Test Suite .* (passed|failed)' "$OUTPUT_LOG" | tail -n 2 || true
SUMMARY="$(grep -E 'Executed [0-9]+ tests?' "$OUTPUT_LOG" | tail -n 1)"
case "$SUMMARY" in
    ""|*"Executed 0 tests"*)
        fail "no tests executed — the runner produced no test summary" ;;
esac

echo "wasm-test: PASS on ${TRIPLE} — ${SUMMARY# }"
