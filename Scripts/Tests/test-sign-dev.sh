#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sign_dev="$repo_root/Scripts/sign-dev.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/lyte-sign-dev.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

fake_bin="$fixture_root/bin"
fake_home="$fixture_root/home"
valid_identities="$fixture_root/valid-identities"
fallback_identities="$fixture_root/fallback-identities"
security_log="$fixture_root/security.log"
codesign_log="$fixture_root/codesign.log"
codesign_state="$fixture_root/codesign.state"
mkdir -p "$fake_bin" "$fake_home" "$fixture_root/Lyte.app"
: > "$fixture_root/lyte-cli"

cat > "$fake_bin/security" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SECURITY_LOG"
if [ "$#" -eq 4 ] \
    && [ "$1" = find-identity ] \
    && [ "$2" = -v ] \
    && [ "$3" = -p ] \
    && [ "$4" = codesigning ]
then
    /bin/cat "$FAKE_VALID_IDENTITIES_FILE"
elif [ "$#" -eq 2 ] \
    && [ "$1" = find-identity ] \
    && [ "$2" = "$HOME/Library/Keychains/lyte-signing.keychain-db" ]
then
    /bin/cat "$FAKE_FALLBACK_IDENTITIES_FILE"
else
    echo "unexpected security invocation: $*" >&2
    exit 90
fi
EOF

cat > "$fake_bin/codesign" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CODESIGN_LOG"
case "$1" in
    --force)
        hash=""
        identifier=""
        target=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --sign) hash="$2"; shift 2 ;;
                --identifier) identifier="$2"; shift 2 ;;
                --timestamp=none|--force) shift ;;
                *) target="$1"; shift ;;
            esac
        done
        case "$hash" in
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)
                identity="Apple Development: Ada One (TEAMONE123)"
                team="TEAMAAAA01" ;;
            BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB)
                identity="Apple Development: Bob Two (TEAMTWO456)"
                team="TEAMBBBB02" ;;
            FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                identity="Apple Development: Ada One (TEAMONE123)"
                team="TEAMFFFF03" ;;
            DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD)
                identity="Lyte Dev"
                team="" ;;
            *)
                echo "unexpected signing hash: $hash" >&2
                exit 91 ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$hash" "$identity" "$identifier" "$team" \
            > "$FAKE_CODESIGN_STATE"
        ;;
    --verify)
        [ "${FAKE_VERIFY_MODE:-pass}" != fail ]
        ;;
    -d)
        IFS="	" read -r hash identity identifier team \
            < "$FAKE_CODESIGN_STATE"
        case "$2" in
            --verbose=4)
                if [ "${FAKE_IDENTIFIER_MODE:-correct}" = wrong ]; then
                    echo "Identifier=dev.shreeve.wrong" >&2
                else
                    echo "Identifier=$identifier" >&2
                fi
                if [ -n "$team" ] && [ "${FAKE_TEAM_MODE:-correct}" != missing ]; then
                    if [ "${FAKE_TEAM_MODE:-correct}" = mismatch ] \
                        && [ "$identifier" = dev.shreeve.lyte-cli ]; then
                        echo "TeamIdentifier=TEAMOTHER4" >&2
                    else
                        echo "TeamIdentifier=$team" >&2
                    fi
                fi
                ;;
            -r-)
                lower_hash="$(printf '%s' "$hash" \
                    | tr '[:upper:]' '[:lower:]')"
                case "${FAKE_REQUIREMENT_MODE:-correct}" in
                    correct)
                        if [ "$identity" = "Lyte Dev" ]; then
                            echo "designated => identifier \"$identifier\" and certificate root = H\"$lower_hash\"" >&2
                        else
                            echo "designated => identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.CN] = \"$identity\"" >&2
                        fi
                        ;;
                    apple_missing_anchor)
                        echo "designated => identifier \"$identifier\" and certificate leaf[subject.CN] = \"$identity\"" >&2 ;;
                    apple_wrong_cn)
                        echo "designated => identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.CN] = \"Wrong\"" >&2 ;;
                    missing_dr_identifier)
                        echo "designated => anchor apple generic and certificate leaf[subject.CN] = \"$identity\"" >&2 ;;
                    self_wrong_root)
                        echo "designated => identifier \"$identifier\" and certificate root = H\"0000000000000000000000000000000000000000\"" >&2 ;;
                    *)
                        echo "unknown requirement mode" >&2
                        exit 92 ;;
                esac
                ;;
            *)
                echo "unexpected codesign display invocation: $*" >&2
                exit 93 ;;
        esac
        ;;
    *)
        echo "unexpected codesign invocation: $*" >&2
        exit 94 ;;
esac
EOF
chmod +x "$fake_bin/security" "$fake_bin/codesign"

write_one_apple() {
    printf '%s\n' \
        '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Ada One (TEAMONE123)"' \
        > "$valid_identities"
}

write_two_apples() {
    printf '%s\n' \
        '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Ada One (TEAMONE123)"' \
        '  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Bob Two (TEAMTWO456)"' \
        > "$valid_identities"
}

write_duplicate_name_apples() {
    printf '%s\n' \
        '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Ada One (TEAMONE123)"' \
        '  2) FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "Apple Development: Ada One (TEAMONE123)"' \
        > "$valid_identities"
}

write_fallback() {
    printf '%s\n' \
        '  1) EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE "Old Lyte Dev"' \
        '  2) DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD "Lyte Dev"' \
        > "$fallback_identities"
}

reset_logs() {
    : > "$security_log"
    : > "$codesign_log"
}

