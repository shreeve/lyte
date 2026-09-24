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
diff -u "$expected" "$actual"

if find "$image" -type l -print -quit | grep -q .; then
    echo "host image verification FAILED: image contains a symlink" >&2
    exit 1
fi
[[ -x "$image/bin/lyte-host" ]]
[[ "$(file_mode "$image/bin/lyte-host")" == 755 ]]
while IFS= read -r file; do
    [[ "$(file_mode "$file")" == 644 ]]
done < <(find "$image/etc" "$image/systemd" "$image/doc" -type f)

unit="$image/systemd/lyte-host.service"
for token in '@USER@' '@UID@' '@HOME@' '@CONFIG_HOME@' '@STATE_HOME@'; do
    grep -Fq "$token" "$unit"
done
grep -Fq 'exec @HOME@/.local/bin/lyte-host $$LYTE_HOST_ARGS' "$unit"
grep -Fq 'EnvironmentFile=@CONFIG_HOME@/lyte/host.conf' "$unit"
grep -Fq 'AmbientCapabilities=CAP_SYS_ADMIN' "$unit"
grep -Fq 'LYTE_HOST_ARGS=' "$image/etc/host.conf"
if grep -En 'LYTE_HOST_BIN|\.build/|/home/CHANGE_ME|/tmp/' \
    "$image/etc/host.conf" "$unit"
then
    echo "host image verification FAILED: development path survived" >&2
    exit 1
fi

manifest="$image/doc/MANIFEST.sha256"
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
