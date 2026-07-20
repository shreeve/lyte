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
# a dedicated ~/Library/Keychains/lyte-signing keychain). If the identity is
# missing this script signs ad-hoc and warns, so builds never hard-fail on a
# fresh machine.
set -e

IDENTITY="Lyte Dev"
# Plain find-identity (not -v): the self-signed cert is untrusted for chain
# validation, so -v hides it, but codesign signs with it by hash just fine.
IDENT_HASH="$(security find-identity ~/Library/Keychains/lyte-signing.keychain-db 2>/dev/null \
  | awk -v n="$IDENTITY" '$0 ~ n {print $2; exit}')"

if [ -z "$IDENT_HASH" ]; then
    echo "warning: '$IDENTITY' identity not found — signing ad-hoc." >&2
    echo "         run Scripts/setup-dev-signing.sh once to stop keychain re-prompts." >&2
    IDENT_HASH="-"
fi

for target in "$@"; do
    case "$target" in
        *.app) ident="dev.shreeve.lyte" ;;
        *)     ident="dev.shreeve.$(basename "$target")" ;;
    esac
    codesign --force --sign "$IDENT_HASH" --identifier "$ident" --timestamp=none "$target"
done
