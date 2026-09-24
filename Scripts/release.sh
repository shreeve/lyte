#!/bin/bash
#
# release.sh — build Lyte <version>, notarize it, sign its update feed, and
# publish it as a GitHub release (docs/RELEASING.md).
#
#   Scripts/release.sh 0.6.0 --notes     # print the notes it would publish; nothing else
#   Scripts/release.sh 0.6.0 --dry-run   # build, notarize and sign under .build/release-0.6.0; publish nothing
#   Scripts/release.sh 0.6.0             # also tag v0.6.0, push the tag, and publish
#
# The release carries Lyte-<version>.zip (the Homebrew cask and the feed both
# download it) and appcast.xml, the Sparkle feed installed copies read from
# the latest release (SUFeedURL). The app is signed with the Developer ID and
# notarized, with the ticket stapled, so Gatekeeper accepts it however it was
# downloaded. The feed is signed with the EdDSA key the login keychain holds
# under the account "lyte", the private half of
# Client/Updates/sparkle-public-key.txt.
#
# The notes are the version's section of CHANGELOG.md, which a release must
# have: the GitHub release shows them, and the feed embeds them for Sparkle's
# update window.
#
# A real release runs from a clean main in step with origin/main and changes
# nothing in the tree: make-app.sh stamps the version into the bundle. Until
# the tag is pushed a failure deletes the draft release and the local tag;
# only publishing the pushed draft can fail beyond that, and the script prints
# the command that finishes it. --dry-run skips every release-only check and
# still submits the app to Apple, which makes nothing public; without the
# update key it stops before the feed and says so.
#
# LYTE_RELEASE_IDENTITY names another Developer ID, NOTARY_PROFILE another
# notarytool keychain profile.

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source "$root/Scripts/lib/assert.sh"

warn() { echo "warning: $*" >&2; }

version="${1:?usage: Scripts/release.sh <version> [--dry-run | --notes]}"
mode="${2:-publish}"
case "$mode" in publish | --dry-run | --notes) ;; *) fail "unknown option $mode" ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, not $version"
repo="shreeve/lyte"
tag="v$version"
identity="${LYTE_RELEASE_IDENTITY:-Developer ID Application: Steve Shreeve (SD6N7Z8P9P)}"
profile="${NOTARY_PROFILE:-notary-tool}"
key_file="Client/Updates/sparkle-public-key.txt"
key_account=lyte

