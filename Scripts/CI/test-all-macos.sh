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

run_package_tests() {
    local label="$1"
    local package_path="$2"
    local scratch_path="$3"
    local marker="$scratch_path/.lyte-build-graph-sha256"
    local installed_hash=""
    echo "==> $label tests"

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
    # existing workspace state. Resolve first so the gate is valid in an
    # incremental developer checkout as well as a clean clone.
    swift package \
        --package-path "$package_path" \
        --scratch-path "$scratch_path" \
        resolve
    swift test \
        --package-path "$package_path" \
        --scratch-path "$scratch_path"
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

    echo "==> frozen-vector contract"
    git diff --exit-code "$base" -- Wire/Vectors/
}

verify_frozen_vectors

build_graph_hash="$({
    for manifest in \
        Client/Package.swift Client/Package.resolved \
        Common/Package.swift Common/Package.resolved \
        Wire/Package.swift Wire/Package.resolved \
        Host/Package.swift Host/Package.resolved \
        SystemTests/Package.swift SystemTests/Package.resolved
    do
        if [[ -f "$manifest" ]]; then
            shasum -a 256 "$manifest"
        fi
    done

    # SwiftPM can retain absolute dependency source paths after a file-only
    # layout migration even when every manifest is unchanged. Make the
    # structural source graph part of cache identity so dependent packages
    # rebuild cleanly after files are added, removed, or moved.
    for package_root in Client Common Wire Host SystemTests; do
        for tree in Sources Tests Plugins; do
            source_root="$package_root/$tree"
            if [[ -d "$source_root" ]]; then
                find "$source_root" -type f -print
            fi
        done
    done | LC_ALL=C sort
} | shasum -a 256 | awk '{print $1}')"

run_package_tests "Common" "$repo_root/Common" "$repo_root/Common/.build"
run_package_tests "Wire" "$repo_root/Wire" "$repo_root/Wire/.build"
run_package_tests "Host" "$repo_root/Host" "$repo_root/Host/.build"
run_package_tests "client" "$repo_root/Client" "$repo_root/.build"
run_package_tests \
    "SystemTests" "$repo_root/SystemTests" "$repo_root/SystemTests/.build"

echo "==> benchmark safety tests"
Scripts/Tests/test-benchmark-safety.sh

echo "==> signing policy tests"
Scripts/Tests/test-sign-dev.sh

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
    'import sys; raise SystemExit(not ((3, 9) <= sys.version_info[:2] < (3, 13)))'
then
    echo "macOS gate FAILED: NumPy 2.0.2 needs Python 3.9–3.12; " \
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

echo "==> signed debug CLI"
Scripts/build-cli.sh debug
codesign --verify --strict .build/debug/lyte-cli

echo "==> signed release app"
Scripts/make-app.sh release
Scripts/Tests/test-app-packaging.sh .build/Lyte.app
codesign --verify --strict .build/Lyte.app/Contents/MacOS/Lyte
codesign --verify --strict .build/Lyte.app/Contents/MacOS/lyte-helperd
codesign --verify --strict .build/Lyte.app

echo "macOS gate PASSED"
