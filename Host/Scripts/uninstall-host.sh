#!/usr/bin/env bash
# uninstall-host.sh — E4: remove the lyte-host systemd service.
# Idempotent. Default removes only what install-host.sh owns (the
# unit); --purge also removes /etc/lyte (the operator's conf).
#
# NEVER touched, by design: ~/.config/lyte-host/ — the Noise static
# key and paired_clients are the host's IDENTITY, not installation
# artifacts. Removing them unpairs every client, so that stays a
# deliberate hand-run step (INSTALL.md spells it out).
set -euo pipefail

UNIT=/etc/systemd/system/lyte-host.service
CONF_DIR=/etc/lyte
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

echo "lyte-host service uninstall"

if systemctl list-unit-files lyte-host.service >/dev/null 2>&1 \
   && [ -f "$UNIT" ]; then
    sudo systemctl disable --now lyte-host.service >/dev/null 2>&1 || true
    ok "service stopped and disabled"
    sudo rm -f "$UNIT"
    sudo systemctl daemon-reload
    ok "removed $UNIT"
else
    ok "no unit installed — nothing to stop"
fi

if [ "$PURGE" -eq 1 ]; then
    sudo rm -rf "$CONF_DIR"
    ok "purged $CONF_DIR"
elif sudo test -d "$CONF_DIR" 2>/dev/null; then
    ok "kept $CONF_DIR (operator conf — remove with --purge)"
fi

ok "host identity (~/.config/lyte-host) untouched — see INSTALL.md"
