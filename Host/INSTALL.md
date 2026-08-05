# Installing lyte-host on a fresh machine

The host serves one GNOME/Mutter Wayland seat with an Intel GPU that
owns the panel (the direct eye encodes on the die that owns the
scanout). Everything below is idempotent — re-run any step freely.

## 0. Build

```sh
# Dependencies (Ubuntu): the Swift toolchain, plus the narrow OS leaves
sudo apt-get install -y pkg-config libdbus-1-dev libpipewire-0.3-dev \
    libva-dev libdrm-dev libgbm-dev libegl-dev libgl-dev avahi-daemon
cd Host && swift build -c release
```

The binary lands at `.build/release/lyte-host`. No setcap needed when
running under the service (step 2) — the capability rides the unit.

### Stage the release image

Turn the release binary into the exact root filesystem image that packaging
and installation consume:

```sh
Host/Scripts/stage-host-image.sh /tmp/lyte-host-image
Scripts/Tests/test-host-package-image.sh /tmp/lyte-host-image
```

The image owns stable paths under `usr/local/bin`, `etc/lyte`, and
`lib/systemd/system`. It also carries Lyte's license, every applicable
third-party notice, and `MANIFEST.sha256`, which authenticates every other
file in the image. Staging is rootless and inert: it does not install files,
change capabilities, contact systemd, or touch host identity.

For this first packaging slice, `install-host.sh` below remains the fast
checkout-coupled development installer. The next slice changes that installer
to consume this image; until then, staging and installation are deliberately
separate operations.

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
sudo setcap cap_sys_admin+ep .build/release/lyte-host   # hand-run only
.build/release/lyte-host --wire-listen 41151 --pair     # prints the PIN
# … client connects, enters the PIN; ctrl-C the host …
sudo systemctl start lyte-host
```

The paired identity persists in `~/.config/lyte-host/paired_clients`
beside the host's Noise key (`noise_static.key`) — both are minted on
first run and survive reinstalls and uninstalls.

## Day-to-day

| task | command |
|---|---|
| deploy a rebuild | `swift build -c release && sudo systemctl restart lyte-host` |
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
