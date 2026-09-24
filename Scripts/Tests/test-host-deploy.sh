#!/usr/bin/env bash
# Exercise Host/Scripts/deploy-host.sh under a private HOME: versioned
# deploys, the atomic link flip, idempotence, rollback, pruning, status, and
# its refusals. No sudo and no systemctl — --restart runs a logging fake.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
deploy="$repo_root/Host/Scripts/deploy-host.sh"
source "$repo_root/Scripts/lib/assert.sh"

scratch="$(mktemp -d -t lyte-host-deploy-test.XXXXXX)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'find "$scratch" -xdev -depth -delete' EXIT
export HOME="$scratch/home"
unset XDG_DATA_HOME
mkdir -p "$HOME"
versions="$HOME/.local/share/lyte/versions"
link="$HOME/.local/bin/lyte-host"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# A release directory whose lyte-host prints $1.
release() {
    local dir="$scratch/release-$1"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho %s\n' "$1" > "$dir/lyte-host"
    printf '#!/bin/sh\necho audio-%s\n' "$1" > "$dir/lyte-audio-check"
    chmod 0755 "$dir/lyte-host" "$dir/lyte-audio-check"
    printf '%s\n' "$dir"
}

id_of() { sha256_file "$1/lyte-host" | cut -c1-12; }
active() { basename "$(dirname "$(readlink "$link")")"; }
refuses() {
    if "$@" >/dev/null 2>&1; then
        fail "accepted: $*"
    fi
}

a="$(release alpha)"
b="$(release bravo)"
id_a="$(id_of "$a")"
id_b="$(id_of "$b")"

# First deploy: an immutable version and a link the unit can execute.
"$deploy" "$a" >/dev/null
[[ -L "$link" ]] || fail "no link"
[[ "$(readlink "$link")" == "$versions/$id_a/lyte-host" ]] || fail "wrong target"
[[ "$("$link")" == alpha ]] || fail "link does not run the deployed binary"
cmp "$a/lyte-audio-check" "$versions/$id_a/lyte-audio-check"
[[ "$(sha256_file "$versions/$id_a/lyte-host")" == "$id_a"* ]] \
    || fail "version directory is not named by its digest"
[[ ! -e "$HOME/.local/share/lyte/previous" ]] || fail "first deploy recorded a previous"

# Redeploying the active binary changes nothing.
grep -Fq 'already deployed' <<< "$("$deploy" "$a")" \
    || fail "redeploy was not idempotent"
[[ "$(active)" == "$id_a" ]] || fail "redeploy moved the link"
[[ "$(ls "$versions" | wc -l | tr -d ' ')" == 1 ]] \
    || fail "redeploy added a version"

# A new binary flips the link and remembers the old one.
"$deploy" "$b" >/dev/null
[[ "$(active)" == "$id_b" && "$("$link")" == bravo ]] || fail "flip to bravo"
[[ "$(cat "$HOME/.local/share/lyte/previous")" == "$id_a" ]] \
    || fail "the replaced version is not remembered"

# Rollback toggles between the two, and --restart reaches the service.
fake_systemctl="$scratch/systemctl"
printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$scratch" > "$fake_systemctl"
chmod 0755 "$fake_systemctl"
LYTE_SYSTEMCTL="$fake_systemctl" "$deploy" --rollback --restart >/dev/null
[[ "$(active)" == "$id_a" && "$("$link")" == alpha ]] || fail "rollback"
grep -Fxq 'restart lyte-host' "$scratch/systemctl.log" || fail "no restart"
"$deploy" --rollback >/dev/null
[[ "$(active)" == "$id_b" ]] || fail "second rollback did not undo the first"
[[ "$(wc -l < "$scratch/systemctl.log" | tr -d ' ')" == 1 ]] \
    || fail "restart without --restart"

# Status names the active version and its digest.
status="$("$deploy" --status)"
grep -Fq "active:   $id_b" <<< "$status" || fail "status active"
grep -Fq "previous: $id_a" <<< "$status" || fail "status previous"
grep -Fq "sha256:   $(sha256_file "$b/lyte-host")" <<< "$status" || fail "status sha"

# Pruning keeps the newest N, always including the active and previous.
for n in 1 2 3 4 5; do
    "$deploy" --keep 3 "$(release "extra$n")" >/dev/null
done
[[ "$(ls "$versions" | wc -l | tr -d ' ')" == 3 ]] || fail "prune kept $(ls "$versions")"
[[ -d "$versions/$(active)" ]] || fail "pruning removed the active version"
[[ -d "$versions/$(cat "$HOME/.local/share/lyte/previous")" ]] \
    || fail "pruning removed the previous version"
[[ ! -e "$versions/$id_a" ]] || fail "oldest version survived pruning"

# XDG_DATA_HOME relocates the versions.
XDG_DATA_HOME="$scratch/data" HOME="$scratch/home2" bash -c '
    mkdir -p "$HOME" && "$1" "$2" >/dev/null
    [[ "$(readlink "$HOME/.local/bin/lyte-host")" == "$XDG_DATA_HOME/lyte/versions/"*/lyte-host ]] \
        || exit 1
' _ "$deploy" "$a" || fail "XDG_DATA_HOME ignored"

# Refusals leave the link exactly as it was.
before="$(readlink "$link")"
refuses "$deploy" "$scratch/missing"
refuses "$deploy" --rollback --status
refuses "$deploy" --keep 0 "$a"
tampered="$(active)"
chmod u+w "$versions/$tampered/lyte-host"
printf 'tamper\n' >> "$versions/$tampered/lyte-host"
refuses "$deploy" --status
[[ "$(readlink "$link")" == "$before" ]] || fail "a refusal moved the link"

rm -f "$link"
ln -s "$scratch/elsewhere/lyte-host" "$link"
refuses "$deploy" "$a"
[[ "$(readlink "$link")" == "$scratch/elsewhere/lyte-host" ]] || fail "foreign link replaced"
ln -sfn "$versions/../../escape/lyte-host" "$link"
refuses "$deploy" "$a"
rm -f "$link"
printf 'hand-placed\n' > "$link"
refuses "$deploy" "$a"
[[ "$(cat "$link")" == hand-placed ]] || fail "hand-placed binary replaced"

echo "host deploy tests PASSED"
