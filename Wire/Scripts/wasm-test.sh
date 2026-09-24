#!/bin/sh
# Cross-build the entire Wire test suite for wasm32-unknown-wasip1 and run
# it under wasmtime, so every suite and frozen vector file verifies on a
# third platform. Toolchain pins: Scripts/lib/wasm-toolchain.sh; nothing is
# auto-installed. No arguments; exits nonzero on any missing tool, build
# failure, test failure, or an empty test run.
set -eu

TRIPLE="wasm32-unknown-wasip1"
# Its own scratch path: the host toolchain's `swift test --scratch-path
# .build` keeps its workspace state, checkouts and manifest caches apart.
SCRATCH=".build/wasm"

# Resolve the package root physically (pwd -P): the tests locate vectors
# via #filePath, and a symlinked working directory (/tmp → /private/tmp)
# bakes paths a WASI preopen of the logical path never satisfies.
WIRE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO_ROOT="$(cd "${WIRE_ROOT}/.." && pwd -P)"
. "${REPO_ROOT}/Scripts/lib/wasm-toolchain.sh"
lyte_wasm_require wasm-test

if ! WASMTIME="$(lyte_wasmtime)"; then
    echo "wasm-test: wasmtime not found (PATH and ~/.wasmtime/bin)" >&2
    lyte_wasmtime_install_help
    exit 1
fi

cd "$WIRE_ROOT"

echo "wasm-test: toolchain ${LYTE_WASM_TOOLCHAIN_VERSION}, SDK ${LYTE_WASM_SDK}, $("$WASMTIME" --version)"
echo "wasm-test: building tests for ${TRIPLE} in ${WIRE_ROOT}"
swiftly run swift build "+${LYTE_WASM_TOOLCHAIN_VERSION}" \
    --swift-sdk "$LYTE_WASM_SDK" --scratch-path "$SCRATCH" --build-tests \
    -Xswiftc -warnings-as-errors

# `swift test` cannot drive XCTest on WASI (its in-process runner only
# speaks swift-testing there and reports 0 tests); the built .xctest wasm
# module is invoked directly instead.
TEST_MODULE="${SCRATCH}/${TRIPLE}/debug/LyteWirePackageTests.xctest"
if [ ! -f "$TEST_MODULE" ]; then
    echo "wasm-test: test module missing after build: $TEST_MODULE" >&2
    exit 1
fi

OUTPUT_LOG="$(mktemp "${TMPDIR:-/tmp}/lyte-wasm-test.XXXXXX")"
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
        echo "wasm-test: no tests executed — the runner produced no test summary" >&2
        exit 1 ;;
esac

echo "wasm-test: PASS on ${TRIPLE} — ${SUMMARY# }"
