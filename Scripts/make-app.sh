#!/bin/sh
# Assemble Lyte.app from the SwiftPM build. A stable Apple Development
# signature preserves Local Network privacy identity and Keychain
# authorization; Lyte Dev is the contributor fallback.
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$ROOT/Scripts/AppArtifact/app-artifact.sh"
. "$ROOT/Scripts/lib/source-fingerprint.sh"

# usage: Scripts/make-app.sh [--diagnostics] [debug|release]
# The app's diagnostic entry points (autoconnect, the benchmark driver) obey
# the environment only in a bundle whose signed Info.plist enables them.
# Only the explicit flag builds one, never an inherited environment.
# benchmark-app.sh builds one at the everyday .build/Lyte.app (one physical
# copy per bundle identity) and restores the plain build when it exits.
DIAGNOSTICS=0
CONFIG=release
for argument in "$@"; do
  case "$argument" in
    --diagnostics) DIAGNOSTICS=1 ;;
    -*)
      echo "usage: Scripts/make-app.sh [--diagnostics] [debug|release]" >&2
      exit 2
      ;;
    *) CONFIG="$argument" ;;
  esac
done
if [ -n "${LYTE_APP_DIAGNOSTICS:-}" ]; then
  echo "note: make-app.sh ignores LYTE_APP_DIAGNOSTICS; pass --diagnostics" >&2
fi
if [ "$DIAGNOSTICS" -eq 1 ]; then
  DIAGNOSTIC_ENTRY_POINTS='<key>LyteDiagnosticEntryPoints</key> <true/>'
  PACKAGING_MODE=--diagnostics
else
  DIAGNOSTIC_ENTRY_POINTS=''
  PACKAGING_MODE=--plain
