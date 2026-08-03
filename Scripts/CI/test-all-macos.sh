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
    local path="$2"
    echo "==> $label tests"
    (cd "$path" && swift test)
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
run_package_tests "Common" "$repo_root/Common"
run_package_tests "Wire" "$repo_root/Wire"
run_package_tests "Host" "$repo_root/Host"
run_package_tests "client" "$repo_root"

echo "==> analyzer tests"
python_env="$repo_root/.build/ci-python"
python_requirements="$repo_root/Scripts/requirements.txt"
python_requirements_hash="$python_env/.lyte-requirements-sha256"
required_hash="$(shasum -a 256 "$python_requirements" | awk '{print $1}')"

if [[ ! -x "$python_env/bin/python3" ]]; then
    python3 -m venv "$python_env"
fi

installed_hash=""
if [[ -f "$python_requirements_hash" ]]; then
    installed_hash="$(<"$python_requirements_hash")"
fi

if [[ "$installed_hash" != "$required_hash" ]]; then
    "$python_env/bin/python3" -m pip install \
        --disable-pip-version-check \
        --requirement "$python_requirements"
    printf '%s\n' "$required_hash" > "$python_requirements_hash"
fi

"$python_env/bin/python3" Scripts/test_analyze_app_benchmark.py

echo "==> signed debug CLI"
Scripts/build-cli.sh debug
codesign --verify --strict .build/debug/lyte-cli

echo "==> signed release app"
Scripts/make-app.sh release
codesign --verify --strict .build/Lyte.app/Contents/MacOS/Lyte
codesign --verify --strict .build/Lyte.app/Contents/MacOS/lyte-helperd
codesign --verify --strict .build/Lyte.app

echo "macOS gate PASSED"
