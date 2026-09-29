#!/usr/bin/env bash
# Install or repair the Lyte Linux host from a verified image. Run as the seat
# user (never with sudo); only the root-owned side escalates. What the
# service executes and reads its arguments from is root's, so code running
# as the seat user cannot plant a binary or an environment that the service
# then runs with CAP_SYS_ADMIN. Start/restart is always explicit; identity is
# never touched.
#
#   /usr/local/lib/lyte/versions/<id>/lyte-host  the binary (deploy-host.sh)
#   /usr/local/lib/lyte/lyte-host                symlink the unit executes
#   /usr/local/share/doc/lyte/                   legal payload
#   /etc/lyte/host.conf                          seeded once, operator-owned
#   ~/.config/lyte/                              identity (the seat user's)
#   ~/.local/state/lyte/                         host.log
#   /etc/systemd/system/lyte-host.service        rendered from the template
#
# A host.conf from an earlier install (~/.config/lyte/host.conf) seeds
# /etc/lyte/host.conf and is left in place. XDG_CONFIG_HOME and
# XDG_STATE_HOME are honored when absolute; the rendered unit carries the
# resolved directories so the service agrees.
set -euo pipefail

usage() {
    echo "usage: Host/Scripts/install-host.sh [HOST_IMAGE]" >&2
    echo "       with no image, stage the current release build first" >&2
    exit 64
}

fail() {
    echo "host install FAILED: $*" >&2
    exit 1
}

[[ $# -le 1 ]] || usage

host_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$host_root/Scripts/lib/host-common.sh"
stage_script="$host_root/Scripts/stage-host-image.sh"
verify_script="$host_root/Scripts/verify-host-image.sh"
deploy_script="$host_root/Scripts/deploy-host.sh"
scratch=""
unit_render=""

cleanup() {
    local status=$?
    [[ -z "$unit_render" ]] || rm -f -- "$unit_render"
    if [[ -n "$scratch" && -d "$scratch" ]]; then
        find "$scratch" -xdev -depth -delete
    fi
    exit "$status"
}
trap cleanup EXIT

[[ "$(id -u)" != 0 ]] || fail "run as the seat user, not root (the script escalates only for the unit)"
[[ "${HOME:-}" == /* && "$HOME" != / && -d "$HOME" ]] \
    || fail "HOME must be an existing absolute directory"

if [[ $# -eq 1 ]]; then
    image="$1"
else
    scratch="$(mktemp -d -t lyte-host-install.XXXXXX)"
    image="$scratch/image"
    "$stage_script" "$image"
fi
"$verify_script" "$image"
image="$(cd "$image" && pwd -P)"

system_side

seat_user="${LYTE_SEAT_USER:-$(id -un)}"
seat_uid="${LYTE_SEAT_UID:-$(id -u)}"
[[ "$seat_user" =~ ^[A-Za-z0-9._-]+$ && "$seat_uid" =~ ^[0-9]+$ ]] \
    || fail "invalid seat identity"

home="${HOME%/}"
config_home="$(xdg_home "${XDG_CONFIG_HOME:-}" "$home/.config")"
state_home="$(xdg_home "${XDG_STATE_HOME:-}" "$home/.local/state")"
# Rendered verbatim into the unit: no whitespace, quotes, '%' or '$'.
for path in "$home" "$config_home" "$state_home"; do
    [[ "$path" =~ ^/[A-Za-z0-9._/+-]+$ ]] \
        || fail "path unsafe for a systemd unit: $path"
done

advertise_interface="${LYTE_ADVERTISE_INTERFACE:-}"
if [[ -z "$advertise_interface" && -d /sys/class/net ]]; then
    advertise_interface="$(find /sys/class/net -mindepth 1 -maxdepth 1 \
        -printf '%f\n' 2>/dev/null | LC_ALL=C sort \
        | grep -E '^(en|eth)' | head -1 || true)"
fi
[[ -z "$advertise_interface" \
    || "$advertise_interface" =~ ^[A-Za-z0-9_.:-]+$ ]] \
    || fail "invalid advertise interface"

legacy_config_file="$config_home/lyte/host.conf"
unit_destination="$install_root/etc/systemd/system/lyte-host.service"

echo "lyte-host image install (user $seat_user, uid $seat_uid, home $home)"

# The binary becomes an immutable version; the link flip is atomic and a
# running service keeps its open executable until an explicit restart.
"$deploy_script" "$image/bin" | sed 's/^/    /'
ok "deployed $lib_path/lyte-host"

as_root install -d -m 0755 "$doc_dir/third-party"
while IFS= read -r source; do
    as_root install -m 0644 "$source" "$doc_dir/${source#"$image/doc/"}"
done < <(find "$image/doc" -type f | LC_ALL=C sort)
ok "installed the legal payload in $doc_dir"

# Configuration is seeded exactly once. Reinstalling never changes an
# operator's arguments, chosen interface, or permissions.
install -d -m 0700 "$config_home/lyte" "$state_home/lyte"
if [[ -e "$conf_file" ]]; then
    ok "$conf_path exists — operator-owned, not touched"
else
    if [[ -f "$legacy_config_file" ]]; then
        seed="$legacy_config_file"
        note="copied from $legacy_config_file, which stays"
    else
        seed="$(mktemp)"
        sed "s|--advertise-interface CHANGE_ME|--advertise-interface ${advertise_interface:-CHANGE_ME}|" \
            "$image/etc/host.conf" > "$seed"
        note="NIC ${advertise_interface:-UNSET — edit the conf}"
    fi
    as_root install -d -m 0755 "$(dirname "$conf_file")"
    as_root install -m 0644 "$seed" "$conf_file"
    [[ "$seed" == "$legacy_config_file" ]] || rm -f -- "$seed"
    ok "seeded $conf_path ($note)"
fi

# The unit is product-owned and always refreshed from the verified template.
unit_render="$(mktemp)"
sed -e "s|@USER@|$seat_user|g" \
    -e "s|@UID@|$seat_uid|g" \
    -e "s|@CONFIG_HOME@|$config_home|g" \
    -e "s|@STATE_HOME@|$state_home|g" \
    "$image/systemd/lyte-host.service" > "$unit_render"
if grep -En '@[A-Z_]+@' "$unit_render"; then
    fail "unit template kept an unrendered token"
fi
as_root install -d -m 0755 "$(dirname "$unit_destination")"
as_root install -m 0644 "$unit_render" "$unit_destination"
ok "installed $unit_destination"

as_root "$systemctl_command" daemon-reload
as_root "$systemctl_command" enable lyte-host.service >/dev/null 2>&1
ok "enabled lyte-host.service"
if "$systemctl_command" is-active --quiet lyte-host.service; then
    ok "service is running; restart remains explicit:"
    printf '    sudo systemctl restart lyte-host\n'
else
    todo "not started — stop any hand-run loop on the same port, then:"
    printf '    sudo systemctl start lyte-host\n'
fi
