#!/bin/sh
# The no-Foundation lint (core plan §1): LyteWire is sans-IO by rule, and
# the rule is enforced, not trusted. Fails on any import of Foundation,
# FoundationEssentials, FoundationNetworking, Dispatch, or Network in the
# LyteWire sources — including scoped imports like `import class
# Foundation.Thread`. LyteWireTestKit and the tests are exempt (file IO
# lives there on purpose).
#
# Usage: lint-no-foundation.sh [source-dir]
#   Default source-dir is Wire/Sources/LyteWire relative to this script.
#   NoFoundationLintTests runs this under `swift test` on both platforms;
#   CI needs nothing beyond `swift test`, or may invoke it directly.
set -eu

if [ $# -ge 1 ]; then
    dir="$1"
else
    dir="$(cd "$(dirname "$0")/../Sources/LyteWire" && pwd)"
fi

# BSD grep has no \b; a trailing non-identifier-or-EOL class serves both.
pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|typealias|func|var|let))?[[:space:]]+(Foundation|FoundationEssentials|FoundationNetworking|Dispatch|Network)([^A-Za-z0-9_]|$)'

violations=$(grep -rnE "$pattern" --include='*.swift' "$dir" || true)

if [ -n "$violations" ]; then
    echo "no-Foundation lint FAILED — forbidden imports in $dir:" >&2
    echo "$violations" >&2
    exit 1
fi

# Crypto confinement (core plan §1, W5): `import Crypto` may appear only
# under Crypto/ — the rest of the module sees the five-function internal
# surface, so a WASM backend swap stays a leaf swap. CryptoKit is
# forbidden everywhere: it is Apple-only, and swift-crypto's `Crypto`
# vends the identical API on Linux too.
crypto_pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|typealias|func|var|let))?[[:space:]]+(Crypto|CryptoKit)([^A-Za-z0-9_]|$)'

crypto_violations=$(
    grep -rnE "$crypto_pattern" --include='*.swift' "$dir" \
        | grep -v "^$dir/Crypto/" \
        || true
)
cryptokit_pattern='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|typealias|func|var|let))?[[:space:]]+CryptoKit([^A-Za-z0-9_]|$)'
cryptokit_violations=$(
    grep -rnE "$cryptokit_pattern" --include='*.swift' "$dir" || true
)

if [ -n "$crypto_violations" ]; then
    echo "crypto-confinement lint FAILED — import Crypto outside $dir/Crypto/:" >&2
    echo "$crypto_violations" >&2
    exit 1
fi
if [ -n "$cryptokit_violations" ]; then
    echo "crypto-confinement lint FAILED — CryptoKit is Apple-only, use swift-crypto's Crypto:" >&2
    echo "$cryptokit_violations" >&2
    exit 1
fi

echo "no-Foundation lint OK: $dir is Foundation-free (Crypto confined to Crypto/)"
