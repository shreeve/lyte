#!/bin/bash
set -euo pipefail

if (( $# == 0 )); then
    echo "usage: Scripts/Tests/test-hermetic-linkage.sh <binary> [...]" >&2
    exit 2
fi

for binary in "$@"; do
    [[ -x "$binary" ]] || {
        echo "hermetic linkage FAILED: not executable: $binary" >&2
        exit 1
    }
    case "$(uname -s)" in
        Darwin)
            dependencies="$(otool -L "$binary")"
            while IFS= read -r dependency; do
                case "$dependency" in
                    /usr/lib/*|/System/Library/*) ;;
                    *)
                        echo "hermetic linkage FAILED: ambient dependency in $binary" >&2
                        printf '%s\n' "$dependencies" >&2
                        exit 1
                        ;;
                esac
            done < <(printf '%s\n' "$dependencies" | tail -n +2 | awk '{print $1}')

            rpaths="$(otool -l "$binary" | awk '
                $1 == "cmd" && $2 == "LC_RPATH" { want_path = 1; next }
                want_path && $1 == "path" { print $2; want_path = 0 }
            ')"
            while IFS= read -r rpath; do
                [[ -z "$rpath" ]] && continue
                case "$rpath" in
                    /usr/lib/swift|@loader_path|@executable_path/../Frameworks)
                        ;;
                    *)
                        echo "hermetic linkage FAILED: ambient rpath in $binary: $rpath" >&2
                        exit 1
                        ;;
                esac
            done <<< "$rpaths"
            ;;
        Linux)
            dynamic="$(readelf -d "$binary")"
            dependencies="$(ldd "$binary")"
            if grep -Eiq 'NEEDED.*libopus' <<< "$dynamic" \
                || grep -Eiq 'libopus' <<< "$dependencies"
            then
                echo "hermetic linkage FAILED: libopus remains external in $binary" >&2
                printf '%s\n' "$dynamic" >&2
                printf '%s\n' "$dependencies" >&2
                exit 1
            fi
            ;;
        *)
            echo "hermetic linkage FAILED: unsupported platform" >&2
            exit 1
            ;;
    esac
done

echo "hermetic linkage tests PASSED"
