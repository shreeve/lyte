#!/usr/bin/env bash
# Exercise the image-consuming installer and uninstaller under a private HOME
# and install root: no sudo, no systemd, no real home. Identity files at both
# the XDG and the pre-XDG location must survive every step byte-for-byte.
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

fail() {
    echo "host installer FAILED: $*" >&2
    return 1
}

identity_fingerprint() {
    local home="$1" file
    for file in \
        "$home/.config/lyte/noise_static.key" \
        "$home/.config/lyte/paired_clients" \
        "$home/.config/lyte-host/noise_static.key" \
        "$home/.config/lyte-host/paired_clients"
    do
        printf '%s %s %s\n' "$file" "$(sha256_file "$file")" "$(file_mode "$file")"
    done
}

# Runs the rendered unit's ExecStart script the way systemd would (with
# "$$" unescaped), against whatever ~/.local/bin/lyte-host is.
run_exec_start() {
    local unit="$1" script
    script="$(sed -n "s|^ExecStart=/bin/sh -c '\(.*\)'\$|\1|p" "$unit")"
    [[ -n "$script" ]] || fail "unit has no /bin/sh ExecStart"
    script="${script//\$\$/\$}"
    LYTE_HOST_ARGS="--wire-listen 41151 --pair" /bin/sh -c "$script"
}

