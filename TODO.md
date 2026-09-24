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
- **Run a root-owned binary instead of a user-writable path under ambient
  `CAP_SYS_ADMIN` (before 1.0).** The unit execs the seat user's
  `~/.local/bin/lyte-host` with ambient `CAP_SYS_ADMIN` and
  `Restart=always`, so seat-user code can plant a binary and have it
  re-executed with the capability ([OPERATIONS](docs/OPERATIONS.md#safety)).
  Wanted: `deploy-host.sh` installs root-owned versions and the unit execs
  a root-owned link (or `setcap` on a root-owned copy); `host.conf` never
  chooses the executable.
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
  one lock. Direction: a single-owner sender thread that alone touches
  `Session`, with capture, audio and shell work posted through mailboxes.
- **Handshake witness per session.** Each session re-creates, and so
  truncates, the `LYTE_HANDSHAKE_WITNESS_JSONL` file. Append if a
  multi-session witness is wanted.

## Client

- **Native IDR that trips a flush.** `VideoRendererHandoff.accept()` fails
  the episode and requests recovery before offering the IDR that tripped
  the flush, which may send one extra recovery request. The browser
  playout already answers the flush with that IDR.

## Wire

- Give `SessionStateMachine`'s `.finalFrameAcknowledged` a group id so a
  stale acknowledgement cannot flip the session to IDLE.
- Add a capability-spine vector for key 14 (`audioStreamOff`), in a new
  file.

## Browser

- **Daily-driver browser client.** The Chrome proof runs against
  `lyte-control-peer` with corpus video. Remaining: live Direct Eye against
  the standing host, a persistent interactive session, Safari, real host
  clipboard where the platform allows it, and product composition
  (`LyteBrowserApp`). Do not scaffold empty `Applications/` stubs before
  composition earns them.
- **Gate the browser core on pup.** pup's Swift 6.1.2 cannot resolve
  JavaScriptKit's 6.2 manifest. Upgrade pup's toolchain, or omit the
  JavaScriptKit dependency and executable on Linux in `Browser/Package.swift`,
  then add `run_package_tests "Browser"` to `Scripts/CI/test-all-pup.sh`.

## Gates

- Add a release-mode leg (`-c release`) for the Wire property tests and
  the corpus gates, run `LYTE_ARQ_TRIALS=25000` in a pre-merge or pup
  gate, and add an optional `LYTE_HARDWARE_TESTS=1` leg on the owner's
  Mac.
- Finish splitting `Scripts/benchmark-app.sh` (handshake and fresh-host
  libraries, one JSON provenance updater, a protected-state fingerprint
  shared with the pup gate).

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
