#!/bin/bash
# Forbidden-token scan: no shell script states a check as a bare `[[ … ]]`,
# `(( … ))` or `! cmd` statement. macOS /bin/bash 3.2 ignores `set -e` when
# the first two fail, and no bash exits when `! cmd` fails, so such a line
# never fails anything. Guard it (`[[ … ]] || fail "…"`, Scripts/lib/assert.sh)
# or make it the condition of an if/while. Every script must also parse.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/Scripts/lib/assert.sh"

# Prints file:line: statement for each bare check. Backslash-continued lines
# and a `[[` left open across lines are joined into one statement first.
bare_checks() {
    awk '
        function report() {
            s = statement
            sub(/^[[:space:]]+/, "", s)
            sub(/^(then|do|else)[[:space:]]+/, "", s)
            if (s ~ /^\[\[/) {
                rest = substr(s, index(s, "]]") + 2)
            } else if (s ~ /^\(\(/) {
                rest = substr(s, index(s, "))") + 2)
            } else if (s ~ /^![[:space:]]/) {
                rest = (s ~ /\|\|/) ? "||" : ""
            } else {
                return
            }
            if (rest !~ /^[[:space:]]*(\|\||&&|\|)/) {
                printf "%s:%d: %s\n", FILENAME, first, s
            }
        }
        FNR == 1 { statement = "" }
        {
            if (statement == "") {
                if ($0 ~ /^[[:space:]]*#/) next
                first = FNR
            }
            line = $0
            continued = sub(/\\$/, "", line)
            statement = statement " " line
            if (continued) next
            opened = gsub(/\[\[/, "&", statement)
            closed = gsub(/\]\]/, "&", statement)
            if (opened > closed) next
            report()
            statement = ""
        }
    ' "$@"
}

# The scanner itself: each bare form is caught, each guarded form is not.
# Fixture lines carry a leading | so this file does not trip its own scan.
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
sed 's/^|//' > "$fixture/bare.sh" <<'EOF'
|[[ -f a ]]
|    [[ "$(cat a)" == b ]]
|[[ -n "$a" \
|    && -n "$b" ]]
|[[ -n "$a" &&
|    -n "$b" ]]
|(( count == 2 ))
|! grep -q a b
|then [[ -d x ]]
|[[ -f a ]]; echo next
EOF
sed 's/^|//' > "$fixture/guarded.sh" <<'EOF'
|# [[ -f a ]] in a comment
|[[ -f a ]] || fail "missing a"
|[[ -n "$a" \
|    && -n "$b" ]] \
|    || fail "empty"
|[[ -z "$x" ]] && continue
|(( count == 2 )) || exit 1
|! grep -q a b || fail "found a"
|if [[ -f a ]]; then :; fi
|while ! grep -q a b; do :; done
|refute grep -q a b
EOF
bare_count="$(bare_checks "$fixture/bare.sh" | wc -l | tr -d ' ')"
[[ "$bare_count" -eq 8 ]] || {
    bare_checks "$fixture/bare.sh" >&2
    fail "scanner found $bare_count of 8 bare checks"
}
guarded="$(bare_checks "$fixture/guarded.sh")"
[[ -z "$guarded" ]] || fail "scanner flagged guarded checks: $guarded"

cd "$repo_root"
scripts=()
while IFS= read -r script; do
    scripts+=("$script")
done < <(git ls-files -- '*.sh')
(( ${#scripts[@]} > 0 )) || fail "no shell scripts found"
# Every script parses under the shell its shebang names (`bash -n a b`
# checks only `a`, so one file at a time).
for script in "${scripts[@]}"; do
    case "$(head -n 1 "$script")" in
        *bash*) bash -n "$script" || fail "$script does not parse" ;;
        *) sh -n "$script" || fail "$script does not parse" ;;
    esac
done
found="$(bare_checks "${scripts[@]}")"
if [[ -n "$found" ]]; then
    printf '%s\n' "$found" >&2
    fail "bare checks never fail under set -e; guard them (Scripts/lib/assert.sh)"
fi
echo "shell assertion lint PASSED (${#scripts[@]} scripts)"