fi
LIVE_APP="$ROOT/.build/Lyte.app"
APP="${LYTE_APP_DESTINATION:-$LIVE_APP}"
case "$APP" in
  /*) ;;
  *) APP="$ROOT/$APP" ;;
esac
case "$APP" in
  "$LIVE_APP"/*)
    echo "error: isolated app destination cannot be inside $LIVE_APP" >&2
    exit 1
    ;;
esac

# Serialize before touching any destination state. Requiring an existing
# parent lets us canonicalize without creating caller-selected directories.
lyte_acquire_app_artifact_lock
if [ ! -d "$(dirname "$APP")" ]; then
  echo "error: app destination parent must already exist" >&2
  exit 1
fi
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
case "$APP" in
  "$ROOT/.build/"*) ;;
  *)
    echo "error: app destination must stay inside $ROOT/.build" >&2
    exit 1
    ;;
esac
case "$APP" in
  "$LIVE_APP") PUBLISHING_LIVE=1 ;;
  "$LIVE_APP"/*)
    echo "error: isolated app destination cannot be inside $LIVE_APP" >&2
    exit 1
    ;;
  *) PUBLISHING_LIVE=0 ;;
esac

[ "$PUBLISHING_LIVE" -eq 0 ] \
  || lyte_require_app_quiescent "live app publication"

# LaunchServices requires a numeric bundle build. Source identity is separate
# because a Git hash is provenance, not a valid CFBundleVersion.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "error: bundle version requires full Git history" >&2
  echo "       fetch --unshallow before assembling Lyte.app" >&2
  exit 1
fi
SOURCE_VERSION_FLOOR="$(git rev-list --count HEAD)"
SOURCE_REVISION="$(git rev-parse --short=12 HEAD)"
[ -n "$(git status --porcelain)" ] \
  && SOURCE_REVISION="${SOURCE_REVISION}+"
case "$SOURCE_VERSION_FLOOR" in
  ''|*[!0-9]*)
    echo "error: Git produced a non-numeric bundle version" >&2
    exit 1
    ;;
esac

PREVIOUS_BUNDLE_VERSION=0
if [ -f "$APP/Contents/Info.plist" ]; then
  if ! PREVIOUS_BUNDLE_VERSION="$(
    plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" \
      2>/dev/null
  )"; then
    echo "error: existing Lyte.app has no readable CFBundleVersion" >&2
    exit 1
  fi
fi
BUNDLE_VERSION="$(
  Scripts/next-bundle-version.sh \
    "$PREVIOUS_BUNDLE_VERSION" "$SOURCE_VERSION_FLOOR"
)"
# A development bundle reports the release it follows.
SHORT_VERSION="$(git describe --tags --abbrev=0 \
  --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | sed 's/^v//')"
printf '%s\n' "$SHORT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || SHORT_VERSION=0.0.0
# A release (Scripts/release.sh) sets LYTE_RELEASE_VERSION=X.Y.Z: it becomes
# the version people see, and only a release bundle carries the update feed
# and key, so a development build never checks for updates. Sparkle orders
# updates by CFBundleVersion, the increasing build number above.
SPARKLE_KEYS=""
if [ -n "${LYTE_RELEASE_VERSION:-}" ]; then
  if ! printf '%s\n' "$LYTE_RELEASE_VERSION" \
      | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: LYTE_RELEASE_VERSION must be X.Y.Z: $LYTE_RELEASE_VERSION" >&2
    exit 1
  fi
  SHORT_VERSION="$LYTE_RELEASE_VERSION"
  if [ ! -s Client/Updates/sparkle-public-key.txt ]; then
    echo "error: a release needs Client/Updates/sparkle-public-key.txt (docs/RELEASING.md)" >&2
    exit 1
  fi
  SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < Client/Updates/sparkle-public-key.txt)"
  SPARKLE_KEYS="<key>SUFeedURL</key> <string>https://github.com/shreeve/lyte/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key> <string>${SPARKLE_PUBLIC_KEY}</string>"
fi

swift build \
  --package-path Client \
  --scratch-path .build \
  -c "$CONFIG" \
  -Xswiftc -warnings-as-errors \
  --product Lyte
swift build \
  --package-path Client \
  --scratch-path .build \
  -c "$CONFIG" \
  -Xswiftc -warnings-as-errors \
  --product lyte-helperd

STAGE_ROOT="$(mktemp -d ".build/.lyte-app-stage.XXXXXX")"
STAGED_APP="$STAGE_ROOT/Lyte.app"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGED_APP/Contents/MacOS" \
  "$STAGED_APP/Contents/Resources" \
  "$STAGED_APP/Contents/Frameworks" \
  "$STAGED_APP/Contents/Library/LaunchDaemons"
cp ".build/$CONFIG/Lyte" "$STAGED_APP/Contents/MacOS/Lyte"
# Sparkle is a binary framework the app links from @rpath, thinned to the
# app's one architecture. Lyte is not sandboxed, so Sparkle's XPC services
# never run (SUEnableInstallerLauncherService is off); they are dropped
# rather than signed and shipped.
SPARKLE_FRAMEWORK="$(find .build/artifacts/sparkle -type d -name Sparkle.framework \
  -path '*macos-arm64*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
  echo "error: no Sparkle.framework under .build/artifacts/sparkle" >&2
  exit 1
fi
ditto --arch arm64 "$SPARKLE_FRAMEWORK" \
  "$STAGED_APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$STAGED_APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$STAGED_APP/Contents/MacOS/Lyte"
cp ".build/$CONFIG/lyte-helperd" "$STAGED_APP/Contents/MacOS/lyte-helperd"
cp Client/AppIcon/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp Common/Sources/COpus/Upstream/opus-1.6.1/COPYING \
  "$STAGED_APP/Contents/Resources/Opus-COPYING.txt"
cp Wire/Sources/CNanorsWire/LICENSE \
  "$STAGED_APP/Contents/Resources/nanors-LICENSE.txt"
cp .build/checkouts/swift-crypto/LICENSE.txt \
  "$STAGED_APP/Contents/Resources/SwiftCrypto-LICENSE.txt"
cp .build/checkouts/swift-crypto/NOTICE.txt \
  "$STAGED_APP/Contents/Resources/SwiftCrypto-NOTICE.txt"
cp .build/checkouts/swift-asn1/LICENSE.txt \
  "$STAGED_APP/Contents/Resources/SwiftASN1-LICENSE.txt"
cp .build/checkouts/swift-asn1/NOTICE.txt \
  "$STAGED_APP/Contents/Resources/SwiftASN1-NOTICE.txt"
cp .build/checkouts/Sparkle/LICENSE \
  "$STAGED_APP/Contents/Resources/Sparkle-LICENSE.txt"

Scripts/normalize-macos-rpaths.sh \
  "$STAGED_APP/Contents/MacOS/Lyte" \
  "$STAGED_APP/Contents/MacOS/lyte-helperd"

# Exact source identity consumed by benchmark-app.sh. A signed bundle without
# this matching fingerprint is not valid benchmark evidence.
# shellcheck disable=SC2086  # the path list is space-separated by design
lyte_source_fingerprint "$ROOT" $LYTE_CLIENT_SOURCE_PATHS \
  > "$STAGED_APP/Contents/Resources/client-source.sha256"
date -u +%Y-%m-%dT%H:%M:%SZ \
  > "$STAGED_APP/Contents/Resources/build-utc.txt"

# Privileged helper daemon (SMAppService): holds awdl0 down during streams
cat > "$STAGED_APP/Contents/Library/LaunchDaemons/dev.shreeve.lyte.helper.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.shreeve.lyte.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/lyte-helperd</string>
    <key>MachServices</key>
    <dict>
        <key>dev.shreeve.lyte.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>dev.shreeve.lyte</string>
    </array>
</dict>
</plist>
EOF

cat > "$STAGED_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>Lyte</string>
    <key>CFBundleIdentifier</key>       <string>dev.shreeve.lyte</string>
    <key>CFBundleName</key>             <string>Lyte</string>
    <key>CFBundleDisplayName</key>      <string>Lyte</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key>          <string>${BUNDLE_VERSION}</string>
    <key>LyteSourceRevision</key>       <string>${SOURCE_REVISION}</string>
    <key>LSMinimumSystemVersion</key>   <string>15.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.games</string>
    <key>NSHumanReadableCopyright</key> <string>© 2026 Steve Shreeve · MIT</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Lyte discovers and streams from Lyte hosts on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_lyte._udp</string></array>
    <key>SUEnableInstallerLauncherService</key> <false/>
    ${SPARKLE_KEYS}
    ${DIAGNOSTIC_ENTRY_POINTS}
</dict>
</plist>
EOF

# Validate and sign the staged bundle; sign-dev.sh fails closed without the
# stable identity, leaving the published app untouched.
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
SPARKLE_EMBEDDED="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
"$ROOT/Scripts/sign-dev.sh" --nested \
  "$SPARKLE_EMBEDDED/Versions/B/Autoupdate" \
  "$SPARKLE_EMBEDDED/Versions/B/Updater.app" \
  "$SPARKLE_EMBEDDED"
"$ROOT/Scripts/sign-dev.sh" \
  "$STAGED_APP/Contents/MacOS/lyte-helperd" "$STAGED_APP"

# Validate the exact staged artifact before the rename-swap can replace the
# last known-good app. The CI gate repeats these checks after publication.
Scripts/Tests/test-app-packaging.sh "$PACKAGING_MODE" "$STAGED_APP" "$STAGE_ROOT"
Scripts/Tests/test-hermetic-linkage.sh \
  "$STAGED_APP/Contents/MacOS/Lyte" \
  "$STAGED_APP/Contents/MacOS/lyte-helperd"

# The shared lock excludes the scripted launcher and concurrent publishers.
# Recheck external process state immediately before replacing the live bundle.
[ "$PUBLISHING_LIVE" -eq 0 ] \
  || lyte_require_app_quiescent "live app publication"

# macOS rename-swap publishes the signed directory in one filesystem
# operation (the EXIT trap removes the old app); a first build's plain
# rename is already atomic.
python3 - "$STAGED_APP" "$APP" <<'PY'
import ctypes
import os
import sys

source, destination = map(os.fsencode, sys.argv[1:])
if not os.path.exists(destination):
    os.rename(source, destination)
else:
    libc = ctypes.CDLL(None, use_errno=True)
    renamex_np = libc.renamex_np
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    if renamex_np(source, destination, 0x00000002) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), os.fsdecode(destination))
PY
echo "assembled $APP"
