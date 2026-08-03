#!/bin/sh
# Build lyte-cli and sign it with the stable "Lyte Dev" identity so the
# Keychain pairing-key grant survives the rebuild. Use this instead of a bare
# `swift build` whenever you'll run lyte-cli against a host.
#
# Usage: Scripts/build-cli.sh [debug|release]   (default: debug)
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build \
  --package-path Client \
  --scratch-path .build \
  -c "$CONFIG" \
  --product lyte-cli
"$(dirname "$0")/sign-dev.sh" ".build/$CONFIG/lyte-cli"
echo "built + signed .build/$CONFIG/lyte-cli"
