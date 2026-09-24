#!/bin/sh
# The Swift Wasm toolchain pins and lookup shared by the WebAssembly legs
# (Browser/Scripts/build.sh, Wire/Scripts/wasm-test.sh, the macOS gate).
# Source it, then call lyte_wasm_require. Nothing is auto-installed: a
# missing piece fails with the exact install commands.
#
# Optional: binaryen's wasm-opt. PackageToJS runs it on release builds when
# it is on PATH; without it the module stages unoptimized (~77 MB) but
# behaves the same.

LYTE_WASM_TOOLCHAIN_VERSION="6.3.3"
LYTE_WASM_SDK="swift-${LYTE_WASM_TOOLCHAIN_VERSION}-RELEASE_wasm"

lyte_wasm_install_help() {
    cat >&2 <<'EOF'
Install (user-local, repo-untouched):
  # swiftly + swift.org 6.3.3 toolchain
  curl -sLO https://download.swift.org/swiftly/darwin/swiftly.pkg
  installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
  ~/.swiftly/bin/swiftly init --assume-yes --skip-install --no-modify-profile
  . ~/.swiftly/env.sh && swiftly install 6.3.3

  # the official Wasm SDK matching the toolchain (checksum pinned)
  swiftly run swift sdk install +6.3.3 \
    https://download.swift.org/swift-6.3.3-release/wasm-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_wasm.artifactbundle.tar.gz \
    --checksum cabfa08b73bb8ac783927ecd15fa386e99d0c139c5f232445067bcf58379cae7
EOF
}

# Prints the wasmtime executable (PATH, then the upstream installer's
# ~/.wasmtime/bin); fails when neither exists.
lyte_wasmtime() {
    if command -v wasmtime 2>/dev/null; then
        return 0
    fi
    if [ -x "$HOME/.wasmtime/bin/wasmtime" ]; then
        echo "$HOME/.wasmtime/bin/wasmtime"
        return 0
    fi
    return 1
}

lyte_wasmtime_install_help() {
    cat >&2 <<'EOF'
Install wasmtime (either):
  brew install wasmtime
  curl https://wasmtime.dev/install.sh -sSf | bash
EOF
}

# True when swiftly, the pinned toolchain and the Wasm SDK are all present.
lyte_wasm_available() {
    if [ -f "$HOME/.swiftly/env.sh" ]; then
        . "$HOME/.swiftly/env.sh"
    fi
    command -v swiftly >/dev/null 2>&1 || return 1
    # Matched as strings, not `| grep -q`: under a caller's pipefail, grep
    # exiting early can SIGPIPE swiftly and turn a match into a miss.
    toolchains="$(swiftly list 2>/dev/null)" || return 1
    case "$toolchains" in
        *"Swift ${LYTE_WASM_TOOLCHAIN_VERSION}"*) ;;
        *) return 1 ;;
    esac
    sdks="$(swiftly run swift sdk list "+${LYTE_WASM_TOOLCHAIN_VERSION}" \
        2>/dev/null)" || return 1
    case "
$sdks
" in
        *"
$LYTE_WASM_SDK
"*) return 0 ;;
    esac
    return 1
}

# Fails with the install commands unless the toolchain is usable, and
# exports an SDKROOT the pinned toolchain can compile manifests against.
lyte_wasm_require() {
    label="$1"
    if ! lyte_wasm_available; then
        echo "${label}: Swift ${LYTE_WASM_TOOLCHAIN_VERSION} + ${LYTE_WASM_SDK} via swiftly not found" >&2
        echo "" >&2
        lyte_wasm_install_help
        exit 1
    fi
    lyte_wasm_select_host_sdk "$label"
}

# Manifests compile for the host with the macOS SDK. A macOS SDK newer than
# the pinned toolchain can crash the manifest compile, so probe the default
# SDK first, then the installed Command Line Tools SDKs newest first. A
# caller's SDKROOT wins.
lyte_wasm_select_host_sdk() {
    label="$1"
    [ -z "${SDKROOT:-}" ] || return 0
    probe="$(mktemp -d "${TMPDIR:-/tmp}/lyte-wasm-sdk-probe.XXXXXX")"
    cat > "$probe/Package.swift" <<'EOF'
// swift-tools-version:6.0
import Foundation
import PackageDescription
let package = Package(
    name: ProcessInfo.processInfo.environment["LYTE_PROBE"] ?? "Probe"
)
EOF
    for candidate in "" $(ls -d \
        /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.[0-9]*.sdk \
        2>/dev/null | sort -rV)
    do
        [ -z "$candidate" ] || [ -d "$candidate" ] || continue
        if [ -n "$candidate" ]; then
            set -- env SDKROOT="$candidate"
        else
            set -- env -u SDKROOT
        fi
        if "$@" swiftly run swift package \
            "+${LYTE_WASM_TOOLCHAIN_VERSION}" --package-path "$probe" \
            dump-package >/dev/null 2>&1
        then
            rm -rf "$probe"
            if [ -n "$candidate" ]; then
                echo "${label}: host SDK ${candidate} (default SDK is newer than the pinned toolchain)"
                SDKROOT="$candidate"
                export SDKROOT
            fi
            return 0
        fi
    done
    rm -rf "$probe"
    echo "${label}: no installed macOS SDK compiles manifests with Swift ${LYTE_WASM_TOOLCHAIN_VERSION}; set SDKROOT" >&2
    exit 1
}
