#!/bin/sh
# Assemble Lyte.app from the SwiftPM build (dev bundling until M7 ships a
# proper signed/notarized app). Ad-hoc signed so TCC permissions stick.
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Lyte
swift build -c "$CONFIG" --product lyte-helperd

# The About box answers "which build am I running?": CFBundleVersion is
# the git short hash, with "+" when the tree had uncommitted changes.
BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git status --porcelain 2>/dev/null)" ] && BUILD_ID="${BUILD_ID}+"

APP=".build/Lyte.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
  "$APP/Contents/Library/LaunchDaemons"
cp ".build/$CONFIG/Lyte" "$APP/Contents/MacOS/Lyte"
cp ".build/$CONFIG/lyte-helperd" "$APP/Contents/MacOS/lyte-helperd"

# Exact source identity consumed by benchmark-app.sh. A signed bundle without
# this matching fingerprint is not valid benchmark evidence.
(
  git ls-files --cached --others --exclude-standard -- \
    Package.swift Sources Common/Package.swift Common/Core Common/IO \
    | LC_ALL=C sort \
    | while IFS= read -r path; do
        if [ -f "$path" ]; then
          shasum -a 256 "$path"
        fi
      done
) | shasum -a 256 | awk '{print $1}' \
  > "$APP/Contents/Resources/client-source.sha256"
date -u +%Y-%m-%dT%H:%M:%SZ \
  > "$APP/Contents/Resources/build-utc.txt"

# Privileged helper daemon (SMAppService): holds awdl0 down during streams
cat > "$APP/Contents/Library/LaunchDaemons/dev.shreeve.lyte.helper.plist" <<'EOF'
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

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>Lyte</string>
    <key>CFBundleIdentifier</key>       <string>dev.shreeve.lyte</string>
    <key>CFBundleName</key>             <string>Lyte</string>
    <key>CFBundleDisplayName</key>      <string>Lyte</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.5</string>
    <key>CFBundleVersion</key>          <string>${BUILD_ID}</string>
    <key>LSMinimumSystemVersion</key>   <string>15.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.games</string>
    <key>NSHumanReadableCopyright</key> <string>© 2026 Steve Shreeve · GPL-3.0</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Lyte discovers and streams from Lyte hosts on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_lyte._udp</string></array>
</dict>
</plist>
EOF

# Sign with the stable "Lyte Dev" identity (falls back to ad-hoc with a warning
# if setup-dev-signing.sh hasn't been run). A stable signature keeps the
# Keychain "Always Allow" grant for the pairing key valid across rebuilds.
"$(dirname "$0")/sign-dev.sh" "$APP/Contents/MacOS/lyte-helperd" "$APP"
echo "assembled $APP"
