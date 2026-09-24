#!/bin/sh
# Build lyte-cli and sign it with the stable development identity so the
# Keychain pairing-key grant survives the rebuild. Use this instead of a bare
# `swift build` whenever you'll run lyte-cli against a host.
#
# Usage: Scripts/build-cli.sh [debug|release]   (default: debug)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"
swift build \
  --package-path Client \
  --scratch-path .build \
  -c "$CONFIG" \
  -Xswiftc -warnings-as-errors \
  --product lyte-cli
"$ROOT/Scripts/normalize-macos-rpaths.sh" ".build/$CONFIG/lyte-cli"
"$ROOT/Scripts/sign-dev.sh" ".build/$CONFIG/lyte-cli"
echo "built + signed .build/$CONFIG/lyte-cli"
