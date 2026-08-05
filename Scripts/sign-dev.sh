#!/bin/sh
# Sign Lyte with a stable identity. Prefer an Apple Development certificate:
# macOS Local Network privacy explicitly relies on Apple-issued signing for
# reliable app tracking. Contributors without one fall back to the dedicated
# self-signed "Lyte Dev" identity, which still preserves Keychain ACLs.
#
# Usage: Scripts/sign-dev.sh <binary-or-.app> [<binary-or-.app> ...]
#
# One-time setup lives in Scripts/setup-dev-signing.sh (creates the identity in
# a dedicated ~/Library/Keychains/lyte-signing keychain). Identity-bearing
# binaries fail closed when it is absent: an ad-hoc fallback silently destroys
# the Keychain ACL invariant and guarantees another authorization prompt.
set -e

if [ "$#" -eq 0 ]; then
    echo "usage: Scripts/sign-dev.sh <binary-or-.app> [<binary-or-.app> ...]" >&2
    exit 2
fi

REQUESTED_IDENTITY="${LYTE_SIGNING_IDENTITY:-}"
IDENTITY=""
IDENT_HASH=""
IDENTITY_KIND="apple"
VALID_IDENTITIES=""
if [ "$REQUESTED_IDENTITY" != "Lyte Dev" ]; then
    VALID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
fi

# Apple selection is fail-closed. A name is accepted only when it identifies
# one certificate; a SHA-1 hash is the unambiguous override for duplicate names.
IDENT_LINE=""
if [ "$REQUESTED_IDENTITY" = "Lyte Dev" ]; then
    IDENTITY_KIND="self-signed"
elif [ -n "$REQUESTED_IDENTITY" ]; then
    if printf '%s\n' "$REQUESTED_IDENTITY" \
        | grep -Eq '^[[:xdigit:]]{40}$'
    then
        IDENT_LINE="$(printf '%s\n' "$VALID_IDENTITIES" \
          | awk -v h="$REQUESTED_IDENTITY" '
              toupper($2) == toupper(h) && index($0, "\"Apple Development: ") {
                  print
              }')"
    else
        case "$REQUESTED_IDENTITY" in
            "Apple Development: "*) ;;
            *)
                echo "error: requested identity is not Apple Development or Lyte Dev: $REQUESTED_IDENTITY" >&2
                exit 1
                ;;
        esac
        IDENT_LINE="$(printf '%s\n' "$VALID_IDENTITIES" \
          | awk -v n="$REQUESTED_IDENTITY" \
              'index($0, "\"" n "\"") {print}')"
    fi
    MATCH_COUNT="$(printf '%s\n' "$IDENT_LINE" \
      | awk 'NF {count++} END {print count + 0}')"
    if [ "$MATCH_COUNT" -eq 0 ]; then
        echo "error: requested Apple signing identity not found: $REQUESTED_IDENTITY" >&2
        exit 1
    fi
    if [ "$MATCH_COUNT" -gt 1 ]; then
        echo "error: requested Apple signing identity is ambiguous: $REQUESTED_IDENTITY" >&2
        echo "       select its 40-character SHA-1 hash instead." >&2
        exit 1
    fi
else
    IDENT_LINE="$(printf '%s\n' "$VALID_IDENTITIES" \
      | awk 'index($0, "\"Apple Development: ") {print}')"
    MATCH_COUNT="$(printf '%s\n' "$IDENT_LINE" \
      | awk 'NF {count++} END {print count + 0}')"
    if [ "$MATCH_COUNT" -gt 1 ]; then
        echo "error: multiple Apple Development identities found." >&2
        echo "       set LYTE_SIGNING_IDENTITY to an exact 40-character SHA-1 hash." >&2
        exit 1
    fi
fi

if [ -n "$IDENT_LINE" ]; then
    IDENTITY="$(printf '%s\n' "$IDENT_LINE" \
      | sed -n 's/.*"\(.*\)".*/\1/p')"
    IDENT_HASH="$(printf '%s\n' "$IDENT_LINE" | awk '{print $2}')"
fi

if [ "$IDENTITY_KIND" = "self-signed" ] || [ -z "$IDENT_HASH" ]; then
    IDENTITY="Lyte Dev"
    IDENTITY_KIND="self-signed"
    # Plain find-identity (not -v): chain validation hides a self-signed
    # certificate even though codesign can use it by hash.
    IDENT_HASH="$(security find-identity \
      ~/Library/Keychains/lyte-signing.keychain-db 2>/dev/null \
      | awk -v n="$IDENTITY" 'index($0, "\"" n "\"") {print $2; exit}')"
fi

if [ -z "$IDENT_HASH" ]; then
    echo "error: '$IDENTITY' identity not found." >&2
    echo "       install an Apple Development identity or run" >&2
    echo "       Scripts/setup-dev-signing.sh before building a Keychain client." >&2
    exit 1
fi

SELECTED_TEAM=""
for target in "$@"; do
    case "$target" in
        *.app) ident="dev.shreeve.lyte" ;;
        *)     ident="dev.shreeve.$(basename "$target")" ;;
    esac
    codesign --force --sign "$IDENT_HASH" --identifier "$ident" --timestamp=none "$target"
    codesign --verify --strict "$target"
    signature_details="$(codesign -d --verbose=4 "$target" 2>&1)"
    actual_ident="$(printf '%s\n' "$signature_details" \
        | awk -F= '/^Identifier=/{print $2; exit}')"
    requirement="$(codesign -d -r- "$target" 2>&1)"
    stable_requirement=false
    if ! printf '%s\n' "$requirement" | rg -Fq "identifier \"$ident\""; then
        stable_requirement=false
    elif [ "$IDENTITY_KIND" = apple ]; then
        actual_team="$(printf '%s\n' "$signature_details" \
            | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
        if ! printf '%s\n' "$actual_team" | grep -Eq '^[A-Z0-9]{10}$'; then
            actual_team=""
        fi
        if [ -n "$actual_team" ] \
            && { [ -z "$SELECTED_TEAM" ] || [ "$SELECTED_TEAM" = "$actual_team" ]; } \
            && printf '%s\n' "$requirement" | rg -Fq 'anchor apple generic' \
            && printf '%s\n' "$requirement" | rg -Fq \
                "certificate leaf[subject.CN] = \"$IDENTITY\""
        then
            SELECTED_TEAM="$actual_team"
            stable_requirement=true
        fi
    elif printf '%s\n' "$requirement" | rg -Fq \
        "certificate root = H\"$(printf '%s' "$IDENT_HASH" | tr '[:upper:]' '[:lower:]')\""
    then
        stable_requirement=true
    fi
    if [ "$actual_ident" != "$ident" ] \
        || [ "$stable_requirement" != true ]; then
        echo "error: unstable code requirement for $target" >&2
        echo "       expected identifier $ident under $IDENTITY ($IDENT_HASH)" >&2
        echo "       got: $requirement" >&2
        exit 1
    fi
done
