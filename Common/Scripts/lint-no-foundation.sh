#!/bin/sh
# LyteCore is shared sans-IO policy. Keep OS frameworks at the LyteIO seam.
set -eu

if [ $# -ge 1 ]; then
    dir="$1"
else
    dir="$(cd "$(dirname "$0")/../Sources/LyteCore" && pwd)"
fi

pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|typealias|func|var|let))?[[:space:]]+(Foundation|FoundationEssentials|FoundationNetworking|Dispatch|Network|Crypto|CryptoKit)([^A-Za-z0-9_]|$)'
violations=$(grep -rnE "$pattern" --include='*.swift' "$dir" || true)

if [ -n "$violations" ]; then
    echo "LyteCore sans-IO lint FAILED — forbidden imports in $dir:" >&2
    echo "$violations" >&2
    exit 1
fi

echo "LyteCore sans-IO lint OK: $dir"