# $1: image; $2: 1 to also run the unit's ExecStart (fake binaries only —
# never on a real host binary).
exercise_image() {
    local image="$1" run_exec="${2:-0}"
    local scratch install_root home fake_systemctl systemctl_log unit
    local identity_before config_before conf log_dir
    "$verify_script" "$image"
    scratch="$(mktemp -d -t lyte-host-installer-test.XXXXXX)"
    scratch="$(cd "$scratch" && pwd -P)"
    install_root="$scratch/root"
    home="$scratch/home"
    mkdir -p "$install_root" "$home/.config/lyte" "$home/.config/lyte-host"
    printf 'new identity\n' > "$home/.config/lyte/noise_static.key"
    printf 'new paired\n' > "$home/.config/lyte/paired_clients"
    printf 'legacy identity\n' > "$home/.config/lyte-host/noise_static.key"
    printf 'legacy paired\n' > "$home/.config/lyte-host/paired_clients"
    chmod 0600 "$home/.config/lyte/"* "$home/.config/lyte-host/"*
    identity_before="$(identity_fingerprint "$home")"
    systemctl_log="$scratch/systemctl.log"
    fake_systemctl="$scratch/systemctl"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf '\''%s\n'\'' "$*" >> "$LYTE_SYSTEMCTL_LOG"' \
        '[[ "${1:-}" != is-active ]]' > "$fake_systemctl"
    chmod 0755 "$fake_systemctl"
    unit="$install_root/etc/systemd/system/lyte-host.service"
    conf="$home/.config/lyte/host.conf"

    run_installer() {
        env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME \
            HOME="$home" \
            LYTE_INSTALL_ROOT="$install_root" \
            LYTE_SYSTEMCTL="$fake_systemctl" \
            LYTE_SYSTEMCTL_LOG="$systemctl_log" \
            LYTE_SEAT_USER=lyte-test-user \
            LYTE_SEAT_UID=4242 \
            "$@"
    }

    LYTE_ADVERTISE_INTERFACE=en-test0 run_installer "$installer" "$image" >/dev/null

    # The binary is a deployed version behind the link the unit executes.
    [[ -L "$home/.local/bin/lyte-host" ]] || fail "no deployed link"
    cmp "$image/bin/lyte-host" "$home/.local/bin/lyte-host"
    case "$(readlink "$home/.local/bin/lyte-host")" in
        "$home/.local/share/lyte/versions/"*/lyte-host) ;;
        *) fail "link escapes the versions directory" ;;
    esac
    cmp "$image/doc/MANIFEST.sha256" \
        "$home/.local/share/lyte/doc/MANIFEST.sha256"
    [[ "$(file_mode "$conf")" == 644 ]]
    [[ "$(file_mode "$home/.config/lyte")" == 700 ]]
    [[ "$(file_mode "$home/.local/state/lyte")" == 700 ]]
    [[ "$(file_mode "$unit")" == 644 ]]
    grep -Fq -- '--advertise-interface en-test0' "$conf"

    # The unit names the real home: systemd's %h would be /root here.
    grep -Fxq 'User=lyte-test-user' "$unit"
    grep -Fxq "EnvironmentFile=$home/.config/lyte/host.conf" "$unit"
    grep -Fxq "Environment=XDG_CONFIG_HOME=$home/.config" "$unit"
    grep -Fxq "Environment=XDG_STATE_HOME=$home/.local/state" "$unit"
    grep -Fxq 'Environment=XDG_RUNTIME_DIR=/run/user/4242' "$unit"
    grep -Fq "exec $home/.local/bin/lyte-host \$\$LYTE_HOST_ARGS >> \"\$\$log\" 2>&1" "$unit"
    grep -Fq "log=$home/.local/state/lyte/host.log;" "$unit"
    grep -Fxq 'AmbientCapabilities=CAP_SYS_ADMIN' "$unit"
    grep -Fxq 'LimitRTPRIO=50' "$unit"
    if grep -vE '^#' "$unit" \
        | grep -nE '@[A-Z_]+@|%|/tmp/lyte-host-session|/etc/lyte/|/usr/local/bin'
    then
        fail "unit kept a token, a specifier, or a pre-XDG path"
    fi
    grep -Fxq 'daemon-reload' "$systemctl_log"
    grep -Fxq 'enable lyte-host.service' "$systemctl_log"
    grep -Fxq 'is-active --quiet lyte-host.service' "$systemctl_log"
    if grep -nE '(^| )(start|restart)( |$)' "$systemctl_log"; then
        fail "installer started or restarted the service"
    fi

    if (( run_exec )); then
        log_dir="$home/.local/state/lyte"
        HOME="$home" run_exec_start "$unit"
        grep -Fxq 'fake-host --wire-listen 41151 --pair' "$log_dir/host.log" \
            || fail "ExecStart did not run the host with LYTE_HOST_ARGS"
        [[ "$(file_mode "$log_dir/host.log")" == 600 ]] || fail "log is not 0600"
        # Over 64 MiB rotates to host.log.1 at the next start.
        dd if=/dev/null of="$log_dir/host.log" bs=1024 seek=65537 2>/dev/null
        HOME="$home" run_exec_start "$unit"
        [[ "$(wc -c < "$log_dir/host.log.1" | tr -d ' ')" == $((65537 * 1024)) ]] \
            || fail "oversized log was not rotated"
        grep -Fxq 'fake-host --wire-listen 41151 --pair' "$log_dir/host.log"
        [[ "$(wc -l < "$log_dir/host.log" | tr -d ' ')" == 1 ]]
        HOME="$home" run_exec_start "$unit"
        [[ "$(wc -l < "$log_dir/host.log" | tr -d ' ')" == 2 ]] \
            || fail "a small log was rotated"
    fi

    # A reinstall refreshes the product but never the operator's conf.
    printf '# operator marker\n' >> "$conf"
    chmod 0600 "$conf"
    config_before="$(sha256_file "$conf")"
    LYTE_ADVERTISE_INTERFACE=en-other0 run_installer "$installer" "$image" >/dev/null
    [[ "$config_before" == "$(sha256_file "$conf")" ]]
    [[ "$(file_mode "$conf")" == 600 ]]
    [[ "$identity_before" == "$(identity_fingerprint "$home")" ]]

    run_installer "$uninstaller" >/dev/null
    [[ ! -e "$home/.local/bin/lyte-host" && ! -L "$home/.local/bin/lyte-host" ]]
    [[ ! -e "$home/.local/share/lyte" ]]
    [[ ! -e "$unit" ]]
    [[ -f "$conf" ]]
    grep -Fxq 'disable --now lyte-host.service' "$systemctl_log"
    [[ "$identity_before" == "$(identity_fingerprint "$home")" ]]

    LYTE_ADVERTISE_INTERFACE=en-test0 run_installer "$installer" "$image" >/dev/null
    run_installer "$uninstaller" --purge >/dev/null
    [[ ! -e "$conf" ]]
    [[ "$identity_before" == "$(identity_fingerprint "$home")" ]] \
        || fail "--purge touched identity"

    # XDG base directories carry through to the unit.
    env HOME="$home" \
        XDG_CONFIG_HOME="$scratch/xdg-config" \
        XDG_STATE_HOME="$scratch/xdg-state" \
        XDG_DATA_HOME="$scratch/xdg-data" \
        LYTE_INSTALL_ROOT="$install_root" \
        LYTE_SYSTEMCTL="$fake_systemctl" \
        LYTE_SYSTEMCTL_LOG="$systemctl_log" \
        LYTE_ADVERTISE_INTERFACE=en-test0 \
        "$installer" "$image" >/dev/null
    [[ -f "$scratch/xdg-config/lyte/host.conf" ]]
    grep -Fxq "EnvironmentFile=$scratch/xdg-config/lyte/host.conf" "$unit"
    grep -Fxq "Environment=XDG_STATE_HOME=$scratch/xdg-state" "$unit"
    case "$(readlink "$home/.local/bin/lyte-host")" in
        "$scratch/xdg-data/lyte/versions/"*/lyte-host) ;;
        *) fail "XDG_DATA_HOME ignored by the deploy" ;;
    esac
    [[ "$identity_before" == "$(identity_fingerprint "$home")" ]]

    find "$scratch" -xdev -depth -delete
    echo "host installer tests PASSED"
}

