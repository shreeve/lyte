# TODO — deferred work

Deferred, unfinished work only ([AGENTS.md](AGENTS.md)). Current work and
live state: [HANDOFF.md](HANDOFF.md).

## Security and pairing

- **Enforce pairing (owner: before 1.0).** The standing conf does not pass
  `--require-paired`, so any client that knows the host's public key gets a
  full session, and `--pair` admits the connecting client before it pairs.
  Wanted: require-paired by default, and a pairing arm inside the running
  service (a signal or control socket that mints a PIN) instead of stop,
  hand-run, restart.
- **Root-owned executable and knobs under ambient `CAP_SYS_ADMIN` (before
  1.0).** The unit (`Host/Systemd/lyte-host.service`) execs the seat
  user's `~/.local/bin/lyte-host` with ambient `CAP_SYS_ADMIN` and
  `Restart=always`, so seat-user code can plant a binary and have it
  re-executed with the capability
  ([OPERATIONS](docs/OPERATIONS.md#safety)). A root-owned binary alone does
  not close this: `EnvironmentFile=` is the seat user's
  `~/.config/lyte/host.conf`, which can set `LD_PRELOAD` or
  `LD_LIBRARY_PATH` for `/bin/sh` and `lyte-host`, and ambient
  capabilities do not set `AT_SECURE`, so the loader honors them under
  `CAP_SYS_ADMIN`. Wanted: `deploy-host.sh` installs root-owned versions
  and the unit execs a root-owned link (or `setcap` on a root-owned copy);
  the knobs move to a root-owned file (for example `/etc/lyte/host.conf`),
  or `lyte-host` reads its own arguments file and `EnvironmentFile=` goes.
  The unquoted `$$LYTE_HOST_ARGS` in `ExecStart` is also glob-expanded by
  `sh`: add `set -f`, or exec `lyte-host` without a shell.
- **Helper registration residual (Mac).** Before `SMAppService`
  registration the app validates the embedded `lyte-helperd` against its
  own designated requirement
  ([MACOS-SIGNING](docs/MACOS-SIGNING.md#registration)), but same-user code
  that can sign with the owner's development identity (which signs without
  a prompt) still passes, and a window remains between validation and
  `register()`. A root-owned install under `/Applications` closes both.
- **Secure event input while streaming (owner call).** The stream window
  never calls `EnableSecureEventInput`, so keystrokes typed into remote
  password prompts are visible to other processes' event taps. Enabling
  it while the window is key (and balancing it on resign and stop) also
  blocks password-manager autotype system-wide while streaming.
- **Noise message-1 freshness (wire-v2 decision).** A captured message 1
  replayed in a later host run can open one unconfirmed handshake per run —
  a delay for a dialing client, not a lockout. A timestamp in the message-1
  payload retires it.
- **Noise u64 send counter.** The send side keeps a u16 seq API, so a
  forward jump of more than half the space cannot be told from a backwards
  seal. Move seq allocation into the transport and widen the counter.

## Host

- **Wayland clipboard leaf (blocked on GNOME).** The host clipboard still
  needs the Mutter RemoteDesktop session bus (`MutterClipboardLeaf`); pup's
  GNOME 50.1 offers no data-control protocol and the portal Clipboard
  cannot start headless. Unlock conditions:
  [record](docs/decisions/20260807-015743-wayland-clipboard-gnome-blocker.md).
- **VAAPI `MaxFrameSize`.** The HRD buffer is bounded by the protectable
  ceiling; `VAEncMiscParameterTypeMaxFrameSize` can trigger multi-pass
  encodes and is unproven on iHD. Tune live.
- **One session lock.** `SessionWire` guards `Session` and the outbox with
  one priority-inheriting lock. Direction: a single-owner sender thread
  that alone touches `Session`, with capture, audio and shell work posted
  through mailboxes.
- **Listener-scoped handshake admission.** `HandshakeGate` lives inside
  each `HostWire.Session`, so its token bucket, flood detector and
  admitted-cookie ring reset whenever `SessionWire` makes a new awaiting
  session (after each served client, after an unconfirmed discard).
  Admission is a listener concept: move the gate, the initiation parse and
  the superseding logic into a `HandshakeAcceptor` in `HostSession`, owned
  by `SessionWire` for the process, which hands `Session` an authenticated
  `NoiseSession` and its tuple. That deletes `Session`'s pre-handshake
  branch (the `phase == .established` checks at 11 sites) and the
  duplicated 0x05/0x14 parse.
- **RS parity after the data shards.** `Session.prepareVideoFrame` computes
  a frame's whole RS parity before any shard can leave, though the code is
  systematic and data shards are plain slices of the Annex-B: about 41 µs
  at 100 KB and 190 µs at 240 KB ahead of the first data byte. Wanted:
  data shards enter the pacer first and parity follows, which needs
  not-ready parity tokens in the pacer (seqs stay contiguous in
  shard-index order, so wire bytes are unchanged), an off-lock parity
  phase, and repair enqueue deferred while a frame's parity is pending.
- **Opening-IDR repair exemption after loss.** `SessionRepairBudgetBook`
  takes client glass evidence only from a feedback block whose cumulative
  chan-2 `missing` is 0, which never holds again after any loss, so the
  opening exemption stays open for every later IDR until its cap
  (`openingRepairMaxAttempts` 4, `openingRepairMaxBytes` 2 MiB) is spent.
  Difference the counters from the opening IDR's send point instead.
- **DRM card discovery.** `lyte-host` captures `/dev/dri/card1` unless
  `--drm-device PATH` names another card (the render node follows the
  card); pup works because simpledrm takes card0. Wanted: pick the card
  whose primary plane is active, so a host without simpledrm or with
  several GPUs needs no flag.
- **Absolute pointer pixel centre.** `lyte_uinput_move_abs`
  (`Host/Sources/CInputUinput/uinput.c`) truncates `x / width * 65535`, so
  each pixel maps back about 0.03 px short and roughly half the pixels
  hit-test one pixel up or left. Mapping the centre
  (`lround((x + 0.5) / width * 65535)`) should fix it, but libinput's
  rounding must be verified live on the host first; `lyte-uinput-check`
  pins the current scale and changes with it.
- **Delete `--wire-out` (owner go-ahead).** `lyte-host --wire-out
  HOST:PORT` has no user in the repository (no script, doc, test or client
  mode), accepts only IPv4 literals, and carries its own peer filter,
  kernel-port listener branch and 120 s timeout. Without it
  `SessionWire.init` always takes a `HostListener`.
- **Handshake witness per session.** Each session re-creates, and so
  truncates, the host's `LYTE_HANDSHAKE_WITNESS_JSONL` file. Append if a
  multi-session witness is wanted.

## Client

- **Native IDR that trips a flush.** `VideoRendererHandoff.accept()` fails
  the episode and requests recovery before offering the IDR that tripped
  the flush, which may send one extra recovery request. The browser
  playout already answers the flush with that IDR.
- **⌘ chords in a stream (owner decision).** ⌘C, ⌘V, ⌘X, ⌘Z, ⌘⇧Z and ⌘A
  do nothing today: SwiftUI's Edit menu claims them as local shortcuts
  (`LyteInputCapture.isLocalShortcut`), and the video view implements none
  of those actions. Options: drop the pasteboard and undo command groups
  so they reach the host as Super+key (GNOME binds Super+V and Super+A);
  translate ⌘→Ctrl for exactly those chords (a terminal's Ctrl+C then
  interrupts); or translate only while clipboard sharing is on.
- **Manual host entry.** `Lyte.app` lists only hosts mDNS advertises now
  (`ConnectView`), so a paired host on a routed or mDNS-less network is
  unreachable from the UI although its pin stores the address and port.
  Wanted: unsighted pinned hosts as "last seen at address:port" rows that
  dial the pinned address, and a typed address for a first connect.
- **Pairing teardown.** The pairing client (`LytePairing.run` in
  `LyteTransport/LytePairingSession.swift`, behind the app's PIN sheet and
  `lyte-cli wire-pair`) ends without a typed 0x0A teardown, so the host
  learns it left only when its path goes silent (about a second for a
  `--pair` host). Send `shuttingDown` once the PIN exchange completes.
- **Audio books on a quiet LAN session.** A 30 s `lyte-cli wire-view
  --audio` against pup reports about 17k underrun frames, 3 recenters
  and a jitter-buffer skew pinned at +500 ppm, identically against the
  pre-revamp host, so the cause is client-side (`AudioJitterBuffer`,
  `AudioReceiver`, `LyteAudioPlayer`). Find why the skew sits at its
  clamp and whether the underruns are start-up only.
- **One home for the detector numbers.** The browser repeats the native
  2.5 s / 350 ms blackout-detector values from `LyteUdpSessionTypes`;
  name them once in `LyteClientSession`.
- **Media keys.** The browser forwards media volume keys and the native
  client drops them; pick one behavior for both shells.

## Wire

- Add a capability-spine vector for key 14 (`audioStreamOff`), in a new
  file.
- **Unknown teardown reasons (wire v2).** An unknown
  `SessionTeardownReason` fails the whole 0x0A decode
  (`lifecycle-v1.json` pins the refusal), so an older client ignores a
  newer host's teardown and waits out the 30 s liveness timeout. In a new
  vector file, decode an unknown reason as `shuttingDown`.

## Browser

- **Daily-driver browser client.** The Chrome proof runs against
  `lyte-control-peer` with corpus video. The peer still widens its
  blackout detector to 30 s for corpus runs; now that the browser sends
  feedback, run it on the default lifecycle so the smoke proves more.
  Remaining: live Direct Eye against
  the standing host, a persistent interactive session, Safari, real host
  clipboard where the platform allows it, and product composition
  (`LyteBrowserApp`). Do not scaffold empty `Applications/` stubs before
  composition earns them.
- **Gate the browser core on pup.** pup's Swift 6.1.2 cannot resolve
  JavaScriptKit's 6.2 manifest, so the pup gate mirrors only Browser's
  manifest and `Sources/` (for Common's lints) and tests nothing there.
  Upgrade pup's toolchain, or keep only `LyteClientBrowserCore`
  and its suite off macOS in `Browser/Package.swift` (as Client's manifest
  does), then mirror Browser and add `run_package_tests Browser` to
  `Scripts/CI/test-all-pup.sh`.

## Gates

- **SystemTests on the exported host kit.** `SystemHostSession` and the
  NACK gate harness in `SystemTests/` hand-roll what the exported
  `HostWireTestKit.HostSessionHarness` provides; move them onto it.
- **Source size.** The second revamp pass grew hand-written source by
  about 3.4k lines (new behavior and safeguards). A behavior-preserving
  shrink pass, like the first revamp's, should start with
  `LyteClientSession`, `Lyte` (app), `lyte-host` and `HostWire`.
- **Enforce the gates.** No hosted CI runs them, so "always green" rests
  on whoever lands a PR running `Scripts/CI/test-all-macos.sh` and
  `test-all-pup.sh` by hand. A self-hosted runner on pup (Linux leg) plus
  the owner's Mac (macOS leg), or a pre-merge hook, would make it a check.
- Add a release-mode leg (`-c release`) for the Wire property tests and
  the corpus gates, run `LYTE_ARQ_TRIALS=25000` in a pre-merge or pup
  gate, and add an optional `LYTE_HARDWARE_TESTS=1` leg on the owner's
  Mac.
- Finish splitting `Scripts/benchmark-app.sh` (handshake and fresh-host
  libraries, one JSON provenance updater, a protected-state fingerprint
  shared with the pup gate).
- **netem reordering (owner decision).** `Scripts/netem/port-netem.sh`
  applies `delay 20ms 10ms` with no rate or distribution, so netem reorders
  packets freely under jitter and the moderate SLO is judged against more
  reordering than real paths show. Keep it and say so, or add a rate or
  distribution that preserves order.

## Product

- **Posture refinements:** an Opus DTX warm rung, DSP fades, and the 2–5 s
  instant-replay ring remain demand-gated. The video cushion stays
  automatic under the Conductor; it is not deferred UI work.
- **Conductor floor-based stretch.** A variant that stretches when every
  part in the window holds less than the floor reserve measured 0 % late
  frames at every tested skew and jitter, at about half a beat of extra cue
  under positive skew; it fails `testEveryFreshFramePresentsOnTheBeatGrid`.
  Owner decision.
- **Printing:** receive a host print job as PDF and hand it to the client's
  native print flow, with its own negotiated capability and consent.
- **Native role shells:** the macOS host role, then Windows host and
  client and Linux client shells, around the shared sans-IO cores.
