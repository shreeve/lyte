#!/usr/bin/env bash
# install-host.sh — E4: install (or repair) the lyte-host systemd
# service. Idempotent; run as the seat user; escalates with sudo only
# for the file placements and daemon-reload.
#
# What it does:
#   1. Seeds /etc/lyte/lyte-host.conf from Host/Systemd/lyte-host.conf
#      (first install only — an existing conf is the operator's and is
#      never overwritten), substituting this user's home and the
#      first wired NIC.
#   2. Installs lyte-host.service with this user's name and uid baked
#      into User=/XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS.
#   3. daemon-reload + enable. Start is left to the operator (it will
#      contend for the listen port with any hand-run loop).
#
# After this, the dev loop is: swift build && sudo systemctl restart
# lyte-host — NO setcap step: AmbientCapabilities carries the DRM
# ticket on the service itself.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_SRC="$HERE/Systemd/lyte-host.service"
CONF_SRC="$HERE/Systemd/lyte-host.conf"
UNIT_DST=/etc/systemd/system/lyte-host.service
CONF_DST=/etc/lyte/lyte-host.conf

SEAT_USER="$(id -un)"
SEAT_UID="$(id -u)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; }

echo "lyte-host service install (user $SEAT_USER, uid $SEAT_UID)"

# --- 1. the conf: seeded once, owned by the operator after ----------
if sudo test -f "$CONF_DST"; then
    ok "$CONF_DST exists — operator-owned, not touched"
else
    WIRED_NIC="$(ls /sys/class/net | grep -E '^(en|eth)' | head -1 || true)"
    sudo mkdir -p /etc/lyte
    sed -e "s|/home/CHANGE_ME|$HOME|" \
        -e "s|--advertise-interface CHANGE_ME|--advertise-interface ${WIRED_NIC:-CHANGE_ME}|" \
        "$CONF_SRC" | sudo tee "$CONF_DST" >/dev/null
    ok "seeded $CONF_DST (bin in build tree, NIC ${WIRED_NIC:-UNSET — edit the conf})"
fi

# --- 2. the unit: always refreshed (it is ours, the conf is theirs) -
sed -e "s|User=lyte-seat-user-set-by-installer|User=$SEAT_USER|" \
    -e "s|lyte-seat-uid-set-by-installer|$SEAT_UID|g" \
    "$UNIT_SRC" | sudo tee "$UNIT_DST" >/dev/null
ok "installed $UNIT_DST"

# --- 3. reload + enable --------------------------------------------
sudo systemctl daemon-reload
sudo systemctl enable lyte-host.service >/dev/null 2>&1
ok "enabled lyte-host.service"
if systemctl is-active --quiet lyte-host.service; then
    ok "service is running"
else
    todo "not started — stop any hand-run loop on the same port, then:"
    printf '    sudo systemctl start lyte-host\n'
fi
