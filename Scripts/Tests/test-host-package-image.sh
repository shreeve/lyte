#!/usr/bin/env bash
# Verify the exact rootless Linux host image contract. With --self-test, build
# an image from isolated fake binary/dependency inputs so macOS CI exercises
# the staging mechanism without requiring a Linux executable.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
stage_script="$repo_root/Host/Scripts/stage-host-image.sh"

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

verify_image() {
    local image="$1"
    [[ -d "$image" && ! -L "$image" ]] || {
        echo "host package image FAILED: not a real directory: $image" >&2
        return 1
    }

    local actual expected
    actual="$(mktemp)"
    expected="$(mktemp)"
    trap 'rm -f -- "$actual" "$expected"' RETURN
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
    rm -f -- "$actual" "$expected"
    trap - RETURN

    if find "$image" -type l -print -quit | grep -q .; then
        echo "host package image FAILED: image contains a symlink" >&2
        return 1
    fi
    [[ -x "$image/usr/local/bin/lyte-host" ]]
    [[ "$(file_mode "$image/usr/local/bin/lyte-host")" == 755 ]]
    while IFS= read -r file; do
        [[ "$(file_mode "$file")" == 644 ]]
    done < <(find "$image/etc" "$image/lib" "$image/usr/local/share" -type f)

    rg -Fq 'exec /usr/local/bin/lyte-host $LYTE_HOST_ARGS' \
        "$image/lib/systemd/system/lyte-host.service"
    rg -Fq 'User=lyte-seat-user-set-by-installer' \
        "$image/lib/systemd/system/lyte-host.service"
    rg -Fq 'LYTE_HOST_ARGS=' "$image/etc/lyte/lyte-host.conf"
    if rg -n 'LYTE_HOST_BIN|\.build/|/home/CHANGE_ME' \
        "$image/etc/lyte/lyte-host.conf" \
        "$image/lib/systemd/system/lyte-host.service"
    then
        echo "host package image FAILED: development path survived" >&2
        return 1
    fi

    local manifest="$image/usr/local/share/doc/lyte/MANIFEST.sha256"
    local digest path actual_digest
    while read -r digest path; do
        [[ -n "$digest" && "$path" == ./* && -f "$image/${path#./}" ]]
        actual_digest="$(sha256_file "$image/${path#./}")"
        [[ "$digest" == "$actual_digest" ]] || {
            echo "host package image FAILED: manifest mismatch: $path" >&2
            return 1
        }
    done < "$manifest"
    [[ "$(wc -l < "$manifest" | tr -d ' ')" == 11 ]]

    echo "host package image tests PASSED"
}

self_test() {
    local scratch fake_binary crypto_root asn1_root image
    scratch="$(mktemp -d -t lyte-host-image-test.XXXXXX)"
    cleanup_self_test() { find "$scratch" -xdev -depth -delete; }
    trap cleanup_self_test EXIT

    fake_binary="$scratch/lyte-host"
    printf '#!/bin/sh\nexit 0\n' > "$fake_binary"
    chmod 0755 "$fake_binary"
    crypto_root="$scratch/swift-crypto"
    asn1_root="$scratch/swift-asn1"
    mkdir -p "$crypto_root" "$asn1_root"
    printf 'crypto license fixture\n' > "$crypto_root/LICENSE.txt"
    printf 'crypto notice fixture\n' > "$crypto_root/NOTICE.txt"
    printf 'asn1 license fixture\n' > "$asn1_root/LICENSE.txt"
    printf 'asn1 notice fixture\n' > "$asn1_root/NOTICE.txt"
    image="$scratch/image"

    LYTE_REPOSITORY_ROOT="$repo_root" \
    LYTE_HOST_BINARY="$fake_binary" \
    LYTE_SWIFT_CRYPTO_ROOT="$crypto_root" \
    LYTE_SWIFT_ASN1_ROOT="$asn1_root" \
        "$stage_script" "$image"
    verify_image "$image"

    if LYTE_REPOSITORY_ROOT="$repo_root" \
        LYTE_HOST_BINARY="$fake_binary" \
        LYTE_SWIFT_CRYPTO_ROOT="$crypto_root" \
        LYTE_SWIFT_ASN1_ROOT="$asn1_root" \
            "$stage_script" "$image" >/dev/null 2>&1
    then
        echo "host package image FAILED: existing destination was accepted" >&2
        return 1
    fi

    printf 'corruption\n' >> "$image/etc/lyte/lyte-host.conf"
    if verify_image "$image" >/dev/null 2>&1; then
        echo "host package image FAILED: manifest corruption was accepted" >&2
        return 1
    fi
    cleanup_self_test
    trap - EXIT
    echo "host package image self-test PASSED"
}

case "${1:-}" in
    --self-test) self_test ;;
    '') echo "usage: Scripts/Tests/test-host-package-image.sh IMAGE|--self-test" >&2; exit 64 ;;
    *) verify_image "$1" ;;
esac
