# TODO — deferred work

Deferred, unfinished work only ([AGENTS.md](AGENTS.md)). Current work and
live state: [HANDOFF.md](HANDOFF.md).

## Security and pairing

- **Enforce pairing (owner ruling: before 1.0).** The standing conf does
  not pass `--require-paired`, so any client that knows the host's public
  key gets a full session, and `--pair` admits the connecting client to a
  full session before it pairs. Wanted: require-paired by default, and a
  pairing arm inside the running service (a signal or control socket that
  mints a PIN) instead of stop, hand-run, restart.
- **Noise send counter.** The transport's send side keeps a u16 seq API, so
  a forward jump of more than half the space cannot be told from a
  backwards seal. A real fix moves seq allocation into the transport and
  widens the send counter to u64.

## Host

- **Wayland clipboard leaf (blocked on GNOME).** The host clipboard still
  needs the Mutter RemoteDesktop session bus (`MutterClipboardLeaf`). On
  pup (GNOME 50.1) there is no `wlr-data-control`/`ext-data-control`,
  `wl-copy`/`wl-paste` hang, and the portal Clipboard cannot start
  headless. Unlock conditions:
  [record](docs/decisions/20260807-015743-wayland-clipboard-gnome-blocker.md).
- **VAAPI `MaxFrameSize`.** The encoder's HRD buffer is bounded by the
  protectable ceiling; `VAEncMiscParameterTypeMaxFrameSize` was not added
  because it can trigger multi-pass encodes and is unproven on iHD. Tune
  live.
- **Host clipboard hashing.** The host still hashes whole clipboard images
  (`HostWire/Session.swift`). Adopt Wire's incremental
  `ingest(_:book:hasher:)` and lazy `shareLocalImage(_:sha256:)` as the
  client did, then delete Wire's eager and whole-blob overloads.
- **One session lock.** `SessionWire` guards `Session` and the outbox with
  one lock. Direction: a single-owner sender thread that alone touches
  `Session`, with capture, audio and shell work posted through mailboxes.
- **Handshake witness per session.** Each session re-creates, and so
  truncates, the `LYTE_HANDSHAKE_WITNESS_JSONL` file. Append if a
  multi-session witness is wanted.

## Client

- **Finish moving pure policy into `LyteClientCore`.** `AudioJitterBuffer`,
  `SeqGapTracker`, `ChromaTier` and `HevcSpsChroma` stay in `LyteTransport`
  because `LyteClientCore` may import nothing; allow `LyteCore` and
  `LyteWire` there (in `SansIOArchitectureTests` and the manifest), then
  move them with their tests.
- **Refused bulk sends.** `ConnectionModel` drops a refused chan-8 send with
  `try?`; surface it as a transfer notice.
- **Test seams.** Make `UdpReceiveEndpoint`'s 100 ms `SO_RCVTIMEO` an init
  parameter and inject the clock into `CoalescedMainActorHop`, so their
  tests stop sleeping in real time.

## Wire

- Move every codec onto `WireReader` with one reader error; only the
  vectors guard which error wins, so migrate codec by codec.
- Convert `AudioFramer` and `AudioDepacketizer` to structs (source-breaking
  for `let` holders in Host, Client and Browser).
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