self_test() {
    local scratch fake_binary crypto_root asn1_root image corrupt empty_root
    local unsafe_home
    scratch="$(mktemp -d -t lyte-host-installer-self-test.XXXXXX)"
    self_test_scratch="$scratch"
    cleanup_self_test() { find "$self_test_scratch" -xdev -depth -delete; }
    trap cleanup_self_test EXIT
    fake_binary="$scratch/lyte-host"
    printf '#!/bin/sh\necho "fake-host $*"\n' > "$fake_binary"
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
    exercise_image "$image" 1

    # A corrupt image installs nothing, anywhere.
    corrupt="$scratch/corrupt"
    cp -R "$image" "$corrupt"
    printf 'corruption\n' >> "$corrupt/etc/host.conf"
    empty_root="$scratch/empty-root"
    mkdir -p "$empty_root/root" "$empty_root/home"
    if HOME="$empty_root/home" LYTE_INSTALL_ROOT="$empty_root/root" \
        "$installer" "$corrupt" >/dev/null 2>&1
    then
        fail "corrupt image was installed"
    fi
    [[ -z "$(find "$empty_root" -mindepth 2 -print -quit)" ]]

    # A home the unit cannot carry verbatim is refused before any change.
    unsafe_home="$scratch/home with space"
    mkdir -p "$unsafe_home"
    if HOME="$unsafe_home" LYTE_INSTALL_ROOT="$empty_root/root" \
        "$installer" "$image" >/dev/null 2>&1
    then
        fail "unit-unsafe home was accepted"
    fi
    [[ -z "$(find "$unsafe_home" "$empty_root" -mindepth 2 -print -quit)" ]]

    "$repo_root/Scripts/Tests/test-host-deploy.sh"
    cleanup_self_test
    trap - EXIT
    echo "host installer self-test PASSED"
}

case "${1:-}" in
    --self-test) self_test ;;
    '') echo "usage: Scripts/Tests/test-host-installer.sh IMAGE|--self-test" >&2; exit 64 ;;
    *) exercise_image "$1" 0 ;;
esac
