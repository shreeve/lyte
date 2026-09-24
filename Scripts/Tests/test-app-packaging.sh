#!/bin/bash
set -euo pipefail

# usage: test-app-packaging.sh [--plain|--diagnostics] [APP] [ACTIVE_STAGE]
# A plain app (the default) must carry no diagnostic entry points: the gate's
# app and the everyday app never obey the diagnostic environment.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
diagnostic_build=0
case "${1:-}" in
    --plain) shift ;;
    --diagnostics) diagnostic_build=1; shift ;;
esac
app="${1:-$repo_root/.build/Lyte.app}"
active_stage="${2:-}"
plist="$app/Contents/Info.plist"
source "$repo_root/Scripts/lib/assert.sh"

[[ -x "$app/Contents/MacOS/Lyte" ]] || fail "no app executable in $app"
[[ -x "$app/Contents/MacOS/lyte-helperd" ]] || fail "no helper executable in $app"
plutil -lint "$plist" >/dev/null
if entry_points="$(plutil -extract LyteDiagnosticEntryPoints raw \
    -o - "$plist" 2>/dev/null)"; then
    if (( ! diagnostic_build )); then
        fail "a plain app carries LyteDiagnosticEntryPoints ($entry_points)"
    fi
    [[ "$entry_points" == true ]] \
        || fail "LyteDiagnosticEntryPoints is $entry_points; want true"
elif (( diagnostic_build )); then
    fail "a diagnostic app lacks LyteDiagnosticEntryPoints"
fi

assert_hash() {
    local resource="$1"
    local expected="$2"
    [[ -f "$app/Contents/Resources/$resource" ]] || fail "missing $resource"
    [[ "$(shasum -a 256 "$app/Contents/Resources/$resource" \
        | awk '{print $1}')" == "$expected" ]] || fail "$resource changed"
}

assert_hash Opus-COPYING.txt \
    01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551
assert_hash nanors-LICENSE.txt \
    3fdda5f011d8490331950398e86427d67dfae05e048681476c2c6b8c34bdd033
assert_hash SwiftCrypto-LICENSE.txt \
    cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
assert_hash SwiftCrypto-NOTICE.txt \
    b3ddc2ae068e76b3beb71be03c0400f90090f9469aa491bf7b1ac42320af37b8
assert_hash SwiftASN1-LICENSE.txt \
    8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac
assert_hash SwiftASN1-NOTICE.txt \
    11dd3b3b783e6ec26098dd38ebc962986ea109b85447e28e62867b83bd0f8c5b

bundle_version="$(plutil -extract CFBundleVersion raw -o - "$plist")"
short_version="$(
    plutil -extract CFBundleShortVersionString raw -o - "$plist"
)"
source_revision="$(plutil -extract LyteSourceRevision raw -o - "$plist")"
local_network_usage="$(
    plutil -extract NSLocalNetworkUsageDescription raw -o - "$plist"
)"
bonjour_service="$(
    plutil -extract NSBonjourServices.0 raw -o - "$plist"
)"

[[ "$bundle_version" =~ ^[0-9]+$ ]] \
    || fail "CFBundleVersion is not numeric: $bundle_version"
commit_count="$(git -C "$repo_root" rev-list --count HEAD)"
[[ "$bundle_version" -ge "$commit_count" ]] \
    || fail "CFBundleVersion $bundle_version is below the commit count $commit_count"
