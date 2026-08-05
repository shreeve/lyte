#!/bin/sh
# Assemble Lyte.app from the SwiftPM build (dev bundling until a notarized
# release exists). The stable Lyte Dev signature preserves local identity.
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build \
  --package-path Client \
  --scratch-path .build \
  -c "$CONFIG" \
  --product Lyte
swift build \
  --package-path Client \
  --scratch-path .build \
  -c "$CONFIG" \
  --product lyte-helperd

# LaunchServices requires a numeric bundle build. Source identity is separate
# because a Git hash is provenance, not a valid CFBundleVersion.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  echo "error: bundle version requires full Git history" >&2
  echo "       fetch --unshallow before assembling Lyte.app" >&2
  exit 1
fi
BUNDLE_VERSION="$(git rev-list --count HEAD)"
SOURCE_REVISION="$(git rev-parse --short=12 HEAD)"
[ -n "$(git status --porcelain)" ] \
  && SOURCE_REVISION="${SOURCE_REVISION}+"
case "$BUNDLE_VERSION" in
  ''|*[!0-9]*)
    echo "error: Git produced a non-numeric bundle version" >&2
    exit 1
    ;;
esac

APP=".build/Lyte.app"
STAGE_ROOT="$(mktemp -d ".build/.lyte-app-stage.XXXXXX")"
STAGED_APP="$STAGE_ROOT/Lyte.app"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$STAGED_APP/Contents/MacOS" \
  "$STAGED_APP/Contents/Resources" \
  "$STAGED_APP/Contents/Library/LaunchDaemons"
cp ".build/$CONFIG/Lyte" "$STAGED_APP/Contents/MacOS/Lyte"
cp ".build/$CONFIG/lyte-helperd" "$STAGED_APP/Contents/MacOS/lyte-helperd"

# Exact source identity consumed by benchmark-app.sh. A signed bundle without
# this matching fingerprint is not valid benchmark evidence.
(
  git ls-files --cached --others --exclude-standard -- \
    Client/Package.swift Client/Package.resolved Client/Sources \
    Common/Package.swift Common/Sources \
    Wire/Package.swift Wire/Package.resolved Wire/Sources \
    | LC_ALL=C sort \
    | while IFS= read -r path; do
        if [ -f "$path" ]; then
          shasum -a 256 "$path"
        fi
      done
) | shasum -a 256 | awk '{print $1}' \
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
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.5.0</string>
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
</dict>
</plist>
EOF

# Validate and sign the complete staged bundle. sign-dev.sh fails closed when
# the stable identity is unavailable; the previously published app is left
# byte-for-byte untouched on any failure before publication.
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
"$(dirname "$0")/sign-dev.sh" \
  "$STAGED_APP/Contents/MacOS/lyte-helperd" "$STAGED_APP"

# macOS rename-swap publishes the complete signed directory in one filesystem
# operation. The old app moves into the private stage and the EXIT trap removes
# it. A first build has no destination yet, so ordinary rename is already
# atomic.
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
