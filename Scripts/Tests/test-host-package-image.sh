#!/usr/bin/env bash
# Verify the exact rootless Linux host image contract. With --self-test, build
# an image from isolated fake binary/dependency inputs so macOS CI exercises
# the staging mechanism without requiring a Linux executable.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
stage_script="$repo_root/Host/Scripts/stage-host-image.sh"
verify_script="$repo_root/Host/Scripts/verify-host-image.sh"

verify_image() {
    "$verify_script" "$1"
}

self_test() {
    local scratch fake_binary crypto_root asn1_root image
    scratch="$(mktemp -d -t lyte-host-image-test.XXXXXX)"
    self_test_scratch="$scratch"
    cleanup_self_test() { find "$self_test_scratch" -xdev -depth -delete; }
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

    # Each mutation of a copy of the good image must fail verification.
    local case_image mutation
    for mutation in \
        'chmod 0700 bin/lyte-host' \
        'chmod 0664 etc/host.conf' \
        'chmod 0600 doc/LICENSE' \
        'tail -n 1 doc/MANIFEST.sha256 >> doc/MANIFEST.sha256' \
        'sed "s| \./etc/host\.conf$| etc/host.conf|" doc/MANIFEST.sha256 > m && mv m doc/MANIFEST.sha256 && chmod 0644 doc/MANIFEST.sha256' \
        'printf "extra\n" > etc/extra.conf' \
        'rm doc/THIRD-PARTY.md' \
        'printf "corruption\n" >> etc/host.conf' \
        'grep -v " \./bin/lyte-host$" doc/MANIFEST.sha256 > m && tail -n 1 m > t && cat t >> m && rm t && mv m doc/MANIFEST.sha256 && chmod 0644 doc/MANIFEST.sha256 && printf "#!/bin/sh\nexit 1\n" > bin/lyte-host' \
        'grep -v " \./bin/lyte-host$" doc/MANIFEST.sha256 > m && mv m doc/MANIFEST.sha256 && chmod 0644 doc/MANIFEST.sha256'
    do
        case_image="$scratch/case"
        cp -Rp "$image" "$case_image"
        (cd "$case_image" && eval "$mutation") \
            || { echo "host package image FAILED: cannot apply: $mutation" >&2; return 1; }
        if verify_image "$case_image" >/dev/null 2>&1; then
            echo "host package image FAILED: accepted an image after: $mutation" >&2
            return 1
        fi
        find "$case_image" -xdev -depth -delete
    done
    cleanup_self_test
    trap - EXIT
    echo "host package image self-test PASSED"
}

case "${1:-}" in
    --self-test) self_test ;;
    '') echo "usage: Scripts/Tests/test-host-package-image.sh IMAGE|--self-test" >&2; exit 64 ;;
    *) verify_image "$1" ;;
esac
