#!/usr/bin/env bash
# Remove what install-host.sh and deploy-host.sh own: the unit, the
# root-owned /usr/local/lib/lyte (every deployed version and the active
# link) and the legal payload, plus a pre-root-owned install's
# ~/.local/bin/lyte-host link and ~/.local/share/lyte versions.
# /etc/lyte/host.conf and the logs survive unless --purge. Identity
# (noise_static.key, paired_clients — new and pre-XDG locations alike) is
# never removed. Run as the seat user; the root-owned side escalates.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/host-common.sh"

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

system_side

home="${HOME%/}"
config_dir="$(xdg_home "${XDG_CONFIG_HOME:-}" "$home/.config")/lyte"
state_dir="$(xdg_home "${XDG_STATE_HOME:-}" "$home/.local/state")/lyte"
legacy_data_dir="$(xdg_home "${XDG_DATA_HOME:-}" "$home/.local/share")/lyte"
unit="$install_root/etc/systemd/system/lyte-host.service"
legacy_link="$home/.local/bin/lyte-host"

# remove_tree [as_root] PATH
remove_tree() {
    local run=()
    if [[ "$1" == as_root ]]; then run=(as_root); shift; fi
    local path="$1"
    if [[ -d "$path" && ! -L "$path" ]]; then
        "${run[@]}" find "$path" -xdev -depth -delete
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

remove_tree as_root "$lib_dir"
remove_tree as_root "$doc_dir"
ok "removed $lib_path (every deployed version) and the legal payload"

# A pre-root-owned install kept its versions in the seat user's home.
if [[ -L "$legacy_link" ]]; then
    case "$(readlink "$legacy_link")" in
        "$legacy_data_dir/versions/"*) rm -f -- "$legacy_link" ;;
    esac
fi
remove_tree "$legacy_data_dir/versions"
remove_tree "$legacy_data_dir/doc"
rm -f -- "$legacy_data_dir/previous"
rmdir -- "$legacy_data_dir" 2>/dev/null || true

if (( purge )); then
    as_root rm -f -- "$conf_file"
    rm -f -- "$config_dir/host.conf" "$state_dir/host.log" "$state_dir/host.log.1"
    ok "purged $conf_path, a pre-root-owned $config_dir/host.conf and the host logs"
elif [[ -f "$conf_file" ]]; then
    ok "kept $conf_path (remove with --purge)"
fi

ok "host identity in $config_dir untouched — see Host/INSTALL.md"
