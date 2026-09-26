# Installing lyte-host on a fresh machine

The host serves one GNOME/Mutter Wayland seat with an Intel GPU that
owns the panel (the direct eye encodes on the die that owns the
scanout). Setup and installation are idempotent: re-run them freely.
Operating an installed host (layout, deploys, rollback, pairing, uninstall,
safety) is in [docs/OPERATIONS.md](../docs/OPERATIONS.md).

## 0. Build

```sh
# Dependencies (Ubuntu): a Swift 6.1 or later toolchain (swift.org), plus
# the narrow OS leaves
sudo apt-get install -y pkg-config libdbus-1-dev libpipewire-0.3-dev \
    libva-dev libdrm-dev libgbm-dev libegl-dev libgl-dev avahi-daemon
swift build --package-path Host -c release
```

The binaries land in `Host/.build/release/`. Swift 6.1.2 on Ubuntu 26.04
needs a `libxml2.so.2` shim for its build tools; see
[docs/OPERATIONS.md](../docs/OPERATIONS.md#build-on-pup).

### Stage the release image

Turn the release binary into the exact image that packaging and installation
consume:

```sh
image="$(mktemp -d)/image"     # the destination must not exist yet
Host/Scripts/stage-host-image.sh "$image"
Scripts/Tests/test-host-package-image.sh "$image"
```

The image holds `bin/lyte-host`, the `etc/host.conf` seed, the
`systemd/lyte-host.service` template, Lyte's license, every applicable
third-party notice, and `doc/MANIFEST.sha256`, which lists the SHA-256 of every
other file in the image: an integrity check against a damaged or altered copy,
not a signature. Staging is rootless and inert: it does not install files,
change capabilities, contact systemd, or touch host identity.

## 1. Machine prerequisites

```sh
Host/Scripts/setup-host.sh
```

Run it as the seat user. It checks each prerequisite and prints the exact
repair command; it never escalates itself, so run the `sudo` lines it
prints:

1. **`CAP_SYS_ADMIN`** for the Direct Eye's DRM ticket. The installed
   service grants it ambiently (step 2); only hand-run binaries need
   `sudo setcap cap_sys_admin+ep BINARY`, re-applied after every rebuild.
   A binary without it fails loudly at startup.
2. **`/dev/uinput` access** through `/etc/udev/rules.d/60-lyte-uinput.rules`.
   Without it client input is off.
3. **Optional realtime scheduling.** The pacing and audio threads ask for
   `SCHED_RR` and degrade gracefully (`sched:` log lines say which rung
   they got). The service's unit grants it (`LimitRTPRIO=50`); a host run
   by hand needs an rtprio allowance of at least 12:

   ```sh
   echo "$USER - rtprio 20" | sudo tee /etc/security/limits.d/90-lyte-rtprio.conf
   ```

It also reports the service and deployed binary, and portal-era and
pre-XDG leftovers ([OPERATIONS.md](../docs/OPERATIONS.md#pre-xdg-leftovers)).

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
- Deploys the binary as a version (`deploy-host.sh`) and installs the legal
  payload in `~/.local/share/lyte/doc/`.
- Seeds `~/.config/lyte/host.conf` **once** (after that the conf is yours and
  reinstalls preserve its bytes and mode). Its one knob is `LYTE_HOST_ARGS`
  (listen port, advertised NIC, session flags). The seed turns on no
  clipboard sync or file drops; both are consent you add there.
- Renders `/etc/systemd/system/lyte-host.service` with your user, uid and
  real home path baked in (`User=`, `EnvironmentFile=`, `ExecStart`, the
  session bus, `XDG_RUNTIME_DIR`), plus `AmbientCapabilities=CAP_SYS_ADMIN`
  and `Restart=always`. It stays a system unit because only pid 1 can grant
  the ambient capability.
- `daemon-reload` + `enable`. Start is left to you.

Before the first start, check the seeded `--advertise-interface` in
`~/.config/lyte/host.conf`: the installer seeds `LYTE_ADVERTISE_INTERFACE`
when set, else the first wired (`en*` or `eth*`) interface it finds, and
prints it; `CHANGE_ME` means it found none. Clients find the host over mDNS
only on that interface.

```sh
sudo systemctl start lyte-host
tail -f ~/.local/state/lyte/host.log
```

## Next

The service is installed and enabled. Pair the first client, deploy
rebuilds, roll back and uninstall as described in
[docs/OPERATIONS.md](../docs/OPERATIONS.md): its
[installed layout](../docs/OPERATIONS.md#installed-layout),
[deploy and roll back](../docs/OPERATIONS.md#deploy-and-roll-back),
[pairing a client](../docs/OPERATIONS.md#pairing-a-client) and
[uninstall](../docs/OPERATIONS.md#uninstall) sections apply to any host,
not only pup.
