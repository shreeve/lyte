#!/usr/bin/env bash
# Verify the exact rootless Linux host image contract. With --self-test, build
# an image from isolated fake binary/dependency inputs so macOS CI exercises
# the staging mechanism without requiring a Linux executable; --stage DIR
# stages that fixture image at DIR/image for other tests.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
stage_script="$repo_root/Host/Scripts/stage-host-image.sh"
verify_script="$repo_root/Host/Scripts/verify-host-image.sh"

verify_image() {
    "$verify_script" "$1"
}

# stage_fixture DIR: stages DIR/image from fake inputs written under DIR: a
# lyte-host that echoes "fake-host ARGS", and license and notice fixtures.
stage_fixture() {
    local scratch="$1" name
    printf '#!/bin/sh\necho "fake-host $*"\n' > "$scratch/lyte-host"
    chmod 0755 "$scratch/lyte-host"
    for name in crypto asn1; do
        mkdir -p "$scratch/swift-$name"
        printf '%s license fixture\n' "$name" > "$scratch/swift-$name/LICENSE.txt"
        printf '%s notice fixture\n' "$name" > "$scratch/swift-$name/NOTICE.txt"
    done
    LYTE_REPOSITORY_ROOT="$repo_root" \
    LYTE_HOST_BINARY="$scratch/lyte-host" \
    LYTE_SWIFT_CRYPTO_ROOT="$scratch/swift-crypto" \
    LYTE_SWIFT_ASN1_ROOT="$scratch/swift-asn1" \
        "$stage_script" "$scratch/image"
}

self_test() {
    local scratch image
    scratch="$(mktemp -d -t lyte-host-image-test.XXXXXX)"
    self_test_scratch="$scratch"
    cleanup_self_test() { find "$self_test_scratch" -xdev -depth -delete; }
    trap cleanup_self_test EXIT
    image="$scratch/image"

    stage_fixture "$scratch"
    verify_image "$image"

    if stage_fixture "$scratch" >/dev/null 2>&1; then
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
    --stage) stage_fixture "$2" ;;
    '') echo "usage: Scripts/Tests/test-host-package-image.sh IMAGE|--self-test|--stage DIR" >&2; exit 64 ;;
    *) verify_image "$1" ;;
esac
