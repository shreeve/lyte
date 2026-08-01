#!/bin/sh
# Sign a Lyte dev binary with the stable "Lyte Dev" self-signed code-signing
# identity so the login-Keychain "Always Allow" grant for the pairing key
# survives rebuilds. An unsigned binary is identified by a hash of its bytes,
# so every rebuild is a new app the ACL has never seen → a fresh prompt. A
# stable signature makes the binary's designated requirement constant, so one
# "Always Allow" holds forever.
#
# Usage: Scripts/sign-dev.sh <binary-or-.app> [<binary-or-.app> ...]
#
# One-time setup lives in Scripts/setup-dev-signing.sh (creates the identity in
# a dedicated ~/Library/Keychains/lyte-signing keychain). Identity-bearing
# binaries fail closed when it is absent: an ad-hoc fallback silently destroys
# the Keychain ACL invariant and guarantees another authorization prompt.
set -e

IDENTITY="Lyte Dev"
# Plain find-identity (not -v): the self-signed cert is untrusted for chain
# validation, so -v hides it, but codesign signs with it by hash just fine.
IDENT_HASH="$(security find-identity ~/Library/Keychains/lyte-signing.keychain-db 2>/dev/null \
  | awk -v n="$IDENTITY" '$0 ~ n {print $2; exit}')"

if [ -z "$IDENT_HASH" ]; then
    echo "error: '$IDENTITY' identity not found." >&2
    echo "       run Scripts/setup-dev-signing.sh before building a Keychain client." >&2
    exit 1
fi

for target in "$@"; do
    case "$target" in
        *.app) ident="dev.shreeve.lyte" ;;
        *)     ident="dev.shreeve.$(basename "$target")" ;;
    esac
    codesign --force --sign "$IDENT_HASH" --identifier "$ident" --timestamp=none "$target"
    codesign --verify --strict "$target"
    actual_ident="$(codesign -d --verbose=4 "$target" 2>&1 \
        | awk -F= '/^Identifier=/{print $2; exit}')"
    requirement="$(codesign -d -r- "$target" 2>&1)"
    if [ "$actual_ident" != "$ident" ] \
        || ! printf '%s\n' "$requirement" | rg -Fq \
            "certificate root = H\"$(printf '%s' "$IDENT_HASH" | tr '[:upper:]' '[:lower:]')\""
    then
        echo "error: unstable code requirement for $target" >&2
        echo "       expected identifier $ident under Lyte Dev $IDENT_HASH" >&2
        echo "       got: $requirement" >&2
        exit 1
    fi
done
