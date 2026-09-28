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
- **Password-free sudo on pup.** The host now runs a root-owned binary
  with root-owned knobs, but pup's seat user has `NOPASSWD: ALL`, so any
  code running as that user is root anyway. Narrow it (for example to
  `systemctl restart lyte-host` and the deploy's `install`/`ln`/`mv` under
  `/usr/local/lib/lyte`) or require a password before 1.0 (owner).
- **Helper registration residual (Mac).** Before `SMAppService`
  registration the app validates the embedded `lyte-helperd` against its
  own designated requirement
  ([MACOS-SIGNING](docs/MACOS-SIGNING.md#registration)), but same-user code
  that can sign with the owner's development identity (which signs without
  a prompt) still passes, and a window remains between validation and
  `register()`. A root-owned install under `/Applications` closes both.
- **Sign the update feed (next release).** `Scripts/release.sh` signs
  each enclosure (`sparkle:edSignature`) but publishes an unsigned
  `appcast.xml`. Sign the feed itself (`generate_appcast` with the `lyte`
  EdDSA key), verify the published feed carries its signature, and only
  then add `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` to
  `SPARKLE_KEYS` in `Scripts/make-app.sh` for the following release: a
  bundle that requires a signed feed must never meet an unsigned one.
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

## Client

- **Audio target after a wake.** On pup, a sound that starts after a
  quiet (`pw-play`) arrives irregularly at first (captureToFeed p99
  70–90 ms against a steady 25 ms), which lifts the jitter target from 5
  to about 11 packets; it then decays only one step per 10 s, so the
  whole sound plays about 30 ms later than it needs to. Find whether the
  irregularity is PipeWire's graph requantizing on the host or the
  capture leaf, and whether the target should discount the first
  hundred milliseconds after a wake.
- **Pairing sheet for an already-paired key.** A typed address that no
  pin knows asks "Which host is at …?" before offering pairing; the
  pairing sheet could instead offer Connect when the pasted key is
  already paired.

## Wire

- **Unknown teardown reasons (wire v2).** An unknown
  `SessionTeardownReason` fails the whole 0x0A decode
  (`lifecycle-v1.json` pins the refusal), so an older client ignores a
  newer host's teardown and waits out the 30 s liveness timeout. In a new
  vector file, decode an unknown reason as `shuttingDown`.

## Browser

- **Daily-driver browser client.** The Chrome proof runs only against
  `lyte-control-peer` with corpus video, whose blackout detector is
  widened to 30 s. Remaining: a relay to a real host (or WebTransport on
  the host itself), live Direct Eye in Chrome, a persistent interactive
  session, Safari, real host clipboard where the platform allows it, and
  product composition (`LyteBrowserApp`). Do not scaffold empty
  `Applications/` stubs before composition earns them. The page's
  worklet ring (`Browser/Page/audio-ring-worklet.js`) books every silent
  frame as underrun, including before the first audio and under an
  announced quiet (0x25); the native player ring books neither. Carry the
  shared `ClientControlSession.hostAnnouncedAudioQuiet` through the bridge
  and post it to the worklet, which stops booking until its next write.

## Gates

- **Enforce the gates.** No hosted CI runs them, so "always green" rests
  on whoever lands a PR running `Scripts/CI/test-all-macos.sh` and
  `test-all-pup.sh` by hand. A self-hosted runner on pup (Linux leg) plus
  the owner's Mac (macOS leg), or a pre-merge hook, would make it a check.
- **Stale cross-package builds on pup.** Swift 6.1.2 on Linux did not
  recompile Browser after `ClientFeedbackReporter` (Client), which the
  browser core embeds by value, gained a stored property: the pup gate
  failed with garbage values until `swift package clean` in Browser. The
  gate cleans only when a manifest, pin or file list changes
  (`Scripts/lib/build-graph.sh`), so the same staleness could pass a
  broken tree. Clean a package whenever a package it depends on changed
  sources, or key the check on a hash of each dependency's `Sources/`.
- **A video-quality gate with a host encode leg.** The orphaned corpus
  pipeline (`corpus-gen`, `corpus-gate`, `decode-probe`, the text goldens)
  was deleted in `23d329c`; recover it from `23d329c^` if a gate that
  encodes on the host and scores on the client is rebuilt.
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
