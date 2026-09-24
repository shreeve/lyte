#!/bin/bash
# Forbidden-token scan: no shell script states a check as a bare `[[ … ]]`,
# `(( … ))` or `! cmd` command. macOS /bin/bash 3.2 ignores `set -e` when
# the first two fail, and no bash exits when `! cmd` fails, so such a check
# never fails anything, alone or as any part of an `&&` list
# (`cmd && [[ … ]]`, `[[ a ]] && [[ b ]]`). A check is guarded when an `||`
# follows it in its list (`[[ … ]] || fail "…"`, Scripts/lib/assert.sh) or
# the list ends in continue, break, return, exit or fail
# (`[[ -z "$x" ]] && continue`), or when it is the condition of an
# if/elif/while/until. Every script must also parse.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/Scripts/lib/assert.sh"

# Prints file:line: statement for each bare check. Backslash-continued lines
# and a `[[` left open across lines are joined into one statement first,
# then split at top-level `;`, `&&` and `||` (quotes, `[[ … ]]` and
# parentheses are opaque; a pipeline stays one command).
bare_checks() {
    awk '
        function is_check(command) {
            return command ~ /^(\[\[|\(\(|![[:space:]])/
        }
        # check_list FROM TO: the commands el[FROM..TO] joined by op[].
        function check_list(from, to,    i, j, guarded, text) {
            sub(/^(then|do|else)[[:space:]]+/, "", el[from])
            if (el[from] ~ /^(if|elif|while|until)([[:space:]]|$)/) return
            for (i = from; i <= to; i++) {
                if (!is_check(el[i])) continue
                guarded = (to > i \
                    && el[to] ~ /^(continue|break|return|exit|fail)([[:space:]]|$)/)
                for (j = i; j < to && !guarded; j++) {
                    if (op[j] == "||") guarded = 1
                }
                if (!guarded) {
                    text = el[from]
                    for (j = from; j < to; j++) text = text " " op[j] " " el[j + 1]
                    printf "%s:%d: %s\n", FILENAME, first, text
                    return
                }
            }
        }
        function trim(text) {
            sub(/^[[:space:]]+/, "", text)
            sub(/[[:space:]]+$/, "", text)
            return text
        }
        function report(    s, n, i, c, pair, quote, depth, tests, current, from) {
            s = statement
            n = 0
            current = ""
            quote = ""
            depth = 0
            tests = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                pair = substr(s, i, 2)
                if (quote == "\047") {
                    if (c == "\047") quote = ""
                    current = current c
                    continue
                }
                if (c == "\\") {
                    current = current pair
                    i++
                    continue
                }
                if (quote == "\"") {
                    if (c == "\"") quote = ""
                    current = current c
                    continue
                }
                if (c == "\047" || c == "\"") {
                    quote = c
                } else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) {
                    break
                } else if (pair == "[[") {
                    tests++
                    current = current pair
                    i++
                    continue
                } else if (pair == "]]" && tests > 0) {
                    tests--
                    current = current pair
                    i++
                    continue
                } else if (c == "(") {
                    depth++
                } else if (c == ")" && depth > 0) {
                    depth--
                } else if (depth == 0 && tests == 0 \
                    && (pair == "&&" || pair == "||" || c == ";")) {
                    el[++n] = trim(current)
                    op[n] = (c == ";") ? ";" : pair
                    current = ""
                    if (c != ";") i++
                    continue
                }
                current = current c
            }
            el[++n] = trim(current)
            op[n] = ";"
            from = 1
            for (i = 1; i <= n; i++) {
                if (op[i] == ";") {
                    check_list(from, i)
                    from = i + 1
                }
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
# Fixture lines are commented out with a leading # (stripped when they are
# written) so this file does not trip its own scan.
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
sed 's/^#//' > "$fixture/bare.sh" <<'EOF'
#[[ -f a ]]
#    [[ "$(cat a)" == b ]]
#[[ -n "$a" \
#    && -n "$b" ]]
#[[ -n "$a" &&
#    -n "$b" ]]
#(( count == 2 ))
#! grep -q a b
#then [[ -d x ]]
#[[ -f a ]]; echo next
#[[ -f a ]] && [[ -f b ]]
#true && [[ 1 == 2 ]]
#cd x && (( count > 1 ))
#make || [[ -f a ]]
#[[ -f a ]] && echo found
#[[ -f a ]] || fail "a"; [[ -f b ]]
#echo "x; y" && ! grep -q a b
EOF
sed 's/^#//' > "$fixture/guarded.sh" <<'EOF'
## [[ -f a ]] in a comment
#[[ -f a ]] || fail "missing a"
#[[ -n "$a" \
#    && -n "$b" ]] \
#    || fail "empty"
#[[ -z "$x" ]] && continue
#(( count == 2 )) || exit 1
#! grep -q a b || fail "found a"
#if [[ -f a ]]; then :; fi
#while ! grep -q a b; do :; done
#refute grep -q a b
#[[ -f a ]] && [[ -f b ]] || fail "a or b"
#cd x && [[ -f a ]] || exit 1
#[[ -n "$x" ]] && (( y > 1 )) && return 0
#[[ -f a ]] && break
#x="$(true && [[ -f a ]] && echo y)" || fail "x"
#echo "[[ -f a ]]; && [[ b ]]"
#if [[ -f a ]] && [[ -f b ]]; then [[ -f c ]] || fail "c"; fi
#until (( n > 3 )); do n=$((n + 1)); done
#[[ "$a" == "]]" ]] || fail "brackets"
#case "$a" in x) echo x ;; esac
EOF
bare_count="$(bare_checks "$fixture/bare.sh" | wc -l | tr -d ' ')"
[[ "$bare_count" -eq 15 ]] || {
    bare_checks "$fixture/bare.sh" >&2
    fail "scanner found $bare_count of 15 bare checks"
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
