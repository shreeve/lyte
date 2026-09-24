#!/bin/sh
# Print a monotonically increasing numeric CFBundleVersion.
#
# A rebuilt Mach-O gets a new UUID, which Local Network privacy includes in
# program identity, while LaunchServices may keep the prior executable when
# path and version are unchanged; a fresh version keeps them distinct.
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
