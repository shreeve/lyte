#!/usr/bin/env bash
# Remove what install-host.sh and deploy-host.sh own: the unit, the
# ~/.local/bin/lyte-host link, every deployed version and the legal payload.
# host.conf and the logs survive unless --purge. Identity (noise_static.key,
# paired_clients — new and pre-XDG locations alike) is never removed. Run as
# the seat user; only the unit removal escalates.
set -euo pipefail

purge=0
case "${1:-}" in
    '') ;;
    --purge) purge=1 ;;
    *) echo "usage: Host/Scripts/uninstall-host.sh [--purge]" >&2; exit 64 ;;
esac

fail() {
    echo "host uninstall FAILED: $*" >&2
    exit 1
}

[[ "$(id -u)" != 0 ]] || fail "run as the seat user, not root"
[[ "${HOME:-}" == /* && "$HOME" != / && -d "$HOME" ]] \
    || fail "HOME must be an existing absolute directory"

install_root="${LYTE_INSTALL_ROOT:-}"
if [[ -n "$install_root" ]]; then
    [[ "$install_root" == /* && -d "$install_root" && ! -L "$install_root" ]] \
        || fail "LYTE_INSTALL_ROOT must be a real absolute directory"
    install_root="$(cd "$install_root" && pwd -P)"
    [[ "$install_root" != / ]] \
        || fail "use an empty LYTE_INSTALL_ROOT for the real root"
    as_root() { "$@"; }
else
    as_root() { sudo "$@"; }
fi
systemctl_command="${LYTE_SYSTEMCTL:-systemctl}"

xdg_home() {
    local value="$1" fallback="$2"
    if [[ "$value" == /* ]]; then printf '%s\n' "${value%/}"; else printf '%s\n' "$fallback"; fi
}
home="${HOME%/}"
config_dir="$(xdg_home "${XDG_CONFIG_HOME:-}" "$home/.config")/lyte"
state_dir="$(xdg_home "${XDG_STATE_HOME:-}" "$home/.local/state")/lyte"
data_dir="$(xdg_home "${XDG_DATA_HOME:-}" "$home/.local/share")/lyte"
unit="$install_root/etc/systemd/system/lyte-host.service"
link="$home/.local/bin/lyte-host"

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

remove_tree() {
    local path="$1"
    if [[ -d "$path" && ! -L "$path" ]]; then
        find "$path" -xdev -depth -delete
    elif [[ -e "$path" || -L "$path" ]]; then
        fail "$path is not a real directory"
    fi
}

echo "lyte-host uninstall"
if [[ -f "$unit" ]]; then
    as_root "$systemctl_command" disable --now lyte-host.service \
        >/dev/null 2>&1 || true
    as_root rm -f -- "$unit"
    as_root "$systemctl_command" daemon-reload
    ok "stopped, disabled, and removed $unit"
else
    ok "no unit installed — nothing to stop"
fi

if [[ -L "$link" ]]; then
    case "$(readlink "$link")" in
        "$data_dir/versions/"*) rm -f -- "$link"; ok "removed $link" ;;
        *) ok "kept $link (not a deployed version)" ;;
    esac
fi
remove_tree "$data_dir/versions"
remove_tree "$data_dir/doc"
rm -f -- "$data_dir/previous"
rmdir -- "$data_dir" 2>/dev/null || true
ok "removed deployed versions and the legal payload"

if (( purge )); then
    rm -f -- "$config_dir/host.conf" "$state_dir/host.log" "$state_dir/host.log.1"
    ok "purged $config_dir/host.conf and the host logs"
elif [[ -f "$config_dir/host.conf" ]]; then
    ok "kept $config_dir/host.conf (remove with --purge)"
fi

ok "host identity in $config_dir untouched — see Host/INSTALL.md"
