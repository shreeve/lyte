#!/bin/sh
# One-time setup: create the stable "Lyte Dev" self-signed code-signing
# identity that Scripts/sign-dev.sh uses. Idempotent — safe to re-run.
#
# Why: macOS records a Keychain "Always Allow" grant against a binary's code
# signature. Unsigned SwiftPM output has none, so its identity is a hash of its
# bytes and every rebuild re-prompts. A stable signing cert gives every build
# the same designated requirement, so one "Always Allow" for the Lyte pairing
# key holds across all future rebuilds.
#
# The identity lives in a DEDICATED keychain (~/Library/Keychains/lyte-signing)
# with a known password, so codesign can use the key non-interactively without
# touching the login keychain's security posture.
set -e

DIR="$HOME/.config/lyte-signing"
KC="$HOME/Library/Keychains/lyte-signing.keychain-db"
PW="lyte"                          # dedicated keychain only holds this dev cert
CN="Lyte Dev"

mkdir -p "$DIR"; chmod 700 "$DIR"

# 1. Self-signed code-signing cert (20-year validity) if we don't have one.
if [ ! -f "$DIR/lyte-dev.p12" ]; then
    echo "creating '$CN' code-signing certificate…"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
        -keyout "$DIR/lyte-dev.key" -out "$DIR/lyte-dev.crt" \
        -subj "/CN=$CN/O=Lyte" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    # -legacy: macOS `security` can't verify the PKCS#12 MAC OpenSSL 3 writes by default.
    openssl pkcs12 -export -legacy -out "$DIR/lyte-dev.p12" \
        -inkey "$DIR/lyte-dev.key" -in "$DIR/lyte-dev.crt" \
        -passout "pass:$PW" -name "$CN" >/dev/null 2>&1
    chmod 600 "$DIR"/*
fi

# 2. Dedicated keychain, added to the search list, with the identity imported.
if [ ! -f "$KC" ]; then
    echo "creating signing keychain $KC…"
    security create-keychain -p "$PW" "$KC"
fi
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"
# Keep current search list; append ours if absent.
CURRENT="$(security list-keychains -d user | sed 's/"//g' | xargs)"
case "$CURRENT" in
    *lyte-signing*) : ;;
    *) security list-keychains -d user -s $CURRENT "$KC" ;;
esac

# Plain find-identity (not -v): a self-signed cert is untrusted for chain
# validation so -v never lists it, but codesign uses it by hash regardless.
if ! security find-identity "$KC" 2>/dev/null | grep -q "$CN"; then
    security import "$DIR/lyte-dev.p12" -k "$KC" -P "$PW" -A -T /usr/bin/codesign >/dev/null 2>&1
fi
# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1 || true

HASH="$(security find-identity "$KC" 2>/dev/null | awk -v n="$CN" '$0 ~ n {print $2; exit}')"
if [ -z "$HASH" ]; then
    echo "error: identity import failed — check $DIR/lyte-dev.p12" >&2
    exit 1
fi
echo "'$CN' ready ($HASH)."
echo "Next: build, then run Scripts/sign-dev.sh on the binary and click"
echo "'Always Allow' ONE more time. All future rebuilds are silent."
