#!/usr/bin/env bash
# Verify the complete Linux host image before any privileged installation.
# Every check fails through `fail`: bash 3.2 (macOS) does not errexit on a
# failing bare [[ ]].
set -euo pipefail

fail() {
    echo "host image verification FAILED: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || {
    echo "usage: Host/Scripts/verify-host-image.sh IMAGE" >&2
    exit 64
}

image="$1"
[[ -d "$image" && ! -L "$image" ]] || fail "not a real directory: $image"
image="$(cd "$image" && pwd -P)"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

file_mode() {
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

actual="$(mktemp)"
expected="$(mktemp)"
cleanup() { rm -f -- "$actual" "$expected"; }
trap cleanup EXIT
(
    cd "$image"
    find . -type f -print | LC_ALL=C sort
) > "$actual"
cat > "$expected" <<'FILES'
./bin/lyte-host
./doc/LICENSE
./doc/MANIFEST.sha256
./doc/THIRD-PARTY.md
./doc/third-party/Opus-COPYING.txt
./doc/third-party/SwiftASN1-LICENSE.txt
./doc/third-party/SwiftASN1-NOTICE.txt
./doc/third-party/SwiftCrypto-LICENSE.txt
./doc/third-party/SwiftCrypto-NOTICE.txt
./doc/third-party/nanors-LICENSE.txt
./etc/host.conf
./systemd/lyte-host.service
FILES
diff -u "$expected" "$actual" || fail "the image's file list is not the expected one"

if find "$image" -type l -print -quit | grep -q .; then
    fail "image contains a symlink"
fi
[[ -x "$image/bin/lyte-host" ]] || fail "bin/lyte-host is not executable"
[[ "$(file_mode "$image/bin/lyte-host")" == 755 ]] \
    || fail "bin/lyte-host is not mode 755"
while IFS= read -r file; do
    [[ "$(file_mode "$file")" == 644 ]] || fail "not mode 644: $file"
done < <(find "$image/etc" "$image/systemd" "$image/doc" -type f)

unit="$image/systemd/lyte-host.service"
for token in '@USER@' '@UID@' '@HOME@' '@CONFIG_HOME@' '@STATE_HOME@'; do
    grep -Fq "$token" "$unit" || fail "the unit template lacks $token"
done
grep -Fq 'exec @HOME@/.local/bin/lyte-host $$LYTE_HOST_ARGS' "$unit" \
    || fail "the unit does not exec the linked lyte-host"
grep -Fq 'EnvironmentFile=@CONFIG_HOME@/lyte/host.conf' "$unit" \
    || fail "the unit does not read host.conf"
grep -Fq 'AmbientCapabilities=CAP_SYS_ADMIN' "$unit" \
    || fail "the unit grants no CAP_SYS_ADMIN"
grep -Fq 'LYTE_HOST_ARGS=' "$image/etc/host.conf" \
    || fail "etc/host.conf sets no LYTE_HOST_ARGS"
if grep -En 'LYTE_HOST_BIN|\.build/|/home/CHANGE_ME|/tmp/' \
    "$image/etc/host.conf" "$unit"
then
    fail "development path survived"
fi

manifest="$image/doc/MANIFEST.sha256"
while read -r digest path; do
    [[ -n "$digest" && "$path" == ./* && -f "$image/${path#./}" ]] \
        || fail "malformed manifest line: $digest $path"
    actual_digest="$(sha256_file "$image/${path#./}")"
    [[ "$digest" == "$actual_digest" ]] || fail "manifest mismatch: $path"
done < "$manifest"
[[ "$(wc -l < "$manifest" | tr -d ' ')" == 11 ]] \
    || fail "the manifest does not list exactly 11 files"

echo "host image verification PASSED"