[[ "$short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "CFBundleShortVersionString is not x.y.z: $short_version"
expected_revision="$(git -C "$repo_root" rev-parse --short=12 HEAD)"
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
    || expected_revision="${expected_revision}+"
[[ "$source_revision" == "$expected_revision" ]] \
    || fail "LyteSourceRevision is $source_revision; want $expected_revision"
[[ -n "$local_network_usage" ]] || fail "no NSLocalNetworkUsageDescription"
[[ "$bonjour_service" == _lyte._udp ]] \
    || fail "NSBonjourServices[0] is $bonjour_service; want _lyte._udp"

codesign --verify --strict "$app/Contents/MacOS/lyte-helperd"
codesign --verify --strict "$app"
# Tool output is captured before it is parsed: under pipefail, a reader
# that stops early (`awk … exit`, `grep -q`) can SIGPIPE the producer and
# fail the pipeline.
app_signature="$(codesign -dvvv "$app" 2>&1)"
helper_signature="$(codesign -dvvv "$app/Contents/MacOS/lyte-helperd" 2>&1)"
identifier="$(awk -F= '/^Identifier=/{print $2; exit}' <<< "$app_signature")"
[[ "$identifier" == dev.shreeve.lyte ]] \
    || fail "app signing identifier is $identifier; want dev.shreeve.lyte"
authority="$(awk -F= '/^Authority=/{print $2; exit}' <<< "$app_signature")"
helper_authority="$(awk -F= '/^Authority=/{print $2; exit}' \
    <<< "$helper_signature")"
requirement="$(codesign -d -r- "$app" 2>&1)"
helper_requirement="$(codesign -d -r- \
    "$app/Contents/MacOS/lyte-helperd" 2>&1)"
[[ "$helper_authority" == "$authority" ]] \
    || fail "helper signed by $helper_authority, app by $authority"
# Hardened runtime on both: the helper trusts whatever satisfies the app's
# designated requirement, so neither process may accept injected code.
hardened_runtime='^CodeDirectory .*flags=0x[[:xdigit:]]+\([^)]*runtime'
grep -Eq "$hardened_runtime" <<< "$app_signature"
grep -Eq "$hardened_runtime" <<< "$helper_signature"
for signed in "$app" "$app/Contents/MacOS/lyte-helperd"; do
    entitlements="$(codesign -d --entitlements - --xml "$signed" 2>/dev/null)"
    if grep -Fq 'get-task-allow' <<< "$entitlements"; then
        fail "$signed permits task-port attach (get-task-allow)"
    fi
done
case "$authority" in
    "Apple Development: "*)
        team_identifier="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' \
            <<< "$app_signature")"
        helper_team_identifier="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' \
            <<< "$helper_signature")"
        [[ "$team_identifier" =~ ^[A-Z0-9]{10}$ ]] \
            || fail "app team identifier is malformed: $team_identifier"
        [[ "$helper_team_identifier" == "$team_identifier" ]] \
            || fail "helper team $helper_team_identifier, app team $team_identifier"
        grep -Fq 'anchor apple generic' <<< "$requirement"
        grep -Fq 'anchor apple generic' <<< "$helper_requirement"
        grep -Fq \
            "certificate leaf[subject.CN] = \"$authority\"" \
            <<< "$requirement"
        grep -Fq \
            "certificate leaf[subject.CN] = \"$authority\"" \
            <<< "$helper_requirement"
        ;;
    "Lyte Dev")
        grep -Fq 'certificate root = H"' <<< "$requirement"
        grep -Fq 'certificate root = H"' <<< "$helper_requirement"
        ;;
    *)
        fail "unexpected app signing authority: $authority"
        ;;
esac

# The helper derives the peer requirement from its own validated designated
# requirement, changing only the code identifier. Prove the packaged app is
# accepted and two foreign peers are rejected: the same-signed helper (wrong
# identifier) and an Apple platform binary (wrong identifier and signer).
client_requirement="$(
    "$app/Contents/MacOS/lyte-helperd" --print-client-requirement
)"
app_designated_requirement="$(
    awk '/^designated => / {sub(/^designated => /, ""); print; exit}' \
        <<< "$requirement"
)"
[[ "$client_requirement" == "$app_designated_requirement" ]] \
    || fail "helper client requirement differs from the app's designated requirement"
codesign --verify --strict -R="$client_requirement" "$app"
if codesign --verify --strict -R="$client_requirement" \
    "$app/Contents/MacOS/lyte-helperd" >/dev/null 2>&1; then
    fail "helper client requirement accepted the wrong bundle identifier"
fi
if codesign --verify --strict -R="$client_requirement" \
    /bin/ls >/dev/null 2>&1; then
    fail "helper client requirement accepted a foreign platform binary"
fi

# TN3179 requires a Mach-O UUID so Local Network privacy can track a macOS
# program reliably. Both responsible executables must carry one.
for executable in Lyte lyte-helperd; do
    uuids="$(dwarfdump --uuid "$app/Contents/MacOS/$executable")"
    grep -Eq '^UUID: [0-9A-F-]{36} ' <<< "$uuids" \
        || fail "$executable carries no Mach-O UUID"
    build="$(xcrun vtool -show-build "$app/Contents/MacOS/$executable")"
    minos="$(awk '$1 == "minos" { print $2; exit }' <<< "$build")"
    [[ "$minos" == 15.0 ]] || fail "$executable minos is $minos; want 15.0"
done

# Positive proof complements the no-dylib closure check: the app really
# contains both pinned C leaves rather than merely ceasing to use them.
app_symbols="$(nm -gU "$app/Contents/MacOS/Lyte")"
grep -Eq ' _opus_decode_float$' <<< "$app_symbols"
grep -Eq ' _reed_solomon_decode$' <<< "$app_symbols"

leftovers="$(
    if [[ -n "$active_stage" ]]; then
        find "$repo_root/.build" -mindepth 1 -maxdepth 1 -type d \
            -name '.lyte-app-stage.*' \
            ! -name "$(basename "$active_stage")" -print
    else
        find "$repo_root/.build" -mindepth 1 -maxdepth 1 -type d \
            -name '.lyte-app-stage.*' -print
    fi
)"
[[ -z "$leftovers" ]] || {
    echo "make-app left staging directories behind:" >&2
    printf '%s\n' "$leftovers" >&2
    exit 1
}

echo "app packaging tests PASSED"
