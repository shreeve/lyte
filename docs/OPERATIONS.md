# Operations

The reference rig, the host's installed layout, deploy and rollback,
pairing, uninstall, and the safety runbook. Everything after the rig
section applies to any installed host. Fresh-machine installation is in
[`Host/INSTALL.md`](../Host/INSTALL.md); facts that change from day to day
(the interface in use, the deployed version) are in
[`HANDOFF.md`](../HANDOFF.md).

## The rig

| Machine | Role | Facts |
|---|---|---|
| `pup` | Linux reference host | Ubuntu 26.04; Intel Meteor Lake GPU drives the panel (Direct Eye and VAAPI run there); RTX 4050 with no attached connectors. Wi-Fi only: `10.0.0.249` on `wlp0s20f3`, where the service advertises (the wired leg, `10.0.0.232` on `enxf8e43b7ede7c`, is absent). Swift 6.1.2 at `/usr/local/bin/swift`. `ssh pup`. |
| the Mac | client and development machine | Xcode, the signing identity, `.build/Lyte.app` (the owner's interactive app) |

The standing host is `lyte-host.service` on UDP **41151**, advertised over
mDNS on the interface named by `--advertise-interface` in its `host.conf`.
When that interface is down, discovery finds nothing: `Lyte.app` still
lists a paired host as "last seen at address:port" and dials that pinned
address, but an unpaired host is reachable only by mDNS or `lyte-cli`.
Point `--advertise-interface` at a live interface and restart the
service:

```sh
ssh pup "sed -i 's/--advertise-interface [^ ]*/--advertise-interface <iface>/' ~/.config/lyte/host.conf && sudo systemctl restart lyte-host"
```

`lyte-cli wire-view 0 --host <address> --host-port 41151 --host-key <key>`
dials an address directly without discovery (`0` binds a free local port).
The key is the 64-hex-digit line `noise: host static public key …` that
`lyte-host` logs at start; once paired, `--host-key` can be omitted.

**Agents on the Mac:** a sandboxed agent shell cannot reach pup: `ssh pup`
fails with `No route to host` because macOS Local Network privacy blocks
the sandbox, not the network. Run ssh, rsync and the pup gate outside the
sandbox.

## Build on pup

The Host manifest references `../Wire` and `../Common`, so the three
packages are synced as siblings:

```sh
rsync -a --delete --exclude .build Wire/   pup:src/Wire/
rsync -a --delete --exclude .build Common/ pup:src/Common/
rsync -a --delete --exclude .build Host/   pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build -c release -Xswiftc -warnings-as-errors'
```

The `LD_LIBRARY_PATH` shim exists only for Swift 6.1.2's build tools, which
want `libxml2.so.2` where Ubuntu 26.04 ships `.so.16`:

```sh
mkdir -p ~/.local/lib/swift-compat
ln -sf /usr/lib/x86_64-linux-gnu/libxml2.so.16 ~/.local/lib/swift-compat/libxml2.so.2
```

It is not a product dependency. No media-library environment exists: Opus
is built from Common's pinned source, and the pup gate fails if `lyte-host`
links libav. The standing service always runs a release build.

## Installed layout

The service runs as the seat user from XDG directories
(`XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `XDG_DATA_HOME` move them when set
to absolute paths; the installer writes the resolved paths into the unit).

| What | Path |
|---|---|
| Knobs (`LYTE_HOST_ARGS` only) | `~/.config/lyte/host.conf` |
| Identity | `~/.config/lyte/noise_static.key`, `~/.config/lyte/paired_clients` (0600, directory 0700) |
| Executable the unit runs | `~/.local/bin/lyte-host` → `~/.local/share/lyte/versions/<sha256-12>/lyte-host` |
| Deploy bookkeeping | `~/.local/share/lyte/previous` |
| Legal payload | `~/.local/share/lyte/doc/` |
| Audio crash ledger | `~/.local/state/lyte/audio_default_sink.prev` |
| Log | `~/.local/state/lyte/host.log` (0600); over 64 MiB it moves to `host.log.1` at the next start, and the running host moves its own output the same way at every session boundary and once a minute |
| Unit | `/etc/systemd/system/lyte-host.service` (system unit with `User=`, ambient `CAP_SYS_ADMIN`, `Restart=always`) |

The host mints its identity on first run; it survives deploys, reinstalls
and uninstalls. The service serves sessions in turn in one process
([service loop](ARCHITECTURE.md#host-linux)).

## Deploy and roll back

Run as the seat user in the Host package (`Host/` in a checkout,
`~/src/lyte-host` on pup), after a release build:

```sh
cd ~/src/lyte-host                          # or Host/ in a checkout
./Scripts/deploy-host.sh --restart            # copy to versions/<id>, flip the link, restart
./Scripts/deploy-host.sh --status             # active and previous version, sha256 check
./Scripts/deploy-host.sh --rollback --restart # flip back (a second rollback undoes the first)
```

A deploy copies `.build/release/lyte-host` (and `lyte-audio-check` when
built) into `versions/<first 12 hex of its sha256>/` and swaps
`~/.local/bin/lyte-host` in one rename; it never rewrites a version in
place, and redeploying the active binary is a no-op. The newest five
versions (`--keep N`) plus the active and previous ones are kept.
`--restart` runs `sudo -n systemctl restart lyte-host`, so it needs
passwordless sudo for that command; without it the running process keeps
its open executable until the next restart.

Verify a restart:

```sh
systemctl is-active lyte-host
pid=$(systemctl show lyte-host -p MainPID --value)
sudo readlink /proc/$pid/exe            # …/versions/<id>/lyte-host
sudo grep CapAmb /proc/$pid/status      # 0000000000200000 (CAP_SYS_ADMIN)
tail -40 ~/.local/state/lyte/host.log   # "noise: awaiting client handshake on port 41151"
```

To change flags, edit `~/.config/lyte/host.conf` and restart. Unit
lifecycle lines are in `sudo journalctl -u lyte-host`.

## Pairing a client

Pairing needs a one-session host that prints the PIN, so the service is
stopped for the duration:

```sh
sudo systemctl stop lyte-host
bin="$(readlink -f ~/.local/bin/lyte-host)"
sudo setcap cap_sys_admin+ep "$bin"        # hand-run only; the unit grants it ambiently
"$bin" --wire-listen 41151 --pair          # prints the PIN; enter it on the client
sudo setcap -r "$bin"
sudo systemctl start lyte-host
```

Pairing without a person at the client: run the `--pair` host in the
background (`nohup … </dev/null > ~/lyte-pair.log 2>&1 &` — without the
stdin redirect the ssh session never returns), read the PIN from its log,
then pair from the Mac with the signed CLI (`Scripts/build-cli.sh`), which
writes the same pinned-host store and Keychain identity the app uses:

```sh
.build/debug/lyte-cli wire-pair <address> --port 41151 --pin - --host-key <host key>   # PIN on stdin
```

The client sends a `shuttingDown` teardown as soon as the PIN exchange
completes, and the `--pair` host exits on it. Afterwards remove the
capability and start the service as above.

The standing conf does not pass `--require-paired`, so the service admits
any client that knows the host's public key (deferred: [TODO.md](../TODO.md)).

## Safety

The rules are repository law ([AGENTS.md](../AGENTS.md#safety)); this is
why they hold and how the tools enforce them.

- **Identity.** Losing `~/.config/lyte/noise_static.key` unpairs every
  client, with no undo. The pup gate and the benchmark's handshake leg
  fingerprint the identity, `host.conf`, `/etc/lyte/lyte-host.conf`, the
  pre-XDG copies, the unit and the deployed link before and after
  (`Scripts/lib/pup-side.sh`) and fail on any change or unreadable file;
  a handshake leg that dies after its restart re-checks on the way out.
- **The standing port.** A listener on a port another socket holds
  refuses to start, so a stray host on 41151 fails rather than sharing the
  service's traffic.
- **One Direct Eye.** A second eye on the DRM seat (a hand-run
  `lyte-host`) blacks the interactive screen. `lyte-control-peer` has no
  eye and is safe beside the service.
- **Hand-run binaries.** `/tmp` is mounted `nosuid`, which strips file
  capabilities, so a hand-run host lives under the home build tree.
- **Ambient `CAP_SYS_ADMIN` (accepted risk).** The unit runs a seat-user
  symlink into seat-user-owned versions, with arguments from the user's
  `host.conf`, ambient `CAP_SYS_ADMIN` and `Restart=always`; treat the seat
  account as root-equivalent on a host running the service. The analysis
  and the pre-1.0 hardening are in [TODO.md](../TODO.md).
- **netem.** `Scripts/netem/port-netem.sh` shapes one `(source port,
  destination /32)` flow and removes only the qdisc it installed.
  `Scripts/benchmark-netem.sh` arms cleanup before the apply, refuses to
  run if its qdisc is already present, and refuses a port that
  `lyte-host.service` does not own; 41151 additionally needs
  `LYTE_BENCHMARK_ALLOW_STANDING_PORT=1`.
- **Benchmarks.** `Scripts/benchmark-app.sh` publishes its diagnostic
  build to the owner's `.build/Lyte.app` under the same bundle identity,
  refuses to start while any Lyte process runs, and restores the plain
  app when it exits ([TESTING.md](TESTING.md#live-benchmarks-pup)). Its
  `handshake-only` leg restarts the standing service.
- **The pup gate** builds in `~/src/lyte-gates/deterministic/` and never
  deploys or restarts the service.

## Pre-XDG leftovers

Hosts installed before the XDG layout may still hold these. `lyte-host`
never writes them, and an identity file missing from `~/.config/lyte/` is
copied from `~/.config/lyte-host/` once (0600, verified byte-for-byte).

| Path | What it was | Removal |
|---|---|---|
| `~/.config/lyte-host/{noise_static.key,paired_clients}` | pre-XDG identity, kept as a read-only backup | owner's decision; the pup gate verifies it unchanged while present and tolerates its absence |
| `/etc/lyte/lyte-host.conf` | pre-XDG knob file | `sudo rm /etc/lyte/lyte-host.conf && sudo rmdir /etc/lyte` |
| `/usr/local/bin/lyte-host` | pre-XDG installed binary | `sudo rm /usr/local/bin/lyte-host` |
| `/tmp/lyte-host-session.log` | pre-XDG log (world-readable) | `rm -f /tmp/lyte-host-session.log` |
| `~/.config/lyte-host/portal_token` | portal-era state, unused since the portal was removed | owner's decision |

Agents never delete these; the owner removes them by hand.
`Host/Scripts/setup-host.sh` lists the ones it finds with the exact command.

## Uninstall

```sh
Host/Scripts/uninstall-host.sh          # unit, link, versions, legal payload; keeps host.conf
Host/Scripts/uninstall-host.sh --purge  # also host.conf and the logs
```

Neither touches identity at either location; remove it by hand only to
unpair every client (there is no undo).
