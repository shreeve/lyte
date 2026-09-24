#!/bin/sh
# Sign Lyte with a stable identity: an Apple Development certificate
# (Local Network privacy relies on Apple-issued signing), else the
# self-signed "Lyte Dev" identity, which still preserves Keychain ACLs.
#
# Usage: Scripts/sign-dev.sh [--nested] <binary-or-.app> [<binary-or-.app> ...]
#
# --nested signs embedded third-party code (Sparkle's framework, its
# Autoupdate tool and Updater.app) with the same identity and runtime but
# keeps each piece's own identifier; sign nested code before its container.
#
# LYTE_SIGNING_IDENTITY may name a "Developer ID Application: …" identity
# for release builds (Scripts/release.sh); those signatures carry a secure
# timestamp, as notarization requires. Development signatures carry none.
#
# One-time setup: Scripts/setup-dev-signing.sh. Identity-bearing binaries
# fail closed without an identity: ad-hoc signing breaks the Keychain ACL
# and guarantees another authorization prompt.
#
# Every target is signed with the hardened runtime and no entitlements: the
# helper trusts the app's designated requirement and lyte-cli holds the
# pairing key, so a same-user process must not inject (DYLD_*, task-port
# attach). The binaries link only system libraries and use no JIT, so no
# exception is needed. Consequence: debuggers cannot attach; debug the
# unsigned SwiftPM binary or a copy re-signed with `codesign --force --sign -`.
set -e

NESTED=0
if [ "${1:-}" = --nested ]; then
    NESTED=1
    shift
fi
if [ "$#" -eq 0 ]; then
    echo "usage: Scripts/sign-dev.sh [--nested] <binary-or-.app> [<binary-or-.app> ...]" >&2
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
              toupper($2) == toupper(h) && (index($0, "\"Apple Development: ") \
                  || index($0, "\"Developer ID Application: ")) {
                  print
              }')"
    else
        case "$REQUESTED_IDENTITY" in
            "Apple Development: "*|"Developer ID Application: "*) ;;
            *)
                echo "error: requested identity is not Apple Development, Developer ID Application or Lyte Dev: $REQUESTED_IDENTITY" >&2
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

TIMESTAMP=--timestamp=none
case "$IDENTITY" in
    "Developer ID Application: "*)
        IDENTITY_KIND=developer-id
        TIMESTAMP=--timestamp
        ;;
esac

if [ "$NESTED" -eq 1 ]; then
    for target in "$@"; do
        codesign --force --sign "$IDENT_HASH" \
            --options runtime "$TIMESTAMP" "$target"
        codesign --verify --strict "$target"
    done
    exit 0
fi

SELECTED_TEAM=""
for target in "$@"; do
    case "$target" in
        *.app) ident="dev.shreeve.lyte" ;;
        *)     ident="dev.shreeve.$(basename "$target")" ;;
    esac
    codesign --force --sign "$IDENT_HASH" --identifier "$ident" \
        --options runtime "$TIMESTAMP" "$target"
    codesign --verify --strict "$target"
    signature_details="$(codesign -d --verbose=4 "$target" 2>&1)"
    actual_ident="$(printf '%s\n' "$signature_details" \
        | awk -F= '/^Identifier=/{print $2; exit}')"
    requirement="$(codesign -d -r- "$target" 2>&1)"
    stable_requirement=false
    if ! printf '%s\n' "$requirement" | grep -Fq "identifier \"$ident\""; then
        stable_requirement=false
    elif [ "$IDENTITY_KIND" = developer-id ]; then
        actual_team="$(printf '%s\n' "$signature_details" \
            | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
        if printf '%s\n' "$actual_team" | grep -Eq '^[A-Z0-9]{10}$' \
            && { [ -z "$SELECTED_TEAM" ] || [ "$SELECTED_TEAM" = "$actual_team" ]; } \
            && printf '%s\n' "$requirement" | grep -Fq 'anchor apple generic' \
            && printf '%s\n' "$requirement" | grep -Eq \
                "certificate leaf\\[subject\\.OU\\] = \"?$actual_team\"?"
        then
            SELECTED_TEAM="$actual_team"
            stable_requirement=true
        fi
    elif [ "$IDENTITY_KIND" = apple ]; then
        actual_team="$(printf '%s\n' "$signature_details" \
            | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
        if ! printf '%s\n' "$actual_team" | grep -Eq '^[A-Z0-9]{10}$'; then
            actual_team=""
        fi
        if [ -n "$actual_team" ] \
            && { [ -z "$SELECTED_TEAM" ] || [ "$SELECTED_TEAM" = "$actual_team" ]; } \
            && printf '%s\n' "$requirement" | grep -Fq 'anchor apple generic' \
            && printf '%s\n' "$requirement" | grep -Fq \
                "certificate leaf[subject.CN] = \"$IDENTITY\""
        then
            SELECTED_TEAM="$actual_team"
            stable_requirement=true
        fi
    elif printf '%s\n' "$requirement" | grep -Fq \
        "certificate root = H\"$(printf '%s' "$IDENT_HASH" | tr '[:upper:]' '[:lower:]')\""
    then
        stable_requirement=true
    fi
    if ! printf '%s\n' "$signature_details" \
        | grep -Eq '^CodeDirectory .*flags=0x[[:xdigit:]]+\([^)]*runtime'
    then
        echo "error: $target is not signed with the hardened runtime" >&2
        exit 1
    fi
    if [ "$actual_ident" != "$ident" ] \
        || [ "$stable_requirement" != true ]; then
        echo "error: unstable code requirement for $target" >&2
        echo "       expected identifier $ident under $IDENTITY ($IDENT_HASH)" >&2
        echo "       got: $requirement" >&2
        exit 1
    fi
done
