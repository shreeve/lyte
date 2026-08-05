#!/usr/bin/env bash
# Verify the complete Linux host image before any privileged installation.
set -euo pipefail

[[ $# -eq 1 ]] || {
    echo "usage: Host/Scripts/verify-host-image.sh IMAGE" >&2
    exit 64
}

image="$1"
[[ -d "$image" && ! -L "$image" ]] || {
    echo "host image verification FAILED: not a real directory: $image" >&2
    exit 1
}
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
./etc/lyte/lyte-host.conf
./lib/systemd/system/lyte-host.service
./usr/local/bin/lyte-host
./usr/local/share/doc/lyte/LICENSE
./usr/local/share/doc/lyte/MANIFEST.sha256
./usr/local/share/doc/lyte/THIRD-PARTY.md
./usr/local/share/doc/lyte/third-party/Opus-COPYING.txt
./usr/local/share/doc/lyte/third-party/SwiftASN1-LICENSE.txt
./usr/local/share/doc/lyte/third-party/SwiftASN1-NOTICE.txt
./usr/local/share/doc/lyte/third-party/SwiftCrypto-LICENSE.txt
./usr/local/share/doc/lyte/third-party/SwiftCrypto-NOTICE.txt
./usr/local/share/doc/lyte/third-party/nanors-LICENSE.txt
FILES
diff -u "$expected" "$actual"

if find "$image" -type l -print -quit | grep -q .; then
    echo "host image verification FAILED: image contains a symlink" >&2
    exit 1
fi
[[ -x "$image/usr/local/bin/lyte-host" ]]
[[ "$(file_mode "$image/usr/local/bin/lyte-host")" == 755 ]]
while IFS= read -r file; do
    [[ "$(file_mode "$file")" == 644 ]]
done < <(find "$image/etc" "$image/lib" "$image/usr/local/share" -type f)

grep -Fq 'exec /usr/local/bin/lyte-host $LYTE_HOST_ARGS' \
    "$image/lib/systemd/system/lyte-host.service"
grep -Fq 'User=lyte-seat-user-set-by-installer' \
    "$image/lib/systemd/system/lyte-host.service"
grep -Fq 'LYTE_HOST_ARGS=' "$image/etc/lyte/lyte-host.conf"
if grep -En 'LYTE_HOST_BIN|\.build/|/home/CHANGE_ME' \
    "$image/etc/lyte/lyte-host.conf" \
    "$image/lib/systemd/system/lyte-host.service"
then
    echo "host image verification FAILED: development path survived" >&2
    exit 1
fi

manifest="$image/usr/local/share/doc/lyte/MANIFEST.sha256"
while read -r digest path; do
    [[ -n "$digest" && "$path" == ./* && -f "$image/${path#./}" ]]
    actual_digest="$(sha256_file "$image/${path#./}")"
    [[ "$digest" == "$actual_digest" ]] || {
        echo "host image verification FAILED: manifest mismatch: $path" >&2
        exit 1
    }
done < "$manifest"
[[ "$(wc -l < "$manifest" | tr -d ' ')" == 11 ]]

echo "host image verification PASSED"
