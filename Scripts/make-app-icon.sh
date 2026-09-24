#!/bin/bash
# Regenerates Client/AppIcon/AppIcon.icns from the two vector masters:
#   lyte-icon.svg        64 px and up
#   lyte-icon-small.svg  16 and 32 px (no hairlines or streaks, heavier edges)
# Scripts/lib/render-app-icon.swift rasterizes them with AppKit and adds the
# Dock shadow; iconutil packs the result. Run it after editing either SVG and
# commit the .icns with it; make-app.sh only copies the file.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/Scripts/lib/assert.sh"
art="$repo_root/Client/AppIcon"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lyte-app-icon.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

iconset="$scratch/AppIcon.iconset"
mkdir "$iconset"
swift "$repo_root/Scripts/lib/render-app-icon.swift" "$art" "$iconset" \
    || fail "rendering the icon masters failed"
iconutil -c icns -o "$art/AppIcon.icns" "$iconset" \
    || fail "iconutil refused the rendered iconset"
echo "wrote $art/AppIcon.icns"
