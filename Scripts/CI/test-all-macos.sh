#!/bin/bash
# The deterministic macOS gate for every Lyte PR. Live hardware and
# impairment evidence are separate, explicitly-invoked gates.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo "macOS gate FAILED: DEVELOPER_DIR does not exist: $DEVELOPER_DIR" >&2
    exit 1
fi

source "$repo_root/Scripts/lib/build-graph.sh"

# run_package_tests PACKAGE: resolve and test PACKAGE in its own scratch
# directory, cleaning it first when its build graph changed.
run_package_tests() {
    local package="$1"
    local package_path="$repo_root/$package"
    local scratch_path="$package_path/.build"
    local marker="$scratch_path/.lyte-build-graph-sha256"
    local build_graph_hash installed_hash=""
    echo "==> $package tests"

    build_graph_hash="$(lyte_build_graph_hash "$repo_root" "$package")"
    if [[ -f "$marker" ]]; then
        installed_hash="$(<"$marker")"
    fi
    if [[ "$installed_hash" != "$build_graph_hash" ]]; then
        echo "    package or source-path graph changed; invalidating stale SwiftPM build state"
        swift package \
            --package-path "$package_path" \
            --scratch-path "$scratch_path" \
            clean
    fi

    # Path-only sibling-package moves do not always invalidate SwiftPM's
    # workspace state; resolve first.
    swift package \
        --package-path "$package_path" \
        --scratch-path "$scratch_path" \
        resolve
    swift test \
        --package-path "$package_path" \
        --scratch-path "$scratch_path" \
        -Xswiftc -warnings-as-errors
    mkdir -p "$scratch_path"
    printf '%s\n' "$build_graph_hash" > "$marker"
}

verify_frozen_vectors() {
    if [[ "${LYTE_ALLOW_VECTOR_CHANGES:-0}" == "1" ]]; then
        echo "==> frozen-vector diff explicitly allowed"
        return
    fi

    local base="${LYTE_GATE_BASE_SHA:-}"
    if [[ -z "$base" ]] && git rev-parse --verify origin/main >/dev/null 2>&1; then
        base="$(git merge-base HEAD origin/main)"
    fi
    if [[ -z "$base" ]]; then
        echo "macOS gate FAILED: set LYTE_GATE_BASE_SHA or fetch origin/main" >&2
        exit 1
    fi

    # Vectors are append-only: a committed vector file may never be modified,
    # deleted, renamed, or retyped. New vector files and README prose are fine.
    echo "==> frozen-vector contract (append-only)"
    local changed
    changed="$(git diff --name-only --diff-filter=MDRT "$base" -- Wire/Vectors/ \
        | grep -v '^Wire/Vectors/README\.md$' || true)"
    if [[ -n "$changed" ]]; then
        echo "macOS gate FAILED: committed vectors changed:" >&2
        echo "$changed" >&2
        exit 1
    fi
}

verify_frozen_vectors

run_package_tests Common
run_package_tests Wire
run_package_tests Host
# `.build/Lyte.app` is the published app and may be running; SwiftPM
# `clean` removes the whole scratch root, so every package, Client
# included, uses its package-local scratch directory.
run_package_tests Client
run_package_tests SystemTests
# The browser's sans-IO core, natively (its tests drive a real HostWire
# session in process).
run_package_tests Browser

# The WebAssembly and page legs need toolchains Xcode does not ship
# (docs/TESTING.md#requirements). A missing one fails the gate: "LyteWire
# stays WebAssembly-compilable" is law, not a best effort. Only
# LYTE_GATE_ALLOW_SKIP=1 skips a leg, and the summary names it.
ran_legs=""
skipped_legs=""
# The probes run in subshells so swiftly's PATH never reaches the Xcode legs.
wasm_toolchain_installed() (
    . "$repo_root/Scripts/lib/wasm-toolchain.sh"
    lyte_wasm_available
)
wasm_suite_runnable() (
    . "$repo_root/Scripts/lib/wasm-toolchain.sh"
    lyte_wasm_available && lyte_wasmtime >/dev/null
)
node_installed() { command -v node >/dev/null; }
# optional_leg NAME PROBE COMMAND...
optional_leg() {
    local name="$1" probe="$2"
    shift 2
    echo "==> $name"
    if ! "$probe"; then
        if [[ "${LYTE_GATE_ALLOW_SKIP:-0}" != 1 ]]; then
            echo "macOS gate FAILED: $name cannot run ($probe failed);" \
                "install the toolchain (docs/TESTING.md#requirements)" \
                "or set LYTE_GATE_ALLOW_SKIP=1" >&2
            exit 1
        fi
        echo "    SKIPPED: $probe failed and LYTE_GATE_ALLOW_SKIP=1"
        skipped_legs="${skipped_legs:+$skipped_legs, }$name"
        return 0
    fi
    "$@"
    ran_legs="${ran_legs:+$ran_legs, }$name"
}