# The version's section of CHANGELOG.md, from under its "## <version>"
# heading to the next one.
section=""
if [[ -f CHANGELOG.md ]]; then
    section=$(awk -v v="$version" '
        /^## / { if (on) exit; on = ($2 == v); next }
        on { line[++n] = $0 }
        END {
            first = 1
            while (first <= n && line[first] == "") first++
            while (n >= first && line[n] == "") n--
            for (i = first; i <= n; i++) print line[i]
        }' CHANGELOG.md)
fi
notes="$section

Install with Homebrew:

    brew install --cask shreeve/tap/lyte

Installed copies update themselves through Lyte → Check for Updates…"

if [[ "$mode" == --notes ]]; then
    [[ -n "$section" ]] || fail "CHANGELOG.md has no section for $version"
    printf '%s\n' "$notes"
    exit 0
fi

# Whether version $1 is higher than version $2.
higher() {
    local IFS=. i
    local -a a=($1) b=($2)
    for i in 0 1 2; do
        if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
        if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
    done
    return 1
}

if [[ "$mode" == publish ]]; then
    [[ "$(git branch --show-current)" == main ]] || fail "release from main"
    [[ -z "$(git status --porcelain)" ]] || fail "the working tree is not clean"
    git fetch -q origin main --tags
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
        || fail "main is not in step with origin/main"
    refute git rev-parse -q --verify "refs/tags/$tag"
    refute git ls-remote --exit-code --tags origin "refs/tags/$tag"
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in to GitHub"
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        fail "a release for $tag already exists; if a failed run left a draft, delete it: gh release delete $tag --repo $repo"
    fi
fi

latest=""
for existing in $(git tag -l 'v[0-9]*'); do
    existing="${existing#v}"
    [[ "$existing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z "$latest" ]] || higher "$existing" "$latest"; then latest="$existing"; fi
done
problems=()
if [[ -n "$latest" ]] && ! higher "$version" "$latest"; then
    problems+=("$version is not higher than the latest release, $latest")
fi
[[ -n "$section" ]] || problems+=("CHANGELOG.md has no \"## $version\" section for the release notes")
[[ -s "$key_file" ]] || problems+=("$key_file is missing; create the update key (docs/RELEASING.md)")
for problem in ${problems[@]+"${problems[@]}"}; do
    if [[ "$mode" == publish ]]; then fail "$problem"; else warn "$problem"; fi
done

identities="$(security find-identity -v -p codesigning)"
grep -qF "\"$identity\"" <<< "$identities" \
    || fail "the keychain has no signing identity \"$identity\""
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "notarytool cannot sign in with keychain profile \"$profile\"; see docs/RELEASING.md"

bin=".build/artifacts/sparkle/Sparkle/bin"
have_key=0
if [[ -s "$key_file" ]]; then
    swift package --package-path Client --scratch-path .build resolve >/dev/null
    [[ -x "$bin/generate_keys" ]] || fail "Sparkle's tools are missing under $bin"
    if keychain_key="$("$bin/generate_keys" --account "$key_account" -p 2>/dev/null)"; then
        [[ "$(tr -d '[:space:]' <<< "$keychain_key")" == "$(tr -d '[:space:]' < "$key_file")" ]] \
            || fail "the keychain's \"$key_account\" update key does not match $key_file"
        have_key=1
    elif [[ "$mode" == publish ]]; then
        fail "the login keychain has no Sparkle key under the account \"$key_account\""
    else
        warn "the login keychain has no Sparkle key under \"$key_account\"; the dry run stops before the feed"
    fi
fi

out=".build/release-$version"
rm -rf "$out"
mkdir -p "$out/feed"

# A dry run without a committed key still proves the bundle, signing and
# notarization; make-app.sh refuses a release version without the key, so
# such a bundle is built as a development version.
if [[ -s "$key_file" ]]; then
    LYTE_RELEASE_VERSION="$version" LYTE_SIGNING_IDENTITY="$identity" \
        LYTE_APP_DESTINATION="$out/Lyte.app" Scripts/make-app.sh release
else
    LYTE_SIGNING_IDENTITY="$identity" \
        LYTE_APP_DESTINATION="$out/Lyte.app" Scripts/make-app.sh release
fi
app="$out/Lyte.app"
if [[ -s "$key_file" ]]; then
    [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" == "$version" ]] \
        || fail "the bundle does not say $version"
    plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist" >/dev/null 2>&1 \
        || fail "the bundle has no SUPublicEDKey, so it could never update"
fi

# Apple scans the app and issues a ticket; stapling puts it in the bundle so
# Gatekeeper can check it offline. The submitted zip is only for Apple; the
# release zip is made from the stapled app.
echo "Notarizing (usually a few minutes)…"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
result=$(xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" \
    --wait --output-format json || true)
rm "$out/notarize.zip"
status=$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null || true)
if [[ "$status" != Accepted ]]; then
    id=$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null || true)
    [[ -z "$id" ]] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    fail "notarization came back ${status:-without a status}"
fi
xcrun stapler staple -q "$app"
assessment=$(spctl --assess --type execute -vv "$app" 2>&1) \
    || fail "Gatekeeper refuses the stapled app: $assessment"
grep -qx "source=Notarized Developer ID" <<< "$assessment" \
    || fail "Gatekeeper does not see a notarized Developer ID app: $assessment"

archive="Lyte-$version.zip"
ditto -c -k --keepParent "$app" "$out/feed/$archive"
[[ -z "$section" ]] || printf '%s\n' "$section" > "$out/feed/Lyte-$version.md"
printf '%s\n' "$notes" > "$out/notes.md"

if (( ! have_key )); then
    [[ "$mode" == --dry-run ]] || fail "no update key"
    echo "Dry run (no feed: no update key yet): $out"
    ls -la "$out" "$out/feed"
    exit 0
fi

"$bin/generate_appcast" --account "$key_account" \
    --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
    --embed-release-notes --link "https://github.com/$repo" "$out/feed" >/dev/null
# generate_appcast writes an unsigned feed when its key does not match the
# bundle's SUPublicEDKey, and Sparkle rejects an unsigned enclosure.
unsigned=$(grep -o '<enclosure[^>]*>' "$out/feed/appcast.xml" | grep -v 'sparkle:edSignature=' || true)
[[ -z "$unsigned" ]] || fail "the feed is unsigned; the keychain key does not match SUPublicEDKey"
if [[ -n "$section" ]]; then
    grep -q '<description' "$out/feed/appcast.xml" || fail "the feed carries no release notes"
fi
cp "$out/feed/appcast.xml" "$out/appcast.xml"

if [[ "$mode" == --dry-run ]]; then
    echo "Dry run: $out"
    ls -la "$out" "$out/feed"
    exit 0
fi

# A draft is invisible until published, so it can be deleted if anything
# below fails. The tag reaches GitHub with the push; publishing uses it.
stage=drafted
undo() {
    local status=$?
    case "$stage" in
        drafted)
            gh release delete "$tag" --repo "$repo" --yes >/dev/null 2>&1 \
                || echo "error: if a draft release $tag exists, delete it: gh release delete $tag --repo $repo" >&2
            git tag -d "$tag" >/dev/null 2>&1 || true
            ;;
        pushed)
            echo "error: $tag is pushed, but its release is still a draft; publish it with:" >&2
            echo "  gh release edit $tag --repo $repo --draft=false --latest --verify-tag" >&2
            ;;
    esac
    exit "$status"
}
trap undo EXIT
trap 'exit 130' INT TERM HUP

gh release create "$tag" "$out/feed/$archive" "$out/appcast.xml" \
    --repo "$repo" --title "Lyte $version" --notes-file "$out/notes.md" --draft >/dev/null
git tag -a "$tag" -m "Lyte $version"
git push -q origin "$tag"
stage=pushed
gh release edit "$tag" --repo "$repo" --draft=false --latest --verify-tag >/dev/null
stage=published
echo "Published $tag"
echo "Next: update Casks/lyte.rb in shreeve/homebrew-tap to $version (sha256 of $out/feed/$archive)."
