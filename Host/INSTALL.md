# Installing lyte-host on a fresh machine

The host serves one GNOME/Mutter Wayland seat with an Intel GPU that
owns the panel (the direct eye encodes on the die that owns the
scanout). Everything below is idempotent — re-run any step freely.
Day-to-day operation of an installed host (deploys, rollback, safety) is in
[docs/OPERATIONS.md](../docs/OPERATIONS.md).

## 0. Build

```sh
# Dependencies (Ubuntu): the Swift toolchain, plus the narrow OS leaves
sudo apt-get install -y pkg-config libdbus-1-dev libpipewire-0.3-dev \
    libva-dev libdrm-dev libgbm-dev libegl-dev libgl-dev avahi-daemon
swift build --package-path Host -c release
```

The binaries land in `Host/.build/release/`. No setcap is needed when
running under the service (step 2) — the capability rides the unit. Swift
6.1.2 on Ubuntu 26.04 needs a `libxml2.so.2` shim for its build tools; see
[docs/OPERATIONS.md](../docs/OPERATIONS.md#build-on-pup).

### Stage the release image

Turn the release binary into the exact image that packaging and installation
consume:

```sh
Host/Scripts/stage-host-image.sh /tmp/lyte-host-image
Scripts/Tests/test-host-package-image.sh /tmp/lyte-host-image
```

The image holds `bin/lyte-host`, the `etc/host.conf` seed, the
`systemd/lyte-host.service` template, Lyte's license, every applicable
third-party notice, and `doc/MANIFEST.sha256`, which authenticates every other
file in the image. Staging is rootless and inert: it does not install files,
change capabilities, contact systemd, or touch host identity.

## 1. Machine prerequisites

```sh
Host/Scripts/setup-host.sh
```

Checks and prints exact repair commands for: the service and deployed binary,
the uinput udev rule (without it client input is OFF), the rtprio limit
(optional, degrades safely), and portal-era or pre-XDG leftovers. It never
escalates itself; run the `sudo` lines it prints.

## 2. The service

Run as the seat user — not with `sudo`; the installer escalates only to
install the unit and call `systemctl`:

```sh
Host/Scripts/install-host.sh                          # stage + install the current release build
Host/Scripts/install-host.sh /path/to/lyte-host-image # or an already-staged image
```

What it does, idempotently:
- Verifies the image's exact inventory, modes, and every SHA-256 manifest
  entry before changing anything.
- Deploys the binary as a version (`deploy-host.sh`, below) and installs the
  legal payload in `~/.local/share/lyte/doc/`.
- Seeds `~/.config/lyte/host.conf` **once** (after that the conf is yours and
  reinstalls preserve its bytes and mode). Its one knob is `LYTE_HOST_ARGS`
  (listen port, advertised NIC, session flags).
- Renders `/etc/systemd/system/lyte-host.service` with your user, uid and
  real home path baked in (`User=`, `EnvironmentFile=`, `ExecStart`, the
  session bus, `XDG_RUNTIME_DIR`), plus `AmbientCapabilities=CAP_SYS_ADMIN`
  and `Restart=always`. It stays a system unit because only pid 1 can grant
  the ambient capability.
- `daemon-reload` + `enable`. Start is left to you:

```sh
sudo systemctl start lyte-host
tail -f ~/.local/state/lyte/host.log
```

### Paths

| what | where |
|---|---|
| knobs (`LYTE_HOST_ARGS`) | `~/.config/lyte/host.conf` |
| identity | `~/.config/lyte/noise_static.key`, `~/.config/lyte/paired_clients` (0600) |
| binary the unit runs | `~/.local/bin/lyte-host` → `~/.local/share/lyte/versions/<sha256-12>/lyte-host` |
| host log | `~/.local/state/lyte/host.log` (0600; over 64 MiB it becomes `host.log.1` — at the next start, and in the running host at every session boundary and once a minute) |
| unit | `/etc/systemd/system/lyte-host.service` |

`XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_DATA_HOME` move the matching
directories when set to absolute paths; the installer writes the resolved
directories into the unit so the service agrees.

A host upgraded from the pre-XDG layout keeps working: when an identity file
is missing from `~/.config/lyte/` but present in `~/.config/lyte-host/`,
lyte-host copies it across (0600, verified byte-for-byte) and logs one line.
It never modifies or deletes the old copy, and it writes only to the new
location.

## 3. Deploy a rebuild

```sh
swift build --package-path Host -c release
Host/Scripts/deploy-host.sh --restart     # copy, flip the link, restart
Host/Scripts/deploy-host.sh --status      # active/previous version + sha256
Host/Scripts/deploy-host.sh --rollback --restart
```

Each deploy copies `lyte-host` (and `lyte-audio-check` when built) into
`versions/<first 12 hex of its sha256>/`, then swaps `~/.local/bin/lyte-host`
in one rename. Redeploying the active binary is a no-op; the newest five
versions (`--keep N`) plus the active and previous ones are kept. Without
`--restart` the running service keeps its open executable until the next
restart.

## 4. Pair the first client

Pairing runs a 6-digit PIN over the sealed CTRL stream. Stop the
service, run one pairing host by hand, then return to the service:

```sh
sudo systemctl stop lyte-host
bin="$(readlink -f ~/.local/bin/lyte-host)"
sudo setcap cap_sys_admin+ep "$bin"             # hand-run only
"$bin" --wire-listen 41151 --pair               # prints the PIN
# … client connects, enters the PIN; ctrl-C the host …
sudo setcap -r "$bin"
sudo systemctl start lyte-host
```

The service never needs the file capability: it gets CAP_SYS_ADMIN from the
unit (`AmbientCapabilities`).

The paired identity persists in `~/.config/lyte/paired_clients` beside the
host's Noise key (`noise_static.key`) — both are minted on first run and
survive deploys, reinstalls and uninstalls.

## Day-to-day

| task | command |
|---|---|
| deploy a rebuild | `swift build --package-path Host -c release && Host/Scripts/deploy-host.sh --restart` |
| status | `systemctl is-active lyte-host; Host/Scripts/deploy-host.sh --status` |
| host log | `~/.local/state/lyte/host.log` |
| unit lifecycle | `sudo journalctl -u lyte-host` |
| change port/flags | edit `~/.config/lyte/host.conf`, restart |

## Uninstall

```sh
Host/Scripts/uninstall-host.sh          # unit, link, versions, legal payload; keep host.conf
Host/Scripts/uninstall-host.sh --purge  # …and host.conf and the host logs
```

Neither touches identity — `~/.config/lyte/noise_static.key`,
`~/.config/lyte/paired_clients`, or a pre-XDG `~/.config/lyte-host/`. They are
identity, not installation; remove them by hand only if you mean to unpair
every client (there is no undo).
