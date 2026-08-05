#!/usr/bin/env bash
# Install or repair the stable Lyte Linux host image. The image is verified
# before the first privileged action; configuration and identity remain owned
# by the operator. Start/restart is always explicit.
set -euo pipefail

usage() {
    echo "usage: Host/Scripts/install-host.sh [HOST_IMAGE]" >&2
    echo "       with no image, stage the current release build first" >&2
    exit 64
}

[[ $# -le 1 ]] || usage

host_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
stage_script="$host_root/Scripts/stage-host-image.sh"
verify_script="$host_root/Scripts/verify-host-image.sh"
scratch=""
config_seed=""
unit_render=""

cleanup() {
    local status=$?
    [[ -z "$config_seed" ]] || rm -f -- "$config_seed"
    [[ -z "$unit_render" ]] || rm -f -- "$unit_render"
    if [[ -n "$scratch" && -d "$scratch" ]]; then
        find "$scratch" -xdev -depth -delete
    fi
    exit "$status"
}
trap cleanup EXIT

if [[ $# -eq 1 ]]; then
    image="$1"
else
    scratch="$(mktemp -d -t lyte-host-install.XXXXXX)"
    image="$scratch/image"
    "$stage_script" "$image"
fi
"$verify_script" "$image"
image="$(cd "$image" && pwd -P)"

# LYTE_INSTALL_ROOT is a test/package-construction seam. A real installation
# uses / and sudo; a prefixed root performs no escalation and contacts only the
# injected systemctl command.
install_root="${LYTE_INSTALL_ROOT:-}"
if [[ -n "$install_root" ]]; then
    [[ "$install_root" == /* && -d "$install_root" && ! -L "$install_root" ]] || {
        echo "host install FAILED: LYTE_INSTALL_ROOT must be a real absolute directory" >&2
        exit 1
    }
    install_root="$(cd "$install_root" && pwd -P)"
    [[ "$install_root" != / ]] || {
        echo "host install FAILED: use an empty LYTE_INSTALL_ROOT for the real root" >&2
        exit 1
    }
    as_root() { "$@"; }
else
    as_root() { sudo "$@"; }
fi

destination() { printf '%s%s\n' "$install_root" "$1"; }
systemctl_command="${LYTE_SYSTEMCTL:-systemctl}"
seat_user="${LYTE_SEAT_USER:-$(id -un)}"
seat_uid="${LYTE_SEAT_UID:-$(id -u)}"
advertise_interface="${LYTE_ADVERTISE_INTERFACE:-}"
if [[ -z "$advertise_interface" && -d /sys/class/net ]]; then
    advertise_interface="$(find /sys/class/net -mindepth 1 -maxdepth 1 \
        -printf '%f\n' 2>/dev/null | LC_ALL=C sort \
        | grep -E '^(en|eth)' | head -1 || true)"
fi
[[ "$seat_user" =~ ^[A-Za-z0-9._-]+$ && "$seat_uid" =~ ^[0-9]+$ ]] || {
    echo "host install FAILED: invalid seat identity" >&2
    exit 1
}
[[ -z "$advertise_interface" \
    || "$advertise_interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
    echo "host install FAILED: invalid advertise interface" >&2
    exit 1
}

binary_destination="$(destination /usr/local/bin/lyte-host)"
document_destination="$(destination /usr/local/share/doc/lyte)"
config_destination="$(destination /etc/lyte/lyte-host.conf)"
unit_destination="$(destination /etc/systemd/system/lyte-host.service)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; }

echo "lyte-host image install (user $seat_user, uid $seat_uid)"

# The binary and legal payload belong to the release image and are refreshed
# together. A running process retains its open executable; this script never
# restarts it underneath the operator.
as_root install -d -m 0755 "$(dirname "$binary_destination")" \
    "$document_destination/third-party"
as_root install -m 0755 "$image/usr/local/bin/lyte-host" "$binary_destination"
while IFS= read -r source; do
    relative="${source#"$image/usr/local/share/doc/lyte/"}"
    target="$document_destination/$relative"
    as_root install -d -m 0755 "$(dirname "$target")"
    as_root install -m 0644 "$source" "$target"
done < <(find "$image/usr/local/share/doc/lyte" -type f | LC_ALL=C sort)
ok "installed $binary_destination and verified legal payload"

# Configuration is seeded exactly once. Reinstalling never changes an
# operator's arguments, chosen interface, permissions, or ownership.
if as_root test -f "$config_destination"; then
    ok "$config_destination exists — operator-owned, not touched"
else
    as_root install -d -m 0755 "$(dirname "$config_destination")"
    config_seed="$(mktemp)"
    sed "s|--advertise-interface CHANGE_ME|--advertise-interface ${advertise_interface:-CHANGE_ME}|" \
        "$image/etc/lyte/lyte-host.conf" > "$config_seed"
    as_root install -m 0644 "$config_seed" "$config_destination"
    ok "seeded $config_destination (NIC ${advertise_interface:-UNSET — edit the conf})"
fi

# The unit is product-owned and always refreshed from the verified template.
as_root install -d -m 0755 "$(dirname "$unit_destination")"
unit_render="$(mktemp)"
sed -e "s|User=lyte-seat-user-set-by-installer|User=$seat_user|" \
    -e "s|lyte-seat-uid-set-by-installer|$seat_uid|g" \
    "$image/lib/systemd/system/lyte-host.service" > "$unit_render"
as_root install -m 0644 "$unit_render" "$unit_destination"
ok "installed $unit_destination"

as_root "$systemctl_command" daemon-reload
as_root "$systemctl_command" enable lyte-host.service >/dev/null 2>&1
ok "enabled lyte-host.service"
if "$systemctl_command" is-active --quiet lyte-host.service; then
    ok "service is running; restart remains explicit"
else
    todo "not started — stop any hand-run loop on the same port, then:"
    printf '    sudo systemctl start lyte-host\n'
fi
