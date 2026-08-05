#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${1:-$repo_root/.build/Lyte.app}"
plist="$app/Contents/Info.plist"
make_app="$repo_root/Scripts/make-app.sh"
sign_dev="$repo_root/Scripts/sign-dev.sh"

[[ -x "$app/Contents/MacOS/Lyte" ]]
[[ -x "$app/Contents/MacOS/lyte-helperd" ]]
plutil -lint "$plist" >/dev/null

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
[[ "$bundle_version" == "$(git -C "$repo_root" rev-list --count HEAD)" ]]
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
[[ -x "$sign_dev" ]]

leftovers="$(
    find "$repo_root/.build" -mindepth 1 -maxdepth 1 -type d \
        -name '.lyte-app-stage.*' -print
)"
[[ -z "$leftovers" ]] || {
    echo "make-app left staging directories behind:" >&2
    printf '%s\n' "$leftovers" >&2
    exit 1
}

echo "app packaging tests PASSED"
