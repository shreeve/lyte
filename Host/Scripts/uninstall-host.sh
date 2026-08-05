#!/usr/bin/env bash
# Remove image-owned Lyte host files. Configuration survives by default;
# host identity is never in this script's ownership.
set -euo pipefail

purge=0
case "${1:-}" in
    '') ;;
    --purge) purge=1 ;;
    *) echo "usage: Host/Scripts/uninstall-host.sh [--purge]" >&2; exit 64 ;;
esac

install_root="${LYTE_INSTALL_ROOT:-}"
if [[ -n "$install_root" ]]; then
    [[ "$install_root" == /* && -d "$install_root" && ! -L "$install_root" ]] || {
        echo "host uninstall FAILED: LYTE_INSTALL_ROOT must be a real absolute directory" >&2
        exit 1
    }
    install_root="$(cd "$install_root" && pwd -P)"
    [[ "$install_root" != / ]] || {
        echo "host uninstall FAILED: use an empty LYTE_INSTALL_ROOT for the real root" >&2
        exit 1
    }
    as_root() { "$@"; }
else
    as_root() { sudo "$@"; }
fi

destination() { printf '%s%s\n' "$install_root" "$1"; }
systemctl_command="${LYTE_SYSTEMCTL:-systemctl}"
unit="$(destination /etc/systemd/system/lyte-host.service)"
binary="$(destination /usr/local/bin/lyte-host)"
documents="$(destination /usr/local/share/doc/lyte)"
config_directory="$(destination /etc/lyte)"

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

echo "lyte-host image uninstall"
if [[ -f "$unit" ]]; then
    as_root "$systemctl_command" disable --now lyte-host.service \
        >/dev/null 2>&1 || true
    as_root rm -f -- "$unit"
    as_root "$systemctl_command" daemon-reload
    ok "stopped, disabled, and removed $unit"
else
    ok "no unit installed — nothing to stop"
fi

as_root rm -f -- "$binary"
if [[ -d "$documents" && ! -L "$documents" ]]; then
    as_root find "$documents" -xdev -depth -delete
elif [[ -e "$documents" || -L "$documents" ]]; then
    echo "host uninstall FAILED: document path is not a real directory" >&2
    exit 1
fi
ok "removed image-owned binary and legal payload"

if (( purge )); then
    if [[ -d "$config_directory" && ! -L "$config_directory" ]]; then
        as_root find "$config_directory" -xdev -depth -delete
    elif [[ -e "$config_directory" || -L "$config_directory" ]]; then
        echo "host uninstall FAILED: config path is not a real directory" >&2
        exit 1
    fi
    ok "purged $config_directory"
elif as_root test -d "$config_directory" 2>/dev/null; then
    ok "kept $config_directory (operator conf — remove with --purge)"
fi

ok "host identity (~/.config/lyte-host) untouched — see INSTALL.md"
