#!/bin/bash
# Drive Scripts/install.sh the way the one-liner does (`… | bash`) against
# local archives of a stub Lyte.app, with fake codesign, spctl, pgrep, mv, uname,
# sw_vers and lsregister, into a scratch destination: no network, no
# /Applications, no Launch Services, and blind to any Lyte that is running.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
install="$repo_root/Scripts/install.sh"
source "$repo_root/Scripts/lib/assert.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/home" "$fixture/tmp"
dest="$fixture/home/Apps"
log="$fixture/calls.log"

# codesign accepts a bundle only against the exact Developer ID requirement
# naming the team the stub claims (Contents/team).
cat > "$fixture/bin/codesign" <<'EOF'
#!/bin/sh
printf 'codesign %s\n' "$*" >> "$FAKE_LOG"
[ "$1" = --verify ] || exit 90
requirement=""
target=""
for argument in "$@"; do
    case "$argument" in
        -R=*) requirement="${argument#-R=}" ;;
        -*) ;;
        *) target="$argument" ;;
    esac
done
team="$(cat "$target/Contents/team" 2>/dev/null)" || exit 1
[ "$requirement" = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\"" ]
EOF
# spctl accepts a stub whose Contents/source names its assessment source, and
# rejects one without.
cat > "$fixture/bin/spctl" <<'EOF'
#!/bin/sh
eval "target=\${$#}"
if [ -f "$target/Contents/source" ]; then
    echo "$target: accepted"
    echo "source=$(cat "$target/Contents/source")"
    exit 0
fi
echo "$target: rejected"
echo "source=Unnotarized Developer ID"
exit 3
EOF
# mv fails to put a staged copy in place when FAKE_MV_FAIL is set.
cat > "$fixture/bin/mv" <<'EOF'
#!/bin/sh
if [ -n "$FAKE_MV_FAIL" ]; then
    case "$1" in */.Lyte.app.incoming) echo "mv: fake failure" >&2; exit 1 ;; esac
fi
exec /bin/mv "$@"
EOF
# pgrep -x NAME finds NAME when FAKE_RUNNING lists it; FAKE_RUNNING=broken is
# a process table that cannot be read. From its FAKE_LAUNCH_AT-th call on,
# Lyte is running too.
cat > "$fixture/bin/pgrep" <<'EOF'
#!/bin/sh
[ "$FAKE_RUNNING" = broken ] && exit 3
echo x >> "$FAKE_LOG.pgrep"
running="$FAKE_RUNNING"
if [ -n "$FAKE_LAUNCH_AT" ] && [ "$(wc -l < "$FAKE_LOG.pgrep")" -ge "$FAKE_LAUNCH_AT" ]; then
    running="$running Lyte"
fi
for process in $running; do
    if [ "$process" = "$2" ]; then echo 4242; exit 0; fi
done
exit 1
EOF
cat > "$fixture/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 90 ;; esac
EOF
cat > "$fixture/bin/sw_vers" <<'EOF'
#!/bin/sh
echo "$FAKE_MACOS"
EOF
cat > "$fixture/bin/lsregister" <<'EOF'
#!/bin/sh
printf 'lsregister %s\n' "$*" >> "$FAKE_LOG"
EOF
chmod +x "$fixture/bin/"*

# make_zip NAME TEAM SOURCE MARK: an archive of a stub Lyte.app that
# Gatekeeper accepts from SOURCE, or rejects when SOURCE is "none".
make_zip() {
    local app="$fixture/src/$1/Lyte.app"
    mkdir -p "$app/Contents/MacOS"
    printf '%s\n' "$2" > "$app/Contents/team"
    [[ "$3" == none ]] || printf '%s\n' "$3" > "$app/Contents/source"
    printf '%s\n' "$4" > "$app/Contents/mark"
    : > "$app/Contents/only-$4"
    ditto -c -k --keepParent "$app" "$fixture/$1.zip"
}
notarized="Notarized Developer ID"
make_zip v1 SD6N7Z8P9P "$notarized" v1
make_zip v2 SD6N7Z8P9P "$notarized" v2
make_zip foreign ABCDE12345 "$notarized" foreign
make_zip rejected SD6N7Z8P9P none rejected
make_zip unnotarized SD6N7Z8P9P "Developer ID" unnotarized
mkdir -p "$fixture/src/empty/Other.app"
ditto -c -k --keepParent "$fixture/src/empty/Other.app" "$fixture/empty.zip"