run_signer() {
    HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    FAKE_VALID_IDENTITIES_FILE="$valid_identities" \
    FAKE_FALLBACK_IDENTITIES_FILE="$fallback_identities" \
    FAKE_SECURITY_LOG="$security_log" \
    FAKE_CODESIGN_LOG="$codesign_log" \
    FAKE_CODESIGN_STATE="$codesign_state" \
    FAKE_REQUIREMENT_MODE="${FAKE_REQUIREMENT_MODE:-correct}" \
    FAKE_IDENTIFIER_MODE="${FAKE_IDENTIFIER_MODE:-correct}" \
    FAKE_TEAM_MODE="${FAKE_TEAM_MODE:-correct}" \
    FAKE_VERIFY_MODE="${FAKE_VERIFY_MODE:-pass}" \
    LYTE_SIGNING_IDENTITY="${LYTE_SIGNING_IDENTITY:-}" \
    "$sign_dev" "$@"
}

expect_failure() {
    local expected="$1"
    shift
    local stderr="$fixture_root/stderr"
    if "$@" 2> "$stderr"; then
        echo "expected command to fail: $*" >&2
        exit 1
    fi
    if [[ -n "$expected" ]]; then
        grep -Fq "$expected" "$stderr"
    fi
}

write_one_apple
write_fallback
reset_logs
run_signer "$fixture_root/Lyte.app" "$fixture_root/lyte-cli"
grep -Fq -- "--force --sign AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --identifier dev.shreeve.lyte --timestamp=none $fixture_root/Lyte.app" "$codesign_log"
grep -Fq -- "--verify --strict $fixture_root/Lyte.app" "$codesign_log"
grep -Fq -- "--force --sign AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA --identifier dev.shreeve.lyte-cli --timestamp=none $fixture_root/lyte-cli" "$codesign_log"
[[ "$(<"$security_log")" == 'find-identity -v -p codesigning' ]]

write_two_apples
reset_logs
expect_failure "multiple Apple Development identities" run_signer \
    "$fixture_root/Lyte.app"
[[ ! -s "$codesign_log" ]]

reset_logs
LYTE_SIGNING_IDENTITY='Apple Development: Bob Two (TEAMTWO456)' \
    run_signer "$fixture_root/Lyte.app"
grep -Fq -- '--sign BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' "$codesign_log"

reset_logs
LYTE_SIGNING_IDENTITY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    run_signer "$fixture_root/Lyte.app"
grep -Fq -- '--sign AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$codesign_log"

write_duplicate_name_apples
reset_logs
LYTE_SIGNING_IDENTITY='Apple Development: Ada One (TEAMONE123)' \
    expect_failure "is ambiguous" run_signer "$fixture_root/Lyte.app"
[[ ! -s "$codesign_log" ]]

reset_logs
LYTE_SIGNING_IDENTITY=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    run_signer "$fixture_root/Lyte.app"
grep -Fq -- '--sign FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' "$codesign_log"

write_two_apples
reset_logs
LYTE_SIGNING_IDENTITY='Apple Development: Missing (MISSING123)' \
    expect_failure "requested Apple signing identity not found" run_signer \
        "$fixture_root/Lyte.app"
[[ ! -s "$codesign_log" ]]
[[ "$(<"$security_log")" == 'find-identity -v -p codesigning' ]]

reset_logs
LYTE_SIGNING_IDENTITY='Developer ID Application: Ada One (TEAMONE123)' \
    expect_failure "not Apple Development or Lyte Dev" run_signer \
        "$fixture_root/Lyte.app"
[[ ! -s "$codesign_log" ]]

reset_logs
LYTE_SIGNING_IDENTITY='Lyte Dev' run_signer "$fixture_root/Lyte.app"
grep -Fq -- '--sign DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD' "$codesign_log"
[[ "$(<"$security_log")" == \
    "find-identity $fake_home/Library/Keychains/lyte-signing.keychain-db" ]]

: > "$valid_identities"
reset_logs
run_signer "$fixture_root/Lyte.app"
grep -Fq -- '--sign DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD' "$codesign_log"
[[ "$(<"$security_log")" == $'find-identity -v -p codesigning\nfind-identity '"$fake_home"'/Library/Keychains/lyte-signing.keychain-db' ]]

: > "$fallback_identities"
reset_logs
expect_failure "identity not found" run_signer "$fixture_root/Lyte.app"
[[ ! -s "$codesign_log" ]]

write_one_apple
write_fallback
for requirement_mode in \
    apple_missing_anchor apple_wrong_cn missing_dr_identifier
do
    reset_logs
    FAKE_REQUIREMENT_MODE="$requirement_mode" \
        expect_failure "unstable code requirement" run_signer \
            "$fixture_root/Lyte.app"
done

: > "$valid_identities"
reset_logs
FAKE_REQUIREMENT_MODE=self_wrong_root \
    expect_failure "unstable code requirement" run_signer \
        "$fixture_root/Lyte.app"

write_one_apple
reset_logs
FAKE_IDENTIFIER_MODE=wrong \
    expect_failure "unstable code requirement" run_signer \
        "$fixture_root/Lyte.app"

reset_logs
FAKE_TEAM_MODE=missing \
    expect_failure "unstable code requirement" run_signer \
        "$fixture_root/Lyte.app"

reset_logs
FAKE_TEAM_MODE=mismatch \
    expect_failure "unstable code requirement" run_signer \
        "$fixture_root/Lyte.app" "$fixture_root/lyte-cli"

reset_logs
FAKE_VERIFY_MODE=fail expect_failure "" run_signer "$fixture_root/Lyte.app"

expect_failure "usage:" "$sign_dev"

echo "sign-dev tests PASSED"
