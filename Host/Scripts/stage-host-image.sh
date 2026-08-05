#!/usr/bin/env bash
# Build a rootless, integrity-manifested Linux host filesystem image from an
# already-built release binary. This script never escalates, installs, starts,
# stops, or contacts a service; install-host.sh will consume this image in the
# next packaging slice.
set -euo pipefail

usage() {
    echo "usage: Host/Scripts/stage-host-image.sh DESTINATION" >&2
    echo "       DESTINATION must not already exist" >&2
    exit 64
}

[[ $# -eq 1 ]] || usage

host_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
repository_root="${LYTE_REPOSITORY_ROOT:-$(cd "$host_root/.." && pwd -P)}"
binary="${LYTE_HOST_BINARY:-$host_root/.build/release/lyte-host}"
crypto_root="${LYTE_SWIFT_CRYPTO_ROOT:-$host_root/.build/checkouts/swift-crypto}"
asn1_root="${LYTE_SWIFT_ASN1_ROOT:-$host_root/.build/checkouts/swift-asn1}"

destination="$1"
case "$destination" in
    /*) ;;
    *) destination="$PWD/$destination" ;;
esac
destination_parent="$(dirname "$destination")"
destination_name="$(basename "$destination")"
[[ -d "$destination_parent" ]] || {
    echo "host image FAILED: destination parent does not exist" >&2
    exit 1
}
destination="$(cd "$destination_parent" && pwd -P)/$destination_name"
[[ "$destination" != / && ! -e "$destination" && ! -L "$destination" ]] || {
    echo "host image FAILED: destination must be a new, non-root path" >&2
    exit 1
}

required_files=(
    "$binary"
    "$repository_root/LICENSE"
    "$repository_root/docs/THIRD-PARTY.md"
    "$repository_root/Common/Sources/COpus/Upstream/opus-1.6.1/COPYING"
    "$repository_root/Wire/Sources/CNanorsWire/LICENSE"
    "$crypto_root/LICENSE.txt"
    "$crypto_root/NOTICE.txt"
    "$asn1_root/LICENSE.txt"
    "$asn1_root/NOTICE.txt"
    "$host_root/Systemd/lyte-host.conf"
    "$host_root/Systemd/lyte-host.service"
)
for file in "${required_files[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] || {
        echo "host image FAILED: required regular file missing: $file" >&2
        exit 1
    }
done
[[ -x "$binary" ]] || {
    echo "host image FAILED: host binary is not executable: $binary" >&2
    exit 1
}

cleanup_failed_image=1
cleanup() {
    local status=$?
    if (( cleanup_failed_image )) && [[ -d "$destination" ]]; then
        find "$destination" -xdev -depth -delete
    fi
    exit "$status"
}
trap cleanup EXIT

binary_dir="$destination/usr/local/bin"
document_dir="$destination/usr/local/share/doc/lyte"
notice_dir="$document_dir/third-party"
config_dir="$destination/etc/lyte"
unit_dir="$destination/lib/systemd/system"
install -d -m 0755 \
    "$binary_dir" "$document_dir" "$notice_dir" "$config_dir" "$unit_dir"

install -m 0755 "$binary" "$binary_dir/lyte-host"
install -m 0644 "$repository_root/LICENSE" "$document_dir/LICENSE"
install -m 0644 \
    "$repository_root/docs/THIRD-PARTY.md" "$document_dir/THIRD-PARTY.md"
install -m 0644 \
    "$repository_root/Common/Sources/COpus/Upstream/opus-1.6.1/COPYING" \
    "$notice_dir/Opus-COPYING.txt"
install -m 0644 \
    "$repository_root/Wire/Sources/CNanorsWire/LICENSE" \
    "$notice_dir/nanors-LICENSE.txt"
install -m 0644 "$crypto_root/LICENSE.txt" \
    "$notice_dir/SwiftCrypto-LICENSE.txt"
install -m 0644 "$crypto_root/NOTICE.txt" \
    "$notice_dir/SwiftCrypto-NOTICE.txt"
install -m 0644 "$asn1_root/LICENSE.txt" \
    "$notice_dir/SwiftASN1-LICENSE.txt"
install -m 0644 "$asn1_root/NOTICE.txt" \
    "$notice_dir/SwiftASN1-NOTICE.txt"

# The checked-in configuration retains the checkout-coupled development loop
# until install-host.sh moves to this image. The image itself owns a stable
# binary path, so LYTE_HOST_BIN and its explanatory block do not belong here.
awk '
    /^# LYTE_HOST_BIN:/ { dropping = 1; next }
    dropping && /^LYTE_HOST_BIN=/ { dropping = 0; next }
    !dropping { print }
' "$host_root/Systemd/lyte-host.conf" > "$config_dir/lyte-host.conf"
chmod 0644 "$config_dir/lyte-host.conf"

sed 's|exec "\$LYTE_HOST_BIN" \$LYTE_HOST_ARGS|exec /usr/local/bin/lyte-host $LYTE_HOST_ARGS|' \
    "$host_root/Systemd/lyte-host.service" > "$unit_dir/lyte-host.service"
chmod 0644 "$unit_dir/lyte-host.service"

if rg -n 'LYTE_HOST_BIN|\.build/|/home/CHANGE_ME' \
    "$config_dir/lyte-host.conf" "$unit_dir/lyte-host.service"
then
    echo "host image FAILED: checkout-coupled service path survived" >&2
    exit 1
fi

manifest="$document_dir/MANIFEST.sha256"
(
    cd "$destination"
    find . -type f ! -path './usr/local/share/doc/lyte/MANIFEST.sha256' \
        -print | LC_ALL=C sort | while IFS= read -r path; do
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$path"
        else
            shasum -a 256 "$path"
        fi
    done
) > "$manifest"
chmod 0644 "$manifest"

cleanup_failed_image=0
echo "staged Lyte host image at $destination"
