# Operations

The reference rig, the host's installed layout, deploy and rollback, and the
safety runbook. Fresh-machine installation is in
[`Host/INSTALL.md`](../Host/INSTALL.md); facts that change from day to day
(addresses in use, the deployed version) are in
[`HANDOFF.md`](../HANDOFF.md).

## The rig

| Machine | Role | Facts |
|---|---|---|
| `pup` | Linux reference host | Ubuntu 26.04; Intel Meteor Lake GPU drives the panel (Direct Eye and VAAPI run there); RTX 4050 with no attached connectors. Wired `10.0.0.232` on `enxf8e43b7ede7c`, Wi-Fi `10.0.0.249`. Swift 6.1.2 at `/usr/local/bin/swift`. `ssh pup`. |
| the Mac | client and development machine | Xcode, the signing identity, `.build/Lyte.app` (the owner's interactive app) |

The standing host is `lyte-host.service` on UDP **41151**, advertised over
mDNS on the interface named by `--advertise-interface` in its `host.conf`.
When that interface is down, discovery finds nothing. `Lyte.app` finds
hosts only through mDNS (it has no manual address entry), so point
`--advertise-interface` at a live interface and restart the service —
while pup is Wi-Fi only that is `wlp0s20f3`:

```sh
ssh pup "sed -i 's/--advertise-interface [^ ]*/--advertise-interface wlp0s20f3/' ~/.config/lyte/host.conf && sudo systemctl restart lyte-host"
```

`lyte-cli wire-view --host <address> --host-port 41151 --host-key <key>`
dials an address directly without discovery.

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

`lyte-host --wire-listen` without `--seconds` is a service: it serves
sessions in turn in one process, and its PID stays the same across
sessions. A failed session or a display mode change exits the process and
systemd restarts it. `--seconds N` or `--pair` serves one session.

## Deploy and roll back

Run as the seat user in the host tree on pup (`~/src/lyte-host`), after a
release build:

```sh
cd ~/src/lyte-host                          # the Host package on pup (Host/ in the repo)
./Scripts/deploy-host.sh --restart            # copy to versions/<id>, flip the link, restart
./Scripts/deploy-host.sh --status             # active and previous version, sha256 check
./Scripts/deploy-host.sh --rollback --restart # flip back (a second rollback undoes the first)
```

A deploy never rewrites a version in place, and redeploying the active
binary is a no-op. The newest five versions (`--keep N`) plus the active
and previous ones are kept. Without `--restart` the running process keeps
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
then pair from the Mac with the CLI, which writes the same pinned-host
store and Keychain identity the app uses:

```sh
lyte-cli wire-pair <address> --port 41151 --pin <PIN> --host-key <host key>
```

The client leaves as soon as the PIN exchange completes; the `--pair` host
then exits cleanly on its own. Afterwards remove the capability and start
the service as above.

The standing conf does not pass `--require-paired`, so the service admits
any client that knows the host's public key (deferred: [TODO.md](../TODO.md)).

## Safety

These rules protect the owner's live rig. They are repository law
([AGENTS.md](../AGENTS.md#safety)); this is the operational detail.

- **Identity.** Never modify or delete `~/.config/lyte/noise_static.key`,
  `~/.config/lyte/paired_clients` or `~/.config/lyte/host.conf` on pup.
  Record their SHA-256 before and verify after any run that comes near
  identity state; the pup gate does this automatically. Losing the key
  unpairs every client, with no undo.
- **The standing port.** Never displace UDP 41151. Test hosts take a fresh
  41xxx port and `--no-advertise`. `lyte-host` binds with `SO_REUSEPORT`,
  so a second process on 41151 would silently share traffic rather than
  fail.
- **One Direct Eye.** Do not start a second Direct Eye (`lyte-host`,
  `lyte-eye`) while the service holds the DRM seat: parallel eyes black the
  interactive screen. `lyte-control-peer` has no eye and is safe beside the
  service.
- **Accepted risk: ambient `CAP_SYS_ADMIN` on a user-writable path.** The
  unit runs `~/.local/bin/lyte-host` — a symlink the seat user owns, into
  `~/.local/share/lyte/versions/`, which the seat user also owns — with
  ambient `CAP_SYS_ADMIN` and `Restart=always`, and `host.conf` (also the
  user's) supplies its arguments. Any code running as the seat user can
  re-point the symlink or rewrite a version, kill the host (signals are
  permitted by UID), and systemd re-executes the planted binary with
  `CAP_SYS_ADMIN`, which is effectively root. The owner accepts this for
  now; the pre-1.0 hardening (a root-owned executable, or file capabilities
  on a root-owned copy) is in [TODO.md](../TODO.md). Treat the seat
  account as root-equivalent on a host running the service.
- **Hand-run binaries.** Keep them under the home build tree, not `/tmp`
  (`nosuid` strips file capabilities), `setcap cap_sys_admin+ep` the exact
  binary, and remove the capability afterwards.
- **netem.** Use only `Scripts/netem/port-netem.sh`, which shapes one
  `(source port, destination /32)` flow and removes only the qdisc it
  installed. `Scripts/benchmark-netem.sh` arms cleanup before the apply,
  refuses to run if its qdisc is already present, and refuses a port that
  `lyte-host.service` does not own; 41151 additionally needs
  `LYTE_BENCHMARK_ALLOW_STANDING_PORT=1`.
- **Benchmarks.** Do not launch `Scripts/benchmark-app.sh` while the
  owner's `Lyte.app` is open: both use the bundle identity
  `dev.shreeve.lyte`, and a benchmark launch can replace the interactive
  client. Live benchmarks and netem runs need the owner's go-ahead.
- **The pup gate** (`Scripts/CI/test-all-pup.sh`) builds in
  `~/src/lyte-gates/deterministic/` and never deploys or restarts the
  service.

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

Neither touches identity at either location.
