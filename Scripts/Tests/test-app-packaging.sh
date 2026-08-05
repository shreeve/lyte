#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${1:-$repo_root/.build/Lyte.app}"
active_stage="${2:-}"
plist="$app/Contents/Info.plist"
make_app="$repo_root/Scripts/make-app.sh"
sign_dev="$repo_root/Scripts/sign-dev.sh"

[[ -x "$app/Contents/MacOS/Lyte" ]]
[[ -x "$app/Contents/MacOS/lyte-helperd" ]]
plutil -lint "$plist" >/dev/null

assert_hash() {
    local resource="$1"
    local expected="$2"
    [[ -f "$app/Contents/Resources/$resource" ]]
    [[ "$(shasum -a 256 "$app/Contents/Resources/$resource" \
        | awk '{print $1}')" == "$expected" ]]
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

[[ "$bundle_version" =~ ^[0-9]+$ ]]
[[ "$bundle_version" -ge "$(git -C "$repo_root" rev-list --count HEAD)" ]]
[[ "$short_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
expected_revision="$(git -C "$repo_root" rev-parse --short=12 HEAD)"
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
    || expected_revision="${expected_revision}+"
[[ "$source_revision" == "$expected_revision" ]]
[[ -n "$local_network_usage" ]]
[[ "$bonjour_service" == _lyte._udp ]]

codesign --verify --strict "$app/Contents/MacOS/lyte-helperd"
codesign --verify --strict "$app"
[[ "$(codesign -d --verbose=4 "$app" 2>&1 \
    | awk -F= '/^Identifier=/{print $2; exit}')" == dev.shreeve.lyte ]]

app_signature="$(codesign -dvvv "$app" 2>&1)"
helper_signature="$(codesign -dvvv "$app/Contents/MacOS/lyte-helperd" 2>&1)"
authority="$(printf '%s\n' "$app_signature" \
    | awk -F= '/^Authority=/{print $2; exit}')"
helper_authority="$(printf '%s\n' "$helper_signature" \
    | awk -F= '/^Authority=/{print $2; exit}')"
requirement="$(codesign -d -r- "$app" 2>&1)"
helper_requirement="$(codesign -d -r- \
    "$app/Contents/MacOS/lyte-helperd" 2>&1)"
[[ "$helper_authority" == "$authority" ]]
case "$authority" in
    "Apple Development: "*)
        team_identifier="$(printf '%s\n' "$app_signature" \
            | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
        helper_team_identifier="$(printf '%s\n' "$helper_signature" \
            | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
        [[ "$team_identifier" =~ ^[A-Z0-9]{10}$ ]]
        [[ "$helper_team_identifier" == "$team_identifier" ]]
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
        echo "unexpected app signing authority: $authority" >&2
        exit 1
        ;;
esac

# TN3179 requires a Mach-O UUID so Local Network privacy can track a macOS
# program reliably. Both responsible executables must carry one.
dwarfdump --uuid "$app/Contents/MacOS/Lyte" | grep -Eq '^UUID: [0-9A-F-]{36} '
dwarfdump --uuid "$app/Contents/MacOS/lyte-helperd" \
    | grep -Eq '^UUID: [0-9A-F-]{36} '

for executable in Lyte lyte-helperd; do
    [[ "$(xcrun vtool -show-build "$app/Contents/MacOS/$executable" \
        | awk '$1 == "minos" { print $2; exit }')" == 15.0 ]]
done

# Positive proof complements the no-dylib closure check: the app really
# contains both pinned C leaves rather than merely ceasing to use them.
app_symbols="$(nm -gU "$app/Contents/MacOS/Lyte")"
grep -Eq ' _opus_decode_float$' <<< "$app_symbols"
grep -Eq ' _reed_solomon_decode$' <<< "$app_symbols"

if grep -Fq 'rm -rf "$APP"' "$make_app"; then
    echo "make-app regained destructive in-place assembly" >&2
    exit 1
fi
grep -Fq 'renamex_np' "$make_app"
grep -Fq 'RENAME_SWAP' "$make_app"
grep -Fq 'STAGED_APP' "$make_app"
grep -Fq '<key>LyteSourceRevision</key>' "$make_app"
grep -Fq '<string>0.5.0</string>' "$make_app"
grep -Fq -- '--is-shallow-repository' "$make_app"
grep -Fq 'Scripts/next-bundle-version.sh' "$make_app"
grep -Fq '. "$ROOT/Scripts/AppArtifact/app-artifact.sh"' "$make_app"
grep -Fq 'lyte_require_app_quiescent "live app publication"' "$make_app"
[[ -x "$sign_dev" ]]

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
