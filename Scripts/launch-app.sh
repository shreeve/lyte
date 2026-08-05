#!/bin/sh
# Register and launch the exact signed Lyte.app artifact on disk.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Lyte.app}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ ! -x "$APP/Contents/MacOS/Lyte" ]; then
    echo "error: missing Lyte app at $APP" >&2
    echo "       build it first with Scripts/make-app.sh" >&2
    exit 1
fi
if [ ! -x "$LSREGISTER" ]; then
    echo "error: LaunchServices registration tool is unavailable" >&2
    exit 1
fi

RUNNING_PIDS="$(pgrep -x Lyte 2>/dev/null || true)"
if [ -n "$RUNNING_PIDS" ]; then
    echo "error: Lyte is already running (PID(s): $(printf '%s' "$RUNNING_PIDS" | tr '\n' ' '))" >&2
    echo "       quit it before registering a replacement build" >&2
    exit 1
fi

codesign --verify --strict "$APP"
IDENTIFIER="$(codesign -d --verbose=4 "$APP" 2>&1 \
    | awk -F= '/^Identifier=/{print $2; exit}')"
if [ "$IDENTIFIER" != dev.shreeve.lyte ]; then
    echo "error: unexpected bundle signing identifier: $IDENTIFIER" >&2
    exit 1
fi

# Atomic app publication changes the bundle inode. Force registration after
# signing and publication so LaunchServices sees this build's Mach-O UUID and
# CFBundleVersion before Local Network privacy evaluates it.
"$LSREGISTER" -f "$APP"
open -F "$APP"
