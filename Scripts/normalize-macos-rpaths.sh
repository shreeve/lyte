#!/bin/bash
# Remove SwiftPM's developer-toolchain search path before signing a macOS
# executable. Shipping artifacts may search the OS Swift runtime and their own
# bundle, never the Xcode installation that happened to build them.
set -euo pipefail

if (( $# == 0 )); then
    echo "usage: Scripts/normalize-macos-rpaths.sh <binary> [...]" >&2
    exit 2
fi

for binary in "$@"; do
    [[ -x "$binary" ]] || {
        echo "runtime-path normalization FAILED: not executable: $binary" >&2
        exit 1
    }
    while IFS= read -r rpath; do
        case "$rpath" in
            /usr/lib/swift|@loader_path|@executable_path/../Frameworks)
                ;;
            *)
                install_name_tool -delete_rpath "$rpath" "$binary"
                ;;
        esac
    done < <(
        otool -l "$binary" | awk '
            $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
            want_path && $1 == "path" { print $2; want_path = 0 }
        '
    )
done