# run_install ZIP [VAR=VALUE…]: pipe install.sh into bash; output in $out.
out="$fixture/out"
run_install() {
    local zip="$1"
    shift
    : > "$log"
    rm -f "$log.pgrep"
    env -i HOME="$fixture/home" TMPDIR="$fixture/tmp" PATH="$fixture/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        NO_COLOR=1 FAKE_LOG="$log" FAKE_RUNNING="" FAKE_MACOS=15.0 FAKE_MV_FAIL="" FAKE_LAUNCH_AT="" \
        LYTE_ZIP_URL="file://$fixture/$zip.zip" LYTE_DEST="$dest" \
        LYTE_LSREGISTER="$fixture/bin/lsregister" "$@" \
        bash < "$install" > "$out" 2>&1
}
installed_mark() { cat "$dest/Lyte.app/Contents/mark"; }
no_leftovers() {
    [[ ! -e "$dest/.Lyte.app.incoming" && ! -e "$dest/.Lyte.app.outgoing" ]] \
        || fail "a staged or set-aside copy was left in $dest"
}
# refused ZIP PATTERN [VAR=VALUE…]: install fails, says PATTERN, and v2 stays.
refused() {
    local zip="$1" pattern="$2"
    shift 2
    refute run_install "$zip" "$@"
    grep -q "$pattern" "$out" || fail "$zip: expected \"$pattern\", got: $(cat "$out")"
    grep -q "nothing was changed" "$out" || fail "$zip: refusal does not say nothing changed"
    [[ "$(installed_mark)" == v2 ]] || fail "$zip: the installed copy changed"
    [[ -e "$dest/Lyte.app/Contents/only-v2" ]] || fail "$zip: the installed copy was altered"
    no_leftovers
}

# A signed, notarized release installs, and Launch Services hears of it.
run_install v1 || fail "fresh install failed: $(cat "$out")"
[[ "$(installed_mark)" == v1 ]] || fail "fresh install did not land v1"
grep -q "Lyte was installed to ~/Apps/Lyte.app" "$out" || fail "no success line: $(cat "$out")"
grep -qx "lsregister -f $dest/Lyte.app" "$log" || fail "Launch Services was not told"
no_leftovers

# An installed copy is replaced whole, never merged.
run_install v2 || fail "replacing install failed: $(cat "$out")"
[[ "$(installed_mark)" == v2 ]] || fail "v2 did not replace v1"
[[ ! -e "$dest/Lyte.app/Contents/only-v1" ]] || fail "v1's files survived the replace"
no_leftovers

# Another team's signature, or no notarization, changes nothing.
refused foreign "not signed with Lyte's Developer ID"
refused rejected "does not accept the downloaded Lyte.app as notarized"
refused unnotarized "does not accept the downloaded Lyte.app as notarized"
refused empty "holds no Lyte.app"

# Never while Lyte, its helper, or an unreadable process table says otherwise.
refused v1 "Lyte is running; quit it" FAKE_RUNNING=Lyte
grep -q "osascript -e 'quit app \"Lyte\"'" "$out" || fail "no way to quit Lyte was printed"
# Lyte opened while the download ran (after the first check's two lookups).
refused v1 "Lyte is running; quit it" FAKE_LAUNCH_AT=3
refused v1 "helper is still running" FAKE_RUNNING=lyte-helperd
refused v1 "cannot tell whether Lyte is running" FAKE_RUNNING=broken
refute run_install v1 FAKE_MACOS=14.7
grep -q "needs macOS 15 or later" "$out" || fail "an old macOS was not refused: $(cat "$out")"
[[ "$(installed_mark)" == v2 ]] || fail "an old macOS changed the installed copy"

# A rename that fails puts back the copy that was installed.
refute run_install v1 FAKE_MV_FAIL=1
grep -q "the installed copy is untouched" "$out" || fail "a failed rename was not reported: $(cat "$out")"
[[ "$(installed_mark)" == v2 ]] || fail "a failed rename lost the installed copy"
no_leftovers

# A swap that died between its renames left the only copy aside: it returns,
# is put back again when this swap fails too, and is replaced when it succeeds.
/bin/mv "$dest/Lyte.app" "$dest/.Lyte.app.outgoing"
refute run_install v1 FAKE_MV_FAIL=1
[[ "$(installed_mark)" == v2 ]] || fail "the set-aside copy was not restored"
no_leftovers
/bin/mv "$dest/Lyte.app" "$dest/.Lyte.app.outgoing"
run_install v1 || fail "install after an interrupted swap failed: $(cat "$out")"
[[ "$(installed_mark)" == v1 ]] || fail "v1 did not install after an interrupted swap"
[[ ! -e "$dest/Lyte.app/Contents/only-v2" ]] || fail "the set-aside copy was merged in"
no_leftovers

echo "install.sh tests PASSED"
