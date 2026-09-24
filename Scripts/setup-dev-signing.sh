#!/bin/sh
# One-time setup: create the stable "Lyte Dev" self-signed code-signing
# identity that Scripts/sign-dev.sh uses. Idempotent — safe to re-run.
#
# macOS records a Keychain "Always Allow" grant against a binary's code
# signature; a stable cert gives every rebuild the same designated
# requirement, so one grant survives rebuilds. The identity lives in a
# dedicated keychain (~/Library/Keychains/lyte-signing) with a known
# password, so codesign uses it non-interactively.
set -e

DIR="$HOME/.config/lyte-signing"
KC="$HOME/Library/Keychains/lyte-signing.keychain-db"
PW="lyte"                          # dedicated keychain only holds this dev cert
CN="Lyte Dev"

# quietly CMD...: runs CMD and shows its output only when it fails.
quietly() {
    if ! output="$("$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

mkdir -p "$DIR"; chmod 700 "$DIR"

# 1. Self-signed code-signing cert (20-year validity) if we don't have one.
if [ ! -f "$DIR/lyte-dev.p12" ]; then
    echo "creating '$CN' code-signing certificate…"
    quietly openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
        -keyout "$DIR/lyte-dev.key" -out "$DIR/lyte-dev.crt" \
        -subj "/CN=$CN/O=Lyte" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning"
    # -legacy: macOS `security` can't verify the PKCS#12 MAC OpenSSL 3 writes by default.
    quietly openssl pkcs12 -export -legacy -out "$DIR/lyte-dev.p12" \
        -inkey "$DIR/lyte-dev.key" -in "$DIR/lyte-dev.crt" \
        -passout "pass:$PW" -name "$CN"
    chmod 600 "$DIR"/*
fi

# 2. Dedicated keychain, added to the search list, with the identity imported.
if [ ! -f "$KC" ]; then
    echo "creating signing keychain $KC…"
    security create-keychain -p "$PW" "$KC"
fi
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"
# Keep the current search list, one quoted path per line; append ours if
# absent. Paths may contain spaces, so they are never word-split.
keychains="$(security list-keychains -d user)"
set --
while IFS= read -r keychain; do
    keychain="$(printf '%s\n' "$keychain" \
        | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
    if [ -n "$keychain" ]; then
        set -- "$@" "$keychain"
    fi
done <<EOF
$keychains
EOF
case "$keychains" in
    *lyte-signing*) : ;;
    *) security list-keychains -d user -s "$@" "$KC" ;;
esac

# Plain find-identity (not -v): -v hides the untrusted self-signed cert,
# which codesign still uses by hash.
if ! security find-identity "$KC" 2>/dev/null | grep -Fq "$CN"; then
    quietly security import "$DIR/lyte-dev.p12" -k "$KC" -P "$PW" \
        -T /usr/bin/codesign
fi
# Let codesign use the key without an interactive prompt.
if ! quietly security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC"
then
    echo "warning: codesign may prompt for the '$KC' password ($PW):" \
        "set-key-partition-list failed" >&2
fi

HASH="$(security find-identity "$KC" 2>/dev/null | awk -v n="$CN" '$0 ~ n {print $2; exit}')"
if [ -z "$HASH" ]; then
    echo "error: identity import failed — check $DIR/lyte-dev.p12" >&2
    exit 1
fi
echo "'$CN' ready ($HASH)."
echo "Next: build, then run Scripts/sign-dev.sh on the binary and click"
echo "'Always Allow' ONE more time. All future rebuilds are silent."
