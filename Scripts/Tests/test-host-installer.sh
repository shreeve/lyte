#!/usr/bin/env bash
# Exercise the image-consuming installer without sudo or a real systemd root.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
installer="$repo_root/Host/Scripts/install-host.sh"
uninstaller="$repo_root/Host/Scripts/uninstall-host.sh"
stage_script="$repo_root/Host/Scripts/stage-host-image.sh"
verify_script="$repo_root/Host/Scripts/verify-host-image.sh"

file_mode() {
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

exercise_image() {
    local image="$1"
    local scratch install_root fake_systemctl systemctl_log identity
    local identity_before config_before
    "$verify_script" "$image"
    scratch="$(mktemp -d -t lyte-host-installer-test.XXXXXX)"
    install_root="$scratch/root"
    mkdir -p "$install_root" "$scratch/home/.config/lyte-host"
    identity="$scratch/home/.config/lyte-host/noise_static.key"
    printf 'identity must survive\n' > "$identity"
    identity_before="$(sha256_file "$identity")"
    systemctl_log="$scratch/systemctl.log"
    fake_systemctl="$scratch/systemctl"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf '\''%s\n'\'' "$*" >> "$LYTE_SYSTEMCTL_LOG"' \
        '[[ "${1:-}" != is-active ]]' > "$fake_systemctl"
    chmod 0755 "$fake_systemctl"

    LYTE_INSTALL_ROOT="$install_root" \
    LYTE_SYSTEMCTL="$fake_systemctl" \
    LYTE_SYSTEMCTL_LOG="$systemctl_log" \
    LYTE_SEAT_USER=lyte-test-user \
    LYTE_SEAT_UID=4242 \
    LYTE_ADVERTISE_INTERFACE=en-test0 \
        "$installer" "$image" >/dev/null

    cmp "$image/usr/local/bin/lyte-host" \
        "$install_root/usr/local/bin/lyte-host"
    [[ "$(file_mode "$install_root/usr/local/bin/lyte-host")" == 755 ]]
    [[ "$(file_mode "$install_root/etc/lyte/lyte-host.conf")" == 644 ]]
    [[ "$(file_mode "$install_root/etc/systemd/system/lyte-host.service")" == 644 ]]
    rg -Fq -- '--advertise-interface en-test0' \
        "$install_root/etc/lyte/lyte-host.conf"
    rg -Fq 'User=lyte-test-user' \
        "$install_root/etc/systemd/system/lyte-host.service"
    rg -Fq 'XDG_RUNTIME_DIR=/run/user/4242' \
        "$install_root/etc/systemd/system/lyte-host.service"
    rg -Fq 'exec /usr/local/bin/lyte-host $LYTE_HOST_ARGS' \
        "$install_root/etc/systemd/system/lyte-host.service"
    cmp "$image/usr/local/share/doc/lyte/MANIFEST.sha256" \
        "$install_root/usr/local/share/doc/lyte/MANIFEST.sha256"
    rg -Fxq 'daemon-reload' "$systemctl_log"
    rg -Fxq 'enable lyte-host.service' "$systemctl_log"
    rg -Fxq 'is-active --quiet lyte-host.service' "$systemctl_log"
    if rg -n '(^| )(start|restart)( |$)' "$systemctl_log"; then
        echo "host installer FAILED: installer started or restarted the service" >&2
        return 1
    fi

    printf '# operator marker\n' >> "$install_root/etc/lyte/lyte-host.conf"
    chmod 0600 "$install_root/etc/lyte/lyte-host.conf"
    config_before="$(sha256_file \
        "$install_root/etc/lyte/lyte-host.conf")"
    LYTE_INSTALL_ROOT="$install_root" \
    LYTE_SYSTEMCTL="$fake_systemctl" \
    LYTE_SYSTEMCTL_LOG="$systemctl_log" \
    LYTE_SEAT_USER=lyte-test-user \
    LYTE_SEAT_UID=4242 \
    LYTE_ADVERTISE_INTERFACE=en-other0 \
        "$installer" "$image" >/dev/null
    [[ "$config_before" == "$(sha256_file \
        "$install_root/etc/lyte/lyte-host.conf")" ]]
    [[ "$(file_mode "$install_root/etc/lyte/lyte-host.conf")" == 600 ]]
    [[ "$identity_before" == "$(sha256_file "$identity")" ]]

    LYTE_INSTALL_ROOT="$install_root" \
    LYTE_SYSTEMCTL="$fake_systemctl" \
    LYTE_SYSTEMCTL_LOG="$systemctl_log" \
        "$uninstaller" >/dev/null
    [[ ! -e "$install_root/usr/local/bin/lyte-host" ]]
    [[ ! -e "$install_root/usr/local/share/doc/lyte" ]]
    [[ ! -e "$install_root/etc/systemd/system/lyte-host.service" ]]
    [[ -f "$install_root/etc/lyte/lyte-host.conf" ]]
    rg -Fxq 'disable --now lyte-host.service' "$systemctl_log"
    [[ "$identity_before" == "$(sha256_file "$identity")" ]]

    LYTE_INSTALL_ROOT="$install_root" \
    LYTE_SYSTEMCTL="$fake_systemctl" \
    LYTE_SYSTEMCTL_LOG="$systemctl_log" \
    LYTE_SEAT_USER=lyte-test-user \
    LYTE_SEAT_UID=4242 \
    LYTE_ADVERTISE_INTERFACE=en-test0 \
        "$installer" "$image" >/dev/null
    LYTE_INSTALL_ROOT="$install_root" \
    LYTE_SYSTEMCTL="$fake_systemctl" \
    LYTE_SYSTEMCTL_LOG="$systemctl_log" \
        "$uninstaller" --purge >/dev/null
    [[ ! -e "$install_root/etc/lyte" ]]
    [[ "$identity_before" == "$(sha256_file "$identity")" ]]

    find "$scratch" -xdev -depth -delete
    echo "host installer tests PASSED"
}

self_test() {
    local scratch fake_binary crypto_root asn1_root image corrupt empty_root
    scratch="$(mktemp -d -t lyte-host-installer-self-test.XXXXXX)"
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
        "$stage_script" "$image" >/dev/null
    exercise_image "$image"

    corrupt="$scratch/corrupt"
    cp -R "$image" "$corrupt"
    printf 'corruption\n' >> "$corrupt/etc/lyte/lyte-host.conf"
    empty_root="$scratch/empty-root"
    mkdir "$empty_root"
    if LYTE_INSTALL_ROOT="$empty_root" "$installer" "$corrupt" \
        >/dev/null 2>&1
    then
        echo "host installer FAILED: corrupt image was installed" >&2
        return 1
    fi
    [[ -z "$(find "$empty_root" -mindepth 1 -print -quit)" ]]
    cleanup_self_test
    trap - EXIT
    echo "host installer self-test PASSED"
}

case "${1:-}" in
    --self-test) self_test ;;
    '') echo "usage: Scripts/Tests/test-host-installer.sh IMAGE|--self-test" >&2; exit 64 ;;
    *) exercise_image "$1" ;;
esac