optional_leg "browser WebAssembly build" wasm_toolchain_installed \
    Browser/Scripts/build.sh
optional_leg "Wire suite on WebAssembly" wasm_suite_runnable \
    Wire/Scripts/wasm-test.sh
optional_leg "browser page tests" node_installed \
    node --test Browser/Tests/Page/page.test.mjs

echo "==> shell script lint and gate helpers"
Scripts/Tests/test-shell-assertions.sh
Scripts/Tests/test-build-graph.sh

echo "==> benchmark safety tests"
Scripts/Tests/test-benchmark-safety.sh
Scripts/Tests/test-host-release-posture.sh

echo "==> rootless Linux host image tests"
Scripts/Tests/test-host-package-image.sh --self-test
Scripts/Tests/test-host-installer.sh --self-test

echo "==> signing policy tests"
Scripts/Tests/test-sign-dev.sh
Scripts/Tests/test-setup-dev-signing.sh

echo "==> analyzer tests"
python_env="$repo_root/.build/ci-python"
python_requirements="$repo_root/Scripts/requirements.txt"
python_bootstrap="${LYTE_CI_PYTHON:-/usr/bin/python3}"
python_environment_hash="$python_env/.lyte-environment-sha256"

if [[ ! -x "$python_bootstrap" ]]; then
    echo "macOS gate FAILED: Python bootstrap missing: $python_bootstrap" >&2
    exit 1
fi
if ! "$python_bootstrap" -c \
    'import sys; raise SystemExit(sys.version_info[:2] < (3, 9))'
then
    echo "macOS gate FAILED: the analyzer tests need Python 3.9 or later;" \
        "set LYTE_CI_PYTHON to a compatible interpreter" >&2
    exit 1
fi

required_hash="$({
    "$python_bootstrap" -c \
        'import os, sys; print(os.path.realpath(sys.executable)); print(sys.version)'
    shasum -a 256 "$python_requirements"
} | shasum -a 256 | awk '{print $1}')"
installed_hash=""
if [[ -f "$python_environment_hash" ]]; then
    installed_hash="$(<"$python_environment_hash")"
fi

if [[ ! -x "$python_env/bin/python3" || "$installed_hash" != "$required_hash" ]]; then
    rm -rf -- "$python_env"
    "$python_bootstrap" -m venv "$python_env"
    "$python_env/bin/python3" -m pip install \
        --disable-pip-version-check \
        --requirement "$python_requirements"
    printf '%s\n' "$required_hash" > "$python_environment_hash"
fi

"$python_env/bin/python3" Scripts/Tests/test_analyze_app_benchmark.py
"$python_env/bin/python3" Scripts/Tests/test_motion_preflight.py
Scripts/Tests/test-app-identity.sh

echo "==> signed debug CLI"
Scripts/build-cli.sh debug
codesign --verify --strict .build/debug/lyte-cli
Scripts/Tests/test-hermetic-linkage.sh .build/debug/lyte-cli

echo "==> signed release app"
ci_app_root="$(mktemp -d .build/.lyte-ci-app.XXXXXX)"
cleanup_ci_app() { rm -rf -- "$ci_app_root"; }
trap cleanup_ci_app EXIT
ci_app="$ci_app_root/Lyte.app"
LYTE_APP_DESTINATION="$ci_app" Scripts/make-app.sh release
first_ci_bundle_version="$(
    plutil -extract CFBundleVersion raw -o - "$ci_app/Contents/Info.plist"
)"
# A second assembly exercises the version-successor and RENAME_SWAP path at an
# isolated destination without touching the owner's published app.
LYTE_APP_DESTINATION="$ci_app" Scripts/make-app.sh release
second_ci_bundle_version="$(
    plutil -extract CFBundleVersion raw -o - "$ci_app/Contents/Info.plist"
)"
[[ "$second_ci_bundle_version" -gt "$first_ci_bundle_version" ]] || {
    echo "macOS gate FAILED: bundle version did not increase" \
        "($first_ci_bundle_version then $second_ci_bundle_version)" >&2
    exit 1
}
Scripts/Tests/test-app-packaging.sh "$ci_app" "$ci_app_root"
codesign --verify --strict "$ci_app/Contents/MacOS/Lyte"
codesign --verify --strict "$ci_app/Contents/MacOS/lyte-helperd"
codesign --verify --strict "$ci_app"
Scripts/Tests/test-hermetic-linkage.sh \
    "$ci_app/Contents/MacOS/Lyte" \
    "$ci_app/Contents/MacOS/lyte-helperd"

echo "toolchain legs run: ${ran_legs:-none}"
if [[ -n "$skipped_legs" ]]; then
    echo "macOS gate PASSED WITH SKIPPED LEGS: $skipped_legs"
else
    echo "macOS gate PASSED"
fi
