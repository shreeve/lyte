#!/bin/sh
# Register and launch the exact signed Lyte.app artifact on disk.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Lyte.app}"
case "$APP" in
    /*) ;;
    *) APP="$PWD/$APP" ;;
esac
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
APP_EXECUTABLE="$APP/Contents/MacOS/Lyte"
LSREGISTER="${LYTE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
. "$ROOT/Scripts/AppArtifact/app-artifact.sh"

lyte_acquire_app_artifact_lock
lyte_require_app_quiescent "app launch"

if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "error: missing Lyte app at $APP" >&2
    echo "       build it first with Scripts/make-app.sh" >&2
    exit 1
fi
if [ ! -x "$LSREGISTER" ]; then
    echo "error: LaunchServices registration tool is unavailable" >&2
    exit 1
fi

"${LYTE_CODESIGN:-codesign}" --verify --strict "$APP"
IDENTIFIER="$("${LYTE_CODESIGN:-codesign}" -d --verbose=4 "$APP" 2>&1 \
    | awk -F= '/^Identifier=/{print $2; exit}')"
if [ "$IDENTIFIER" != dev.shreeve.lyte ]; then
    echo "error: unexpected bundle signing identifier: $IDENTIFIER" >&2
    exit 1
fi

# Atomic app publication changes the bundle inode. Force registration after
# signing and publication so LaunchServices sees this build's Mach-O UUID and
# CFBundleVersion before Local Network privacy evaluates it.
"$LSREGISTER" -f "$APP"
"${LYTE_OPEN:-open}" -F "$APP"
PID="$(lyte_wait_for_exact_app "$APP_EXECUTABLE")"
echo "launched $APP (PID $PID)"
