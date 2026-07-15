#!/bin/sh
# Assemble Lyte.app from the SwiftPM build (dev bundling until M7 ships a
# proper signed/notarized app). Ad-hoc signed so TCC permissions stick.
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Lyte
swift build -c "$CONFIG" --product lyte-helperd

APP=".build/Lyte.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp ".build/$CONFIG/Lyte" "$APP/Contents/MacOS/Lyte"
cp ".build/$CONFIG/lyte-helperd" "$APP/Contents/MacOS/lyte-helperd"

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

cat > "$APP/Contents/Info.plist" <<'EOF'
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
    <key>CFBundleVersion</key>          <string>5</string>
    <key>LSMinimumSystemVersion</key>   <string>15.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.games</string>
    <key>NSHumanReadableCopyright</key> <string>© 2026 Steve Shreeve · GPL-3.0</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Lyte discovers and streams from Sunshine hosts on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_nvstream._tcp</string></array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP/Contents/MacOS/lyte-helperd"
codesign --force --sign - "$APP"
echo "assembled $APP"
