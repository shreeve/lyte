#!/bin/bash
# Drive Scripts/setup-dev-signing.sh against fake `security` and `openssl`
# under a private HOME: no real keychain or certificate is touched.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
setup="$repo_root/Scripts/setup-dev-signing.sh"
source "$repo_root/Scripts/lib/assert.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"

cat > "$fixture/bin/openssl" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_OPENSSL_FAIL:-}" ]; then
    echo "openssl: fake $1 failure" >&2
    exit 1
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        -keyout|-out) : > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
EOF
cat > "$fixture/bin/security" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_SECURITY_LOG"
case "$1" in
    create-keychain)
        eval "keychain=\${$#}"
        mkdir -p "$(dirname "$keychain")"
        : > "$keychain"
        ;;
    list-keychains)
        if [ "${4:-}" = -s ]; then
            shift 4
            printf '%s\n' "$@" > "$FAKE_SEARCH_LIST"
        else
            echo '    "/Users/fake/Library/Keychains/login.keychain-db"'
            echo '    "/Users/fake/Library/Keychains/with space.keychain-db"'
        fi
        ;;
    import) : > "$FAKE_IMPORTED" ;;
    find-identity)
        if [ -e "$FAKE_IMPORTED" ]; then
            echo '  1) DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD "Lyte Dev"'
        fi
        ;;
    set-key-partition-list)
        if [ -n "${FAKE_PARTITION_FAIL:-}" ]; then
            echo "security: fake partition failure" >&2
            exit 1
        fi
        ;;
esac
EOF
chmod +x "$fixture/bin/openssl" "$fixture/bin/security"

# run_setup NAME [VAR=VALUE...]: one run in a fresh HOME named NAME.
run_setup() {
    local name="$1"
    shift
    mkdir -p "$fixture/$name/home"
    env "$@" \
        HOME="$fixture/$name/home" \
        PATH="$fixture/bin:$PATH" \
        FAKE_SECURITY_LOG="$fixture/$name/security.log" \
        FAKE_SEARCH_LIST="$fixture/$name/search-list" \
        FAKE_IMPORTED="$fixture/$name/imported" \
        "$setup" >"$fixture/$name/stdout" 2>"$fixture/$name/stderr"
}

# A fresh setup appends the signing keychain to the search list, keeping
# every existing path whole.
run_setup fresh || fail "setup failed: $(<"$fixture/fresh/stderr")"
expected_list="/Users/fake/Library/Keychains/login.keychain-db
/Users/fake/Library/Keychains/with space.keychain-db
$fixture/fresh/home/Library/Keychains/lyte-signing.keychain-db"
[[ "$(<"$fixture/fresh/search-list")" == "$expected_list" ]] \
    || fail "search list became: $(<"$fixture/fresh/search-list")"
grep -Fq "'Lyte Dev' ready (DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD)." \
    "$fixture/fresh/stdout"

# A certificate that cannot be made stops the setup and says why.
if run_setup broken FAKE_OPENSSL_FAIL=1; then
    fail "setup survived a failed certificate request"
fi
grep -Fq 'openssl: fake req failure' "$fixture/broken/stderr"
[[ ! -e "$fixture/broken/security.log" ]] \
    || fail "setup reached the keychain without a certificate"

# A partition-list failure still finishes, but warns that codesign will prompt.
run_setup prompt FAKE_PARTITION_FAIL=1 \
    || fail "setup failed on a partition-list failure"
grep -Fq 'security: fake partition failure' "$fixture/prompt/stderr"
grep -Fq 'codesign may prompt' "$fixture/prompt/stderr"

echo "setup-dev-signing tests PASSED"
