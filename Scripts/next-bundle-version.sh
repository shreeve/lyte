#!/bin/sh
# Print a monotonically increasing numeric CFBundleVersion.
#
# A rebuilt Mach-O receives a new UUID even when source did not change. macOS
# Local Network privacy includes that UUID in program identity, while
# LaunchServices may retain the prior executable when path and bundle version
# are unchanged. Give every assembled app a fresh version so those identities
# cannot be mistaken for the same artifact.
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: Scripts/next-bundle-version.sh <previous> <source-floor>" >&2
    exit 2
fi

PREVIOUS="$1"
SOURCE_FLOOR="$2"
NOW="${LYTE_BUILD_EPOCH:-$(date -u +%s)}"

for value in "$PREVIOUS" "$SOURCE_FLOOR" "$NOW"; do
    case "$value" in
        ''|*[!0-9]*)
            echo "error: bundle-version inputs must be non-negative integers" >&2
            exit 1
            ;;
    esac
done

NEXT="$NOW"
if [ "$NEXT" -le "$PREVIOUS" ]; then
    NEXT=$((PREVIOUS + 1))
fi
if [ "$NEXT" -lt "$SOURCE_FLOOR" ]; then
    NEXT="$SOURCE_FLOOR"
fi

printf '%s\n' "$NEXT"
