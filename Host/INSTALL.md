# Installing lyte-host on a fresh machine

The host serves one GNOME/Mutter Wayland seat with an Intel GPU that
owns the panel (the direct eye encodes on the die that owns the
scanout). Everything below is idempotent — re-run any step freely.

## 0. Build

```sh
# Dependencies (Ubuntu): the Swift toolchain, plus
sudo apt-get install -y libva-dev libdrm-dev libgbm-dev libegl-dev \
    libavahi-client-dev libopus-dev
cd Host && swift build
```

The binary lands at `.build/debug/lyte-host`. No setcap needed when
running under the service (step 2) — the capability rides the unit.

## 1. Machine prerequisites

```sh
Host/Scripts/setup-host.sh
```

Checks and prints exact repair commands for: the uinput udev rule
(without it client input is OFF — E2), the rtprio limit (optional,
degrades safely), and portal-era leftovers. It never escalates
itself; run the `sudo` lines it prints.

## 2. The service

```sh
Host/Scripts/install-host.sh
```

What it does, idempotently:
- Seeds `/etc/lyte/lyte-host.conf` **once** (first install only —
  after that the conf is yours and reinstalls never touch it). Two
  knobs: `LYTE_HOST_BIN` (defaults to this checkout's build tree)
  and `LYTE_HOST_ARGS` (listen port, advertised NIC, session flags).
- Installs `/etc/systemd/system/lyte-host.service` with your user
  and uid baked in (`User=`, the session bus, `XDG_RUNTIME_DIR`),
  `AmbientCapabilities=CAP_SYS_ADMIN`, `Restart=always`.
- `daemon-reload` + `enable`. Start is left to you:

```sh
sudo systemctl start lyte-host
tail -f /tmp/lyte-host-session.log   # the host's own log, always here
```

## 3. Pair the first client

Pairing runs a 6-digit PIN over the sealed CTRL stream. Stop the
service, run one pairing host by hand, then return to the service:

```sh
sudo systemctl stop lyte-host
sudo setcap cap_sys_admin+ep .build/debug/lyte-host   # hand-run only
.build/debug/lyte-host --wire-listen 41151 --pair     # prints the PIN
# … client connects, enters the PIN; ctrl-C the host …
sudo systemctl start lyte-host
```

The paired identity persists in `~/.config/lyte-host/paired_clients`
beside the host's Noise key (`noise_static.key`) — both are minted on
first run and survive reinstalls and uninstalls.

## Day-to-day

| task | command |
|---|---|
| deploy a rebuild | `swift build && sudo systemctl restart lyte-host` |
| status | `systemctl is-active lyte-host` |
| host log | `/tmp/lyte-host-session.log` |
| unit lifecycle | `sudo journalctl -u lyte-host` |
| change port/flags | edit `/etc/lyte/lyte-host.conf`, restart |

## Uninstall

```sh
Host/Scripts/uninstall-host.sh          # stop + disable + remove unit
Host/Scripts/uninstall-host.sh --purge  # …and /etc/lyte (the conf)
```

Neither touches `~/.config/lyte-host/` — the Noise key and paired
clients are identity, not installation; remove them by hand only if
you mean to unpair every client:
`rm -r ~/.config/lyte-host` (there is no undo).
