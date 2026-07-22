# Lyte — Session Handoff

*Current as of 2026-07-22 ~00:10 MDT. Session scratch; deliberately gitignored.*

## H1 WAVE — LIVE STATUS (updates as slices land)

The opening wave launched 2026-07-21 ~23:15 MDT and its first four slices
are LANDED, GATED, COMMITTED (not pushed):
- **W3 ARQ** (`002cc72`, Wire/): ArqFrames (CTRL 0x07 data / 0x08 ACK,
  self-delimiting, ACK piggybacks), sans-IO ArqEndpoint (send/sendOneShot,
  ingest→events, poll→(datagrams, deadline); group 0 ordered, groups ≥1
  one-shots), RFC 9002-shaped PTO + fast retransmit, replay-proof. Gate
  W-G4 full strength: 165,240 exhaustive interleavings; 1M seeded sim
  trials 0 failures Mac AND Linux; adversarial leg fixed a real
  CTRL-starvation bug (group 0 always admitted). arq-v1.json frozen,
  sha-identical cross-platform. Suites 223/223 both. SimNet (seeded
  impairment injector) added to LyteWireTestKit. In-tree sim runs 25k
  trials; 1M is env-gated. Exhaustive test adds ~12 s to swift test.
- **HS-10 discovery** (`1b499e7`, Host/): Avahi via D-Bus (SessionBus grew
  .system), advertises `_lyte._udp`, TXT `v=1` + `pkh=<sha256 of Noise
  static pubkey>`; default-on for --wire-listen (--no-advertise opts out);
  `lyte-host advertise` standalone. Live-gated via dns-sd from the Mac.
- **CL-10 HostClockModel** (`d16dbc1`, root): min-RTT-gated (±2 ms of
  window min) offset + least-squares skew over 30 s window, sans-IO in
  spirit (no clock reads inside). Live: residual rms ~300–380 µs, max
  <940 µs, spikes gated. Fixed wire-view Int64-through-%d truncation.
- **CL-5 discovery** (`233e403`, root): LyteDiscovery (LyteTransport,
  NWBrowser) browses _lyte._udp, parses v/pkh, pinned-key recognition;
  `lyte-cli wire-discover` + ConnectView dual-browse. Live-gated against
  the host's real advertisement (resolved 10.0.0.249:41003, pkh matched).

- **HS-8 CTRL-over-ARQ** (`830b44e`, Host/): Session owns
  ArqEndpoint<HostClock>; sendReliable/sendReliableOneShot; inbound sealed
  CTRL 0x07/0x08 routed by one-byte peek; deliveries =
  SessionEvent.reliableCtrl/.reliableOneShotAcknowledged. Segment bodies
  clamped to 1093 (real ceiling 1101 with conn-id TLV + tag); poll
  payloads re-cut on over-budget. PTO deadline folded into
  nextWake/advance (idle-floor tick services it). EXEMPT by design:
  beacons, path challenge/response, handshake, IDR requests. Gate: SimNet
  5% loss + dup + reorder, exactly-once in-order both ways; 39/39 Mac AND
  pup. Deferred: capabilities exchange (needs W7), joint beacon-residual
  gate + live netem leg (need CL-7).

- **CL-7 ARQ leg** (`a5a4794`, root): ReliableCtrlEndpoint — the client
  half of HS-8's seam. ArqEndpoint<ClientClock> behind the 0x07/0x08
  one-byte peek in wire-view's CTRL routing; ARQ datagrams sealed via
  TransportSender (grew TLV extensions param), tagged with the conn-id
  LEARNED from the host's TLV (never invented; untagged only in the
  pre-first-beacon window), repacked to the 1101 B real ceiling with
  bodies clamped 1093 at init; PTO on a self-rescheduling timer
  (production) / tick(now:) (tests). Gate 5/5 + suites 67/67: SimNet
  W-G4 storm (5% loss/2% dup/4 ms jitter), exactly-once in-order BOTH
  directions vs a LyteWire host build-up (root can't import HostWire —
  ArqCtrlGateTests runs the mirror pairing), beacons through the peek
  untouched, sealed IDR landing mid-storm, PTO-retransmit-rides-fresh-
  datagram, budget/piggyback/clamp pins. LIVE vs pup :41005 (60 s
  mid-stream, Noise): 30/30 `--arq-ping` reliable messages delivered
  exactly once on the host (Wi-Fi PTO retransmits deduped as routine
  duplicateSegment ignores), ACKs quiesce the client between pings,
  38,072 datagrams ALL ok, 0 unseal failures, **clock residual rms
  362 µs / max 802 µs after 30 s — the joint CL-10/CL-7 <1 ms
  beacon-residual gate, PASSED**. Logs /tmp/cl7-client.log (Mac),
  pup:/tmp/cl7-host.log. Cleanup verified (no lyte-host, 41005 free,
  Sunshine active, token/key shas unchanged). pup rebuilt from
  committed HEAD via git archive (Wire/ working tree was mid-W4b-edit —
  don't rsync the raw tree while that worker runs). Deferred from
  CL-7's full row (blocked on W4b/W6/W7): LyteUdpSession behind
  ConnectionModel, capabilities exchange, reconnect/takeover UX. Known
  benign: host's fixed-duration run dies on recvmmsg ECONNREFUSED when
  the client exits first (Host/ territory).

- **W4b session state machine** (`fd69ee4`, Wire/): SessionStateMachine —
  ACTIVE/IDLE wire modes; FROZEN/RECOVERY local overlay off each end's
  350 ms silence detector (never signaled on the wire); WAKE a transition
  not a state; terminal `closed` added. One machine, two roles
  (mediaSender drives modes/IDR; mediaReceiver mirrors, derives the CL-8
  pill, never enters RECOVERY). Pinned: idle flip waits converged-frame
  one-shot ACK, damage aborts pending flip; pre-arm survives FROZEN,
  consumed exactly once by RECOVERY's halfStaleEstimate IDR; WAKE arms
  next-damage-as-IDR at lastGoodRate; two clean windows graduate
  RECOVERY; beacons feed liveness (30 s teardown) + FROZEN exit but not
  the 350 ms detector. New ARQ-carried CTRL: ModeTransition 0x09,
  SessionTeardown 0x0A (reasons taken-over-by/shutting-down); frozen in
  NEW lifecycle-v1.json (14 vectors; sha 7b81dab0…052a identical on pup).
  Gate W-G5b: ~130-row exhaustive table, property suite, SimNet
  blackout→lossy-recovery→teardown over real ArqEndpoints. Wire suite
  223 → **259/259 Mac AND pup**.

- **W6 CPace PIN-PAKE** (`f6f9358`, Wire/): CPACE-X25519-SHA512 per
  draft-irtf-cfrg-cpace-21, initiator-responder (client = A, host = B;
  o_cat/symmetric + sid_output deliberately not implemented). Elligator 2
  hand-written over new pure-Swift GF(2²⁵⁵−19) (Field25519.swift 5×51
  limbs, Elligator2.swift); X25519/SHA-512 from swift-crypto; import
  Crypto still confined to Crypto/. CTRL 0x0B share A / 0x0C share B+tag
  / 0x0D confirm A / 0x0E typed reject (single confirmation-failed value
  — no oracle), ARQ-carried on the sealed ordered stream. sid = Noise
  handshake hash; CI = lv_cat("lyte-pairing-v1", client static, host
  static) → MITM gets different generators → confirm fails; wrong PIN
  indistinguishable, machine dead after failure, nothing
  offline-testable. PairingResult promotes the session's own statics to
  pinned; reconnects = plain 1-RTT IK. Gate W-G7: draft appendix
  vectors byte-exact BOTH platforms incl. full B.1.10 low-order table;
  composition test with real NoiseSession; pairing-v1.json frozen
  (sha 39ae8719…6135 identical on pup); suites 293/293 Mac AND pup.
  Constant-time caveats documented in-code for the scheduled pre-H1
  Crypto/ review. HS-9/CL-6 own carriage/timers/flood/keystore/UI.

- **W7 capabilities** (`421feef`, Wire/): the superpowers handshake.
  Cbor.swift — hand-rolled RFC 8949 §4.2.1 deterministic profile
  (shortest-form arguments, bytewise-ordered map keys, no floats/tags/
  indefinite lengths; non-canonical REJECTS even when well-formed;
  decode depth cap 8). Capabilities — registry keys 1–8 (wireMinor
  u16 min; videoCodecs [1=HEVC] / chromaModes [1=4:2:0, 2=4:4:4] /
  featureChannels [1 clip, 2 files, 3 print] as ascending id lists,
  set-∩; idleSilence/audioExpress/resume bool AND; maxDatagramBytes
  u32 ≥1152, min). Forward-compat spine: unknown keys ignored +
  preserved verbatim, unknown ids in lists carried not rejected,
  foreign entries survive intersection only on byte-equal agreement —
  algebra commutative/idempotent/associative, property-tested AND
  frozen as data in both argument orders. CTRL 0x0F declaration /
  0x11 update / 0x12 ack (1024 B message cap; ack echoes the proposal
  verbatim). CapabilityNegotiator (sans-IO): intersection IS the
  agreement (no accept round); empty codec/chroma intersection = typed
  failure; renegotiation v1 = maxDatagramBytes ONLY (the DPLPMTUD
  seam), host→client only, one outstanding, bounds [1152, agreed
  ceiling], operative value starts 1152; bad proposal → rejected ack,
  never teardown. NEW capabilities-v1.json (45 vectors; sha
  a326b835…59d2, pup regeneration byte-identical). Gate W-G8: CBOR
  fuzz (2k seeded trees + 5k hostile buffers), unknown-key rule,
  intersect algebra, negotiator end-to-end through its own codecs.
  Wire suite 293 → **336/336 Mac AND pup**. Unblocks HS-8's and
  CL-7's deferred capabilities-exchange legs.

- **HS-9 host pairing** (`4b9e82e` + fixup `7f02972`, Host/):
  PairingResponderService (sans-IO) rides HS-8's .reliableCtrl seam;
  Session grew public `handshakeHash` (§8.2's sid). `--pair` prints 6
  CSPRNG digits on the console (UI is CL-6's). Flood posture: guesses
  counted AT SHARE-B ISSUANCE (0x0C carries Tb — share B IS the online
  guess); 3 burn the PIN to wire silence, reconnect never refills; 1 s
  share-A throttle; HandshakeGate token bucket (10/s burst 10) refuses
  msg1 floods BEFORE Noise allocation. Keystore
  ~/.config/lyte-host/paired_clients (0600, hex-per-line; sans-IO
  ClientKeystore in HostWire, Foundation leaf in lyte-host);
  `--require-paired` feeds the HS-7 allowedClientStaticPublicKeys seam
  (opt-in until CL-6). Gate: Host 53/53 Mac AND pup; FIVE live legs on
  pup :41006 (pair 106 ms; wrong-PIN loud abort; live burn→silence;
  1-RTT paired reconnect 16.7 ms + stranger refused; 500-msg1 flood =
  10 Noise attempts, 0 sessions, honest client paired 524 ms later).
  pup's paired_clients now holds two probe statics (harmless;
  supersede at CL-6). Deferred: stateless retry-cookie (needs a Wire
  codec that doesn't exist yet), joint live pairing with real UI (CL-6).

- **CL-6 client pairing** (`6166b12`, root): the PIN flow end to end.
  PairingInitiatorService (sans-IO mirror of HS-9's responder — wrong
  PIN learned from Tb one message early, answered with typed 0x0E,
  machine dead after; no oracle) + LytePairingSession (one blocking
  call: persistent-static Noise IK → UdpReceiveEndpoint →
  ReliableCtrlEndpoint → the pake; shared by CLI and app sheet).
  Identity storage split by secrecy: client's own X25519 static =
  login-Keychain GENERIC-PASSWORD item (ClientNoiseIdentity —
  SecKeyCreateRandomKey can't mint X25519, so SecItemAdd behind the
  stable "Lyte Dev" signature is the only door; build-cli.sh REQUIRED
  for anything touching it, unit tests never call the Keychain paths);
  pinned host statics = ~/Library/Application Support/Lyte/
  pinned_hosts.json keyed by TXT pkh (browse recognition = dictionary
  lookup). NoiseTransportCrypto grew staticKeys + handshakeHash.
  Surfaces: `lyte-cli wire-pair HOST --port N --pin P --host-key HEX`
  (pasted key hash-checked against the advertised pkh; key optional
  when re-pairing a pinned identity), `wire-unpair`, `wire-view`
  WITHOUT --host-key = the zero-UI 1-RTT reconnect (pinned key +
  Keychain identity; explicit --host-key keeps the throwaway-static
  debug posture), ConnectView pairing sheet (pure SwiftUI, live pkh
  validation) + Paired badge + Unpair context menu. Gate: 5 new tests
  incl. the CPace exchange through the W-G4 SimNet storm over the REAL
  client endpoint stack vs a LyteWire responder build-up; root suite
  67 → **72/72**. LIVE vs pup :41007 (pup's committed-HEAD host
  binary): paired first attempt, handshake 16.1 ms — client static
  357a83cc…cd52 into paired_clients, host static 10e0f084…6201 pinned
  client-side; wrong PIN → tag mismatch → typed reject, exit 1, host
  logged clientAborted, nothing pinned; 1-RTT reconnect under
  --require-paired: 17,587 datagrams ALL ok, layer .rendering, zero
  UI; a throwaway static drew "client static not in the paired set" ×5
  from the same LIVE enforcing host; unpair refuses the dial until
  re-paired (store restored — this Mac remains paired). Cleanup
  verified: no lyte-host, 41007 free, Sunshine active, token/key shas
  unchanged. Logs: /tmp/cl6-pair-mac.log, /tmp/cl6-wrongpin*-mac.log
  (Mac); pup:/tmp/cl6-host-{pair,wrongpin,wrongpin2,reconnect,
  refuse}.log. Known benign again: the host's fixed-duration run dies
  on recvmmsg ECONNREFUSED when the client exits first (Host/
  territory). Deferred (blocked on CL-7's session slice): app-row
  click → live stream (the sheet pins identity only), takeover/
  reconnect UX, ConnectionModel rewiring.

- **W8 retry cookie** (`bca9b8d`, Wire/): HS-9's deferred flood
  hardening — the stateless HMAC retry-cookie codec the core plans
  promised (core plan §5; QUIC Retry's shape). RetryCookie
  (Crypto/): mint(tuple, msg1, now, secret) → 24 bytes = ts u64 LE ‖
  HMAC-SHA256/16 over "lyte-retry-cookie-v1" ‖ ts ‖ tupleLen‖tuple ‖
  msg1; verify(cookie, tuple, msg1, now, secrets[current-first],
  lifetime dflt 30 s) — no per-client state, rotation-tolerant (one
  window), future stamp = forgery, malformed = quiet false (flood
  path never throws), constant-time tag compare + no early exit
  across secrets. CTRL 0x13 RetryChallenge (`type ‖ cookieLen u8 ‖
  cookie` — cookie length-prefixed/opaque so the interior can evolve
  host-side) / 0x14 RetryHandshake1 (‖ verbatim msg1, ≥96 B refused
  pre-cookie-work); both bare pre-transport like 0x05/0x06,
  ARQ-exempt. Gate: MAC anchored vs independent RFC 2104 HMAC over
  TestKit's Sha256; codecs vs hand-built layouts; real IK msg1
  through the full challenge→resubmit→verify→handshake loop. NEW
  retry-v1.json (26 vectors; sha a902805d…90eb7, pup regeneration
  byte-identical). Wire suite 336 → **354/354 Mac AND pup**.
  Deferred (Host/ territory): HandshakeGate's escalation to cookie
  mode — consume the seam as mint(tuple = host's own serialization
  of the source addr, now, secret) on refused msg1s, verify on 0x14
  arrivals BEFORE Noise; secret = 32 B CSPRNG, rotate on the host's
  schedule passing [current, previous]. Client leg (root): answer
  0x13 by resubmitting the SAME msg1 (0443beb's rule makes it free)
  inside 0x14.

- **HS-11 + HS-8 capabilities** (`ceb5176` + fixup `37fc10a`, Host/):
  the host-session lifecycle slice. HostWire.Session runs the W4b
  SessionStateMachine (mediaSender): chan-3 feedback feeds the 350 ms
  blackout detector; every other authenticated arrival feeds
  liveness/FROZEN-exit only; the machine's poll deadline rides
  nextWake/advance. Idle flip: the ratchet's all-skip stop → the final
  converged frame rides a reliable ONE-SHOT as the HOST-PINNED
  **0x15 IdleFrame** (`type ‖ frame u32 ‖ captureMicros u64 ‖
  Annex-B`; PROMOTE to Wire with CL-8; deliberately carried on the
  CTRL endpoint's one-shot groups, NOT chan-4 videoIdle, because
  that's the sublayer today's client already acks — carriage moves at
  CL-8, bytes don't; fixup renumbered 0x13→0x15 after W8 took
  0x13/0x14 mid-slice) → ONLY its full ack flips to IDLE + emits
  ModeTransition 0x09; new damage aborts a pending flip; damage in
  IDLE = WAKE (0x09 active + next-damage-as-IDR via the existing
  takeFreshKeyframeRequest poll). FROZEN suppresses video in-session
  (counted, never thrown); returning evidence → RECOVERY (resume +
  halfStaleEstimate IDR); a 25 ms feedback-window STUB graduates
  RECOVERY until HS-16's estimator owns verdicts. W7 exchange (HS-8's
  deferred item): host declaration 0x0F is the FIRST sendReliable
  post-establishment (insecure mode: first advance); intersection =
  agreement (.capabilitiesAgreed); empty codec/chroma intersection →
  typed 0x0A teardown + close; a declaration-less client (today's
  CL-7) streams unimpeded — capability gating (idleSilence) engages
  only once both ends have spoken. Teardown: beginTeardown → 0x0A on
  the ordered stream, shell lingers ≤500 ms until arqIsQuiescent;
  CNetIO grew `LYTE_NETIO_PEER_GONE (-2)` for ECONNREFUSED (send AND
  recv) → SessionWire closes CLEANLY with full stats — the known
  recvmmsg death is fixed (proven live 4×: early client deaths drew
  ICMP and the host shrugged with a clean summary every time).
  Gate: NEW SessionLifecycleGateTests, 8 legs (first-word
  declaration, intersection in vivo, ack-gated flip byte-exact,
  damage abort, FROZEN/RECOVERY off the real detector, both teardown
  directions, liveness-closes-silently); Host suite 53 → **61/61 Mac
  AND pup** (pup from committed-HEAD archives — Wire/ tree was
  mid-W8). LIVE on pup :41008 (--ratchet, 30 s host / 42 s foreground
  client, run E): **10 full idle cycles** — one-shot acked → `mode: →
  IDLE` → 1 Hz clock-tick damage → `mode: → ACTIVE` + wake IDR
  (10 IDRs = exactly 1/wake); client received all 30 reliable
  messages exactly once, 6902 datagrams ALL ok, 0 unseal failures;
  final teardown 0x0A ACKNOWLEDGED ("clean close"); tcpdump: 28
  video-silence windows >250 ms (idle bounded by pup's top-bar clock
  damage), ZERO video datagrams inside them, beacons/CTRL alive
  (30/30 echoes). Live evidence ran the pre-fixup 0x13 build — no
  ambiguity in practice (retry 0x13 is bare pre-transport; the idle
  frame rides inside the sealed ARQ stream), layout otherwise
  identical. Logs /tmp/hs11e-{host,client}.log on Mac+pup (runs A–D =
  the ECONNREFUSED evidence). Cleanup verified: no lyte-host, 41008
  free, tcpdump killed, Sunshine active, portal_token/noise_static/
  paired_clients shas byte-identical. Deferred: chan-4 videoIdle
  carriage + 0x15 promotion (CL-8), IdrPacing numbers + real window
  verdicts (HS-16), preArmInput caller (HS-13), DPLPMTUD proposer
  (negotiator seam exists, no caller), idle-floor retirement in
  non-ratchet mode, W8 cookie-mode enforcement in HandshakeGate.
  NOTE for CL-8: W4b's pinned WAKE semantics make every post-idle
  damage a full IDR — on a "static" GNOME desktop the 1 Hz clock
  costs one IDR per wake; expect that rhythm until damage-vs-wake
  policy is revisited with data.

IN FLIGHT / NEXT: CL-8 FROZEN pill + idle mirroring (the host now
emits 0x09/0x15 for real), CL-7 capabilities-exchange follow-up (the
client still declares nothing), HS-9 cookie-mode enforcement (W8
landed). Ports used tonight: 41000–41008.
Subagent stall pattern persists — 7-min watchdog + interrupt-kick works
(W4b needed two kicks; check any silent worker's transcript mtime).

**NOTE: the Linux host box was renamed `pop` → `pup` (2026-07-21 evening).
Same machine, same IP 10.0.0.249; `ssh pup` now. All docs + code comments
were updated (uncommitted as of this writing); references below say pup.**

---

# START HERE (new AI onboarding)

You are resuming the Lyte project. Everything below this block is detailed
session scratch; this block is the self-contained state + next action. Read
the plan of record before acting: `docs/20260720-222500-lyte-build-plan.md`
(the master build plan — slice ladder, gates, waves) and
`docs/20260720-215100-lyte-udp-decision.md` (the "all-in on Lyte-UDP"
decision). The four pillar docs + overview (`docs/20260720-1917*`,
`docs/20260720-193000`) are the protocol spec.

## What Lyte is (one paragraph)

A GPLv3 remote-desktop system where we own BOTH ends: a SwiftUI macOS client
and a Swift Linux host (`pup`, an RTX 4050 box at 10.0.0.249). We dropped the
GameStream/Sunshine dialect entirely and built our own protocol, **Lyte-UDP**:
damage-driven video, Noise-encrypted, Reed-Solomon FEC, pure Swift with C only
at OS boundaries (PipeWire, NVENC, D-Bus, libopus). Three SwiftPM packages:
`Wire/` (LyteWire — the shared, sans-IO protocol core, imported by both ends),
`Host/` (the Linux host), and the repo-root package (the macOS client). The
client's OLD GameStream stack is FROZEN scaffolding, deleted at H2 parity;
Sunshine on the host box is a bootstrap crutch, uninstalled at H2.

## Repo state

- Branch `main` is **in sync with `origin/main`** (pushed 2026-07-21
  ~23:12 MDT at the user's explicit request — the usual convention of
  not pushing unless asked still stands going forward). Working tree
  clean. `HANDOFF.md` is gitignored scratch — safe to edit, never
  commit it.
- Latest commits: `37011f5` (COMPARISON.md — product comparison doc),
  `57aaca0`/`b07914f`/`b88f32a` (pop→pup rename + hostname
  genericization: prose says "the host", commands keep `pup`),
  `28028b9` (Host README Wire-sibling note), `e721d50` (AGENTS.md joins
  the repo), `8783ef6` (CNetIO sendto), `0443beb` (handshake retry),
  `c8635f6` (client NoiseTransportCrypto). The whole H0a+H0b arc
  (W0–W5, HS-3–HS-7, HS-12, HS-14, CL-1–CL-3, codec promotions) is
  committed, gated, and now published.

## What works RIGHT NOW (proven, tested, committed)

- **H0a — capture+encode**: portal ScreenCast → NVENC HEVC, headless via a
  persisted restore token; steady-rate idle floor; quality-ratchet prototype
  (emergent QP walk to ~50 dB luma). All live-verified on pup.
- **H0b — first pixels over Lyte-UDP, NOISE ON END TO END**: the encrypted
  J-G1 re-gate PASSED (details below): real client `--host-key` handshake in
  ~12 ms, 5.5-min sealed soak with total accounting agreement (154,009 sent /
  154,002 received, 0 unseal failures both ways), 5% netem loss healed by the
  client's real coalescing IDR-retry loop (26/26), DSCP 40/48 on the wire,
  beacon clock sane, rendered in a window (`layer .rendering`). Codecs
  unified into Wire/ (conn-id TLV, path 0x03/0x04, carriage 0x05/0x06,
  IDR 0x10 + session-v1.json vectors). The human visual PASSED 22:26 MDT
  (see below) — **J-G1 is fully signed off; H0b is CLOSED.**
- **Protocol core (Wire/)**: envelope, FEC (nanors), video packetizer/
  assembler, clock beacon, feedback report, Noise IK (verified vs snow +
  cacophony external vectors). 181+ tests, byte-exact on Mac AND pup.
- **Client (root)**: receives/decodes/renders; feedback + beacon-echo +
  coalescing IDR-requester; `NoiseTransportCrypto` now REAL (IK initiator).
- **Host (Host/)**: full Session (Noise responder, seals everything, 1 Hz
  beacon), pacer (audio waits <35 µs behind video IDR), connection migration
  (spoof-rejected 4 ways), desktop audio capture + Opus (200 pkt/s, 5 ms).
- **CP-5 input verdict**: portal RemoteDesktop is HOSTILE headless; **Mutter
  internal RemoteDesktop is the HS-13 primary** (injection proven, cursor
  moved in captured frames, ~18 ms); uinput is the secondary fallback.

## THE ENCRYPTED J-G1 RE-GATE — **PASSED** (worker a773fa89, verdict ~11:50 MDT)

The 11:20 "unverified" flag is resolved: the worker was alive and the full
encrypted re-gate ran to completion. (Timeline overlap note: the worker and
this coordinating session both ran hosts on port 41000 — one coordinator
host was killed at ~11:10 as a "stray" and one worker client run aborted on
a Mac bind collision before the overlap was understood. All verdict runs
below completed cleanly; the definitive soak moved to port 41002 to
de-conflict. `/tmp/jg1n-*` = worker logs, `/tmp/jg1e-*` = coordinator logs.)

- **Pup rebuild + tests**: Wire **189/189 on Linux** (was 181; +8 from the
  promoted session codecs), Host builds clean, **34/34 on Linux** (37 minus
  the 3 codec tests relocated to Wire), `lyte-netio-check` green. Mac:
  Wire 189/189, Host 34/34, root **42/42** (35 + 7 new NoiseClientTests).
- **Handshake, live**: 1-RTT over the LAN in **12.2–22.1 ms** (wire-view
  prints it in its mode banner); host adopts the msg1 tuple and connects.
- **Definitive soak (port 41002, no netem, 330 s host / 340 s client),
  accounting agreement TOTAL**: host `19748 frames → 153677 shards →
  154009 datagrams (156.4 MB) in 133867 paced batches; max batch wire time
  940400 ns ≤ 1 ms; 331 beacons, 330 echoes, 4 IDR requests, 0 unseal
  failures, 8230 feedback datagrams`. Client: `154002 total, ALL ok
  (0 malformed, 0 unseal-failed)`, video 153671 dg / 6 seq-missing (Wi-Fi,
  0.005%), **19744 decoded, 4 fec-impossible → exactly 4 IDR requests →
  healed**, layer `.rendering`, 330 echoes, 329 clock samples. Logs:
  `/tmp/jg1n-soak2-{client,host}.log` (+ an earlier equally-green 330 s
  soak on 41000: 131k datagrams, 0 unseal failures, 1 fec-impossible/1 IDR:
  `/tmp/jg1n-soak-*.log`).
- **5% netem loss heal — THE PROBE CAVEAT IS CLOSED** (egress prio+u32 on
  wlp0s20f3 scoped to udp dport 41000, Sunshine untouched; 90 s): 40066
  datagrams, 2114 seq-missing (~5.1%), **26 FEC-impossible → 26 coalesced
  IDR-requests → host forced 26 IDRs → healed every time**, 5374 frames
  decoded, layer `.rendering` throughout, **0 unseal failures under loss**.
  The real retry loop (the probe's run-B gap) is live: request seqs 0–25
  observed on the host, ~100 ms coalescing window. Logs:
  `/tmp/jg1n-loss-{client,host}.log`.
- **DSCP on the wire** (tcpdump wlp0s20f3, 12 s soak window): 6068 ×
  `tos 0xa0` (video/DSCP 40), 12 × `tos 0xc0` (CTRL/DSCP 48). Client→host
  still unmarked (Mac IP_TOS best-effort — known, unchanged).
- **Beacon clock sane**: offset ≈ 83 907 658 xxx µs, stable to ~±1 µs at
  min-rtt samples across 330 s; min rtt 4990–8249 µs; Wi-Fi power-save
  rtt spikes (~55–100 ms) visible and correctly min-gated out.
- **Cleanup verified**: netem removed (`noqueue` restored), Sunshine user
  unit `active`, portal token sha `dadf9a66…37cf` and noise key sha
  `72860390…cfed` byte-identical to pre-run.
- **Independent coordinator confirmation (logs `/tmp/jg1e-*`, verified
  11:31 MDT)**: a second full pass agrees on every axis. Clean 330 s soak
  on 41000: host `19763 frames → 153939 shards → 154271 datagrams
  (157.2 MB), max batch wire time 921600 ns, 331/331 beacons echoed,
  0 unseal failures` ↔ client `154218 total ALL ok, 52 seq-missing
  (0.03% Wi-Fi), 19756 decoded, 3 fec-impossible → 3 IDR → healed,
  layer .rendering, 330 clock samples` (handshake 12.8 ms). 5% netem
  (100 s): host sent 46366 datagrams, client saw 2265 missing (≈4.9%),
  **42 fec-impossible → 41 coalesced IDR-requests → 42 forced IDRs,
  0 unseal failures under loss**, layer `.rendering`, handshake 48.3 ms
  through the impaired port. DSCP 60 s window: 30322 × tos 0xa0 /
  60 × tos 0xc0. Final cleanup re-verified 11:31 MDT after killing the
  last stray soak host: no lyte-host running, port 41000 free, `noqueue`,
  Sunshine `active`, both key/token shas unchanged.
- **CNetIO send_to verified live** (beyond the commit): pup loopback probe
  delivered a 61 B challenge-sized datagram to an OFF-PRIMARY tuple with
  TOS 0xC0 intact and source port preserved; the connected path still
  worked after. Only the live G7 roam run remains (needs a second client
  address to roam to).
- **Hard-won handshake lesson** (commit `0443beb`): retransmit ONE
  message 1 verbatim across the retry window, never a fresh session per
  attempt — Wi-Fi power-save delivered msg1 seconds late, the host
  established against it, and a client that had rolled its ephemeral could
  never read the answer.

### Pubkey pinning usage (until W6 PAKE)

lyte-host prints `noise: host static public key <64 hex>` at start
(key file: pup `~/.config/lyte-host/noise_static.key`, raw 32 B, 0600).
Today's stable key:
`10e0f0840455abf01afe255d7f4ade49eceabc33d2738a28de47b3e83c766201`.
Hand the hex to the client as `--host-key`; read it live from the banner
each run. A wrong pin fails loudly (tested: the host never derives a
transport from a msg1 it cannot open, the client times out).

### THE HUMAN VISUAL — **PASSED 2026-07-21 22:26 MDT (eyes on glass)**

J-G1 is now signed off on every axis; **H0b is CLOSED.** The maintainer
watched pup's live desktop rendered on the Mac over the fully encrypted
path and called it "absolutely beautiful" / updates "amazing". Run facts
(full 330 s, completed clean): pup had rebooted ~18:04 (portal restore
token survived — run was headless); Noise IK handshake 62.5 ms against
the pinned stable key `10e0f084…6201`; first frame on glass 21.4 ms after
first datagram; layer `.rendering` throughout. Accounting agreement:
host `20115 frames → 153568 shards → 153900 datagrams (169.0 MB), max
batch wire time 998400 ns ≤ 1 ms, 331/331 beacons echoed, 1 IDR request,
0 unseal failures` ↔ client `153897 total ALL ok, 2 missing (Wi-Fi,
0.001%), 20114 decoded, 1 fec-impossible → 1 IDR → healed, 331 echoes,
330 clock samples, min rtt ~9.3 ms`. Cleanup verified: no lyte-host,
port 41000 free, Sunshine `active`, noise key sha `72860390…cfed`
unchanged, portal token re-saved by the run as designed (36 B).
Logs: `/tmp/visual-{host,client}.log` (Mac).
Rerun recipe if ever needed: host
`cd ~/src/lyte-host && LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat ./.build/debug/lyte-host --backend portal --wire-listen 41000 --seconds 330`
→ copy printed pubkey → Mac
`DEVELOPER_DIR=/Applications/Xcode.app swift run lyte-cli wire-view 41000 --host-key <hex>`
(`--host` defaults to 10.0.0.249; ports 41000–41010 only.)

## NEXT: the H1 wave (parallelizable — one worker per territory)

Open these per the master plan (gates + deps there). Independent territories =
`Wire/`, `Host/`, root — never two workers in one package at once.
- **W3** ARQ reliable sublayer (Wire) — the big one; exhaustive sim tests.
- **W4b** session state machine, **W6** CPace PIN-PAKE, **W7** capabilities
  (Wire).
- **HS-8** CTRL-over-ARQ, **HS-9** pairing, **HS-10** Avahi discovery (Host).
- **CL-10** HostClockModel, **CL-6** pairing UI, **CL-5** discovery (client).
Then H2 (input via Mutter RemoteDesktop, audio on the wire, congestion) →
**Sunshine uninstalled, GameStream client stack deleted** (demolition
checklist in `docs/20260720-221103` §client plan). Then H3+ (clipboard →
drag-drop → printing → one `lyte` binary → WASM/browser via the Caddy
datagram-relay bridge).

## How to drive the work (operational lessons from this session)

- Delegate non-trivial slices to background subagents, ONE coherent worker per
  package territory; synthesize when several finish. Commit per-package
  (`git add Wire/` etc.), never `git add -A`, repo commit voice (declarative
  first line with an em-dash flourish + a why-focused body), no AI-attribution
  trailers, no push, no amend.
- **Subagents stalled chronically this session** — often 1 tool call then
  silence. A background watchdog (`while true; do sleep 420; echo TICK; done`
  with a notify pattern) that interrupt-kicks any worker silent >~8 min worked
  well; launch prompts that say "bias toward action, read only what you need"
  stalled less. (This MAY have been the pending Cursor security approval that
  triggered the restart — check whether launches behave normally now.)
- `pup` crashed/dropped off-network twice in 24 h (hard down for hours). If
  `ssh pup` times out, it needs a physical power/Wi-Fi check — not a code bug.
- pup facts: Ubuntu 26.04, GNOME Wayland, Swift 6.1.2 (needs the
  `LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat` libxml2 shim to build),
  passwordless sudo works, PipeWire 1.6.2. Keep all Lyte UDP off ports
  47998–48010. Never disturb the Sunshine service or
  `~/.config/lyte-host/{portal_token,noise_static.key}`.

---

## J-G1 FIRST-PIXELS LIVE RUN — RESULT (2026-07-21, pup back online)

pup returned (up 5 days, RTX 4050, unlocked). All deferred LINUX + LIVE
legs ran. **The stack is live end to end: Noise IK handshake over the
real LAN, sealed video from pup's real desktop to the Mac, FEC surviving
5% induced loss, per-packet DSCP on the wire, IDR-on-demand, sane
beacon clock, and a 5.5-minute soak with both ends' accounting in
agreement. Rendering (window) verified via wire-view `--insecure`
(1090 frames, layer `.rendering`); the Noise leg was verified with a
throwaway headless probe because the client package's
`NoiseTransportCrypto` is still `noisePending` (CL-1's slice).**

Key facts, hard-won or confirmed:

- **swift-crypto 3.x resolves and builds CLEAN on pup's Swift 6.1.2**
  (vendored BoringSSL). No pin needed. Wire builds in 17 s, all
  **181/181 tests pass on Linux**.
- **Cross-platform vector byte-exactness proven**: all five vector
  files regenerated on pup are sha256-identical to the committed
  (Mac-generated) artifacts — envelope 3715…83ef, fec caf3…69e8,
  video c415…35cf8, beacon d168…9984, noise 8a94…4dc6. Note: the
  video vectorgen reads `video-corpus-v1/` from the OUTPUT path's
  directory — symlink the corpus next to the output when regenerating
  outside Vectors/.
- **First Linux compile of the HS-5/7/12 legs needed exactly two
  one-line fixes** (committed `78f2aa6`): rd-spike's frame trampoline
  was missing the `graph_us` parameter HS-5 added to `lyte_pw_frame_cb`,
  and a beacon-offset integer literal in SessionGateTests needed an
  explicit Int64 under 6.1.2's inference. Host then builds and passes
  **37/37 on Linux**; `lyte-netio-check` green (grown recv slot OK).
- File-capture regression: `--seconds 3` portal run → 181 packets,
  1 IDR, `VPS SPS PPS PREFIX_SEI IDR_W_RADL`, clean ffmpeg decode,
  portal token byte-identical (sha dadf9a66…37cf).
- **Noise IK live**: msg1 122 B → handshake complete in ~11–48 ms
  1-RTT against the responder; host prints its static pubkey
  (`~/.config/lyte-host/noise_static.key` minted on first run; pubkey
  `10e0f084…6201` on pup today). Sealed stream: 0 unseal failures
  across ~140 k datagrams total this session; every datagram ≤1152 B.
- **FEC under 5% netem loss** (egress prio+u32 qdisc on wlp0s20f3
  scoped to udp dport 41100 — Sunshine untouched): 70 s run,
  20 998 video datagrams delivered, **3591/3601 frames byte-exact
  (99.7%)**, 10 FEC-impossible (loss clusters beyond per-frame parity),
  0 corrupt. The real client coalesces those into IDR requests
  (verified separately); the probe skipped them by design.
- **DSCP per packet on the real wire** (tcpdump wlp0s20f3): 20 986 ×
  `tos 0xa0` (DSCP 40, video), 58 × `tos 0xc0` (DSCP 48, CTRL
  beacons/msg2), 59 × `tos 0x0` (inbound from Mac — the client side
  doesn't mark yet).
- **IDR-on-demand live**: probe's sealed 0x10 → host `ctrl: IDR
  request seq 0` → forced IDR decoded 2 frames later (run A). Run B's
  forced IDR itself died to the 5% loss (no re-request in the probe —
  the client's coalescing requester handles that in production).
- **Beacon clock sane**: offset settles to −129 894.0 s ±10 µs
  (CLOCK_MONOTONIC epochs differ by boot time — expected), rtt
  5.7–11 ms on this Wi-Fi path, min-rtt-gated estimate stable across
  the whole soak.
- **Latency honesty**: `delta − offset` on idle-floor repeats measures
  DESKTOP STALENESS (the retained frame's capture stamp), not path
  latency — p50 ~0.5 s is the top-bar clock's damage cadence. The
  freshest-frame figure (min delta − offset) is **~16 ms capture→
  assembled on the Mac** (+ decode/present on top).
- **Soak (330 s host / 345 s probe, no netem) — accounting agreement
  is TOTAL**: host encoded 19 800 frames → 131 754 shards → 132 086
  datagrams (132.1 MB); probe received exactly 132 086 (video 131 754,
  ctrl 331, + msg2) — ZERO datagrams lost on the LAN in 5.5 min.
  **19 800/19 800 frames decoded byte-exact**, 0 FEC-impossible,
  0 skipped, 331/331 beacons echoed, 330 clock samples, 0 unseal
  failures both directions, max batch wire time 955 µs ≤ 1 ms quantum,
  every datagram ≤ 1152 B. Mid-soak IDR request healed in 2 frames.
  Logs: `/tmp/jg1-soak-probe.log` (Mac), pup:`/tmp/jg1-host-soak.log`.
- wire-view render leg (insecure, 35 s smoke): 7846 datagrams, 1090
  frames decoded/enqueued, layer `.rendering`, first frame 9.7 ms
  after first datagram. The `417 send-failed` on the client is benign:
  feedback ticks before any host datagram arrives have no peer address.
- **`--insecure` host mode requires the CLIENT socket to exist first**
  (host streams immediately; ICMP unreachable kills it with
  `recvmmsg: Connection refused`). Start wire-view before lyte-host,
  and give the client a duration ≥ the host's.
- **CP-5 upgrade — pixels moved**: `rd-spike --mutter --keyboard` on
  pup: Mutter RemoteDesktop session headless, pointer injected to two
  points, frame-diff confirms the EMBEDDED cursor moved (11 frames,
  injection→visible ≈ **18 ms**), KEY_A down/up fired. Portal video
  token untouched after (sha identical).
- **HS-12 live rebind: NOT RUNNABLE yet by design** — challenges to
  unvalidated tuples are "undeliverable until CNetIO grows sendto"
  (SessionWire counts and logs them loudly). The Linux rebind leg
  stays deferred until that lands; don't burn time trying.
- Noise probe lives at `/tmp/noise-probe` (throwaway, NOT in the repo):
  LyteWire NoiseSession initiator + VideoAssembler + beacon echo +
  sealed IDR request, prints the accounting verdict. Rebuild:
  `cd /tmp/noise-probe && DEVELOPER_DIR=/Applications/Xcode.app swift build`.
- **Remaining for J-G1 sign-off: the human's eyes** (client Noise leg
  CL-1 still pending, so the visual run is `--insecure`):
  1. Mac: `cd ~/Data/Code/lyte && DEVELOPER_DIR=/Applications/Xcode.app swift run lyte-cli wire-view 41000 --insecure`
  2. pup: `cd ~/src/lyte-host && LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat ./.build/debug/lyte-host --wire-out <MAC_IP>:41000 --insecure --seconds 330`
  MANDATORY re-run with Noise once CL-1's NoiseTransportCrypto lands
  (host: `--wire-listen 41000`, no `--insecure`; client pins the
  printed pubkey).

## TL;DR

- **Tonight's strategy decision — "DROP EVERYTHING BUT Lyte-UDP"** — is
  recorded in `docs/20260720-215100-lyte-udp-decision.md` and folded into
  LYTE-PLAN §5–§6, HOST-PLAN, the protocol overview, the bridge doc, and
  TODO.md. lyte-host will only ever speak Lyte-UDP (our own protocol over
  plain UDP; QUIC rejected for v1); the client's GameStream stack is frozen
  scaffolding, deleted once Lyte-UDP is load-bearing (H0b/H1 target, H2 at
  the latest); Sunshine is a bootstrap crutch until Lyte↔Lyte streams, then
  uninstalled. The pillar docs remain the protocol spec.
- `main` is six commits ahead of `origin/main`: `ccfb913` verifies
  idle-video tolerance; `7e3b50f` records the audio-continuity consult,
  establishes `docs/HOST-PLAN.md` as the host plan, and standardizes
  vocabulary; `4619121` lands **H0a slice 1**; `f529c57` lands **H0a
  slice 2** (idle-floor steady-rate supply); `89326b4` commits the
  Lyte-UDP decision and pillar docs; `493b6bd` lands **H0a slice 3**
  (quality-ratchet prototype).
  Use **host/client** for the two ends; use **sender/receiver** only for
  directional roles within a stream.
- Client M0–M6 core is complete and live against Sunshine on `pup`. The app
  streams HEVC video, Opus audio, and input; the doctor and AWDL helper work.
  M5.5–M7 work stays frozen through H0–H2 except for critical fixes. No new
  GameStream work of any kind happens on the client.
- Pre-H0 preparation is complete. The idle gate passes: `LYTE_GAP_SIM`
  discards every video packet for 45 seconds midstream while audio/control
  survive; video resumes with exactly one lost frame and an IDR request.
  The client accepts arbitrarily long video silence after its first complete
  frame.
- H0a slice 1 is committed (`4619121`): `Host/` SwiftPM package with
  pure-Swift Annex-B helpers (10/10 tests), system-library modules,
  `CPipeWireCapture`, `CHevcEncode`, and `lyte-host`. H0a slice 2 is
  committed (`f529c57`): the idle floor re-encodes the last frame on a
  PipeWire-loop tick at the fps interval, so a static desktop yields ~300
  packets in 5s at 60 fps (1 IDR, repeats are ordinary P-frames) instead
  of ~7 damage frames; `--no-idle-floor` disables it.
- **The portal restore path is verified headless.** Two consecutive
  noninteractive runs over SSH on `pup` each consumed the saved restore token
  (no consent dialog), captured the real desktop 2048×1280 bgr0, encoded to
  HEVC Main yuv420p with VPS/SPS/PPS + IDR first, decoded cleanly under
  `ffmpeg`, and left the 36-byte token intact.
- The formerly planned "Sunshine-dialect RTP+FEC into the debug client"
  H0a slice is **dropped** by the Lyte-UDP decision.
- **H0a slice 3 (quality-ratchet prototype) is done and committed** —
  `--ratchet` runs capped-CQ VBR and converges the static desktop to QP 12
  in ~0.9 s from trigger, then goes truly silent. The mechanism that works
  in libavcodec's `hevc_nvenc` is *emergent*: feed identical frames under
  `rc=vbr` + `cq` and nvenc's own rate control walks the frame QP down
  1–3 rungs per pass — no per-frame QP command exists or is needed. See
  "Quality-ratchet findings" below; this is the key input to the Work-mode
  encoder design (image-quality pillar §3).
- **HS-4 (CNetIO UDP leaf) is done and committed** (`84dd823`): per-packet
  DSCP via IP_TOS cmsgs on sendmmsg batches, IP_RECVTOS receive readback,
  SO_TIMESTAMPING software TX stamps off MSG_ERRQUEUE — all proven on pup
  (tcpdump per-packet tos 0xb8/0xa0/0xc0; stamps monotonic, +23 µs first).
  `lyte-netio-check` is the harness; `Scripts/netem/lo-netem.sh` is the
  first (loopback, port-scoped) netem rig piece. See "HS-4 findings" below.
- **HS-6 (Pacer v1) is done and committed**: `HostCore.Pacer` is the
  strict-priority token-bucket send pacer — pure Swift, injected clock,
  sans-IO. Gate held in simulation (max batch wire time 0.92 ms;
  conforming 59,904 B IDR drains 24.14 ms ≤ 25; audio max wait 34 µs) and
  on pup through CNetIO (`lyte-pace-check`: TX-stamp batch spacing
  0.19/0.88/1.03 ms min/avg/max, 48 KB IDR drain 19.2 ms, audio wait
  29 µs, per-class TOS 0xC0/0xA0 verified via IP_RECVTOS). At 20 Mbps the
  derived `frameByteCeiling` is 60,000 B (62,500 B gross in the 25 ms
  budget minus ~2.1 KB of higher-class audio/control). See "HS-6
  findings" below.
- **Resume here:** H0b Lyte-UDP envelope design-to-code.

## Project

Lyte is a GPLv3, SwiftUI-native macOS client plus a Swift Linux host, giving
the project ownership of both ends. Both ends speak **Lyte-UDP** — our own
protocol over plain UDP (decision of 2026-07-20); the client's existing
GameStream stack is frozen scaffolding kept only until Lyte-UDP is
load-bearing. The client protocol layer is pure Swift with vendored C leaves
for ENet and nanors (ENet leaves with the scaffolding deletion; nanors stays —
Lyte-UDP's RS FEC is deliberately nanors-compatible); host C stays at
hardware/OS boundaries such as D-Bus, PipeWire, and libavcodec. Product policy centers on one Work/Play
toggle, Local/Remote detection, telemetry-derived settings, and a network
doctor. The host captures the real desktop through the portal and uses NVENC.

Read in this order:

1. `README.md`
2. `LYTE-PLAN.md` — overall strategy and H-ladder in §6
3. `docs/20260720-215100-lyte-udp-decision.md` — the protocol decision of
   record (only Lyte-UDP, ever)
4. `docs/20260720-19170{1,2,3,4}-lyte-protocol-*.md` — the four pillar docs
   (the protocol spec) and `docs/20260720-193000-lyte-protocol-overview.md`
   (their reconciliation; see its §6 addendum)
5. `PLAN.md` — client implementation blueprint
6. `docs/DESIGN.md`
7. `docs/HOST-PLAN.md` — adopted capture/encode path (wire mandate
   superseded; see its banner)
8. `docs/20260720-145840-audio-continuity.md` — H2 pacing and M7 audio spec
9. Historical reference: `docs/moonlight-common-c.md`,
   `docs/moonlight-macos.md`, `docs/sunshine-v2026.715.205118.md`,
   `docs/moonshine.md`

## Current repository state

- Recent commits:
  - `493b6bd` H0a slice 3: quality-ratchet prototype (`--ratchet`)
  - `89326b4` Lyte-UDP decision + pillar docs committed
  - `f529c57` H0a slice 2: idle-floor steady-rate frame supply
  - `4619121` H0a slice 1: Host/ package, portal capture → NVENC → Annex-B
  - `7e3b50f` audio-continuity consult, host/client vocabulary, doc rename
  - `ccfb913` idle-video tolerance verification
- Working tree: `main...origin/main [ahead 6]`; untracked `Wire/`
  (parallel H0b work, not mine to touch). `HANDOFF.md` is ignored session
  scratch.
- Do not add AI-attribution trailers to commits.

## Environment facts

- `pup` is the host at `10.0.0.249`, reached with `ssh pup`. It runs Ubuntu
  26.04 x86_64, GNOME/Mutter Wayland, and a 2048×1280@60 `eDP-1` display.
  **`pup` was unreachable as of ~21:10 tonight** — re-check before resuming
  the ratchet-prototype work.
- Live state at last contact (~19:05): Sunshine user unit active; session 1
  active and unlocked (`LockedHint=no`); portal token present (36 bytes);
  the earlier `/tmp/lyte-h0a.hevc` evidence file is not currently present.
- Keep Sunshine running and keep `pup` unlocked. Concurrent capture is
  supported. Sunshine uses VAAPI while `lyte-host` uses NVENC, and the H0a
  file-output slice has no network-port conflict.
- Portal ScreenCast v5 exposes persistence/restore tokens; RemoteDesktop v2
  is available. A locked GNOME session inhibits portal capture. The host must
  reject this state with a named error.
- Swift 6.1.2 is at `/usr/local/bin/swift`. PipeWire, D-Bus, libavcodec, and
  NVENC development/runtime support are installed. GPU: NVIDIA GeForce RTX
  4050 Laptop, driver 595.71.05.
- Swift 6.1.2 build tools request `libxml2.so.2`; Ubuntu 26.04 supplies
  `libxml2.so.16`. The current no-root environment workaround is
  `~/.local/lib/swift-compat/libxml2.so.2 → /usr/lib/x86_64-linux-gnu/libxml2.so.16`
  with `LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat`. This is a local build
  workaround, not a general ABI guarantee.
- Host source stays local in `Host/`; sync with
  `rsync -a --delete --exclude .build Host/ pup:src/lyte-host/`, then build on
  `pup` with the `LD_LIBRARY_PATH` workaround.
- macOS client tests need
  `DEVELOPER_DIR=/Applications/Xcode.app swift test`. Use
  `Scripts/build-cli.sh` and `Scripts/make-app.sh` for binaries that contact a
  host so the stable “Lyte Dev” signature preserves Keychain authorization.
  Details: `docs/MACOS-SIGNING.md`.
- Pairing with `pup` is already stored. `lyte-cli apps 10.0.0.249` works.
  Encrypted RTSP (`rtspenc://`, enabled by `corever=1`) is correct.

## Verified client state

- M0–M2: scaffold, pairing, encrypted RTSP session handshake, control-v2 GCM,
  pings, and clean teardown work against Sunshine.
- M3: RTP → nanors FEC → HEVC depacketization →
  `AVSampleBufferDisplayLayer` renders at about 60 fps. A 310-second soak
  yields 18,132 frames, 143,865 packets, zero skipped, and 10 startup losses.
  A 5% packet-drop run recovers 1,087 packets with FEC; IDR requests heal the
  10 unrecoverable frames.
- M4: keyboard, mouse, scroll, and UTF-8 input ride encrypted control channel
  NVCTL `0x0206`. Audio uses Opus, AES-128-CBC, and 4+2 RS FEC with NVIDIA
  parity `77 40 38 0e c7 a7 0d 6c`; a 5% drop run recovers 187 audio packets.
- M5: Lyte.app provides discovery, recents, PIN pairing, relaunch/reconnect,
  Work/Play launch cards, focused-window actions, and full streaming.
- M6 core: menu-bar agent, doctor, SMAppService AWDL helper, declick ramps,
  honest underrun counting, kernel-stamped gap probes, and per-host bitrate
  headroom learning all work. Remaining M6 niceties stay frozen.
- One session per host: do not run the app and CLI stream concurrently against
  the same host; duplicated clients produce doubled/echoed audio.

### Idle-video acceptance

`LYTE_GAP_SIM="start:len"` discards all received video for 45 seconds after
streaming begins. Audio and ENet control remain alive. When video packets
return, the frame-index jump records exactly one lost frame, triggers control
message `0x0302`, and a fresh IDR restores full-rate rendering.

Client behavior and host obligations:

- Video watchdogs apply only at startup: first traffic within 10 seconds of
  PLAY, then first complete frame within 10 seconds of first traffic.
- No post-first-frame video-rate watchdog exists; control carries liveness.
- The host must emit an immediate complete IDR at startup and promptly answer
  every `0x0302` IDR request.
- After the first complete frame, damage-driven silence may be arbitrarily
  long. Contiguous frame numbering on true idle requires no recovery.

## H0a slices 1–2

`Host/` is a separate SwiftPM package because the root package is macOS-only:

- `HostCore`: pure-Swift Annex-B/NAL helpers; 10/10 tests pass on macOS.
- `CDBus`, `CPipeWire`, `CLibAV`: Linux system-library modules.
- `CPipeWireCapture`: C PipeWire capture leaf.
- `CHevcEncode`: C libavcodec/`hevc_nvenc` leaf with low-latency CBR,
  single-frame VBV, infinite GOP, zero B-frames/reorder, P1/ULL, one surface.
- `lyte-host`: Swift executable wiring portal or Mutter capture to NVENC and
  an Annex-B file.

The Mutter direct backend proves the capture/encode path while portal approval
waits for consent. A five-second run against the real `pup` desktop receives
8 damage-driven frames and emits 8 packets, one IDR, and 82,164 bytes. The
first packet is `VPS SPS PPS PREFIX_SEI IDR_W_RADL`; `ffprobe` reports HEVC
Main, 2048×1280, yuv420p; a full `ffmpeg` decode is clean. Eight frames are
expected for a static desktop because PipeWire delivery is damage-driven.

Portal is the default backend and implements
CreateSession → SelectSources (`persist_mode=UNTIL_REVOKED`, optional restore
token) → Start → OpenPipeWireRemote. The noninteractive restore-token path is
verified: two consecutive headless runs, no consent dialog, clean decodes,
token intact. Mutter remains a spike fallback, not the product capture path.

Two hard-won fixes were required to make the portal path work headlessly
(both in the committed slice):

1. **Pin the capture stream to the portal node by `object.serial`.**
   `pw_stream_connect`'s target id parameter is resolved loosely by
   WirePlumber; it linked the *default* video source (the laptop webcam,
   YUY2/MJPG-only) instead of the gnome-shell screencast node, and format
   negotiation failed with "no more input formats". The fix: registry-scan
   the portal remote for the node id, set `target.object` to its
   `object.serial`, connect with `PW_ID_ANY`, and set
   `node.dont-fallback=true` so a missing target errors loudly
   ("defined target not found") instead of silently linking the webcam.
2. **Keep the portal D-Bus session alive for the whole capture.** The
   `PortalScreenCast` object was dropped after `openDesktopStream()`
   returned; its `SessionBus.deinit` closed the D-Bus connection, the portal
   tore down the session, and the PipeWire node vanished mid-negotiation
   ("some node was destroyed before the link was created"). The fix retains
   the portal object until capture completes.

Slice 2 (`f529c57`) adds the idle-floor/steady-rate supply. The capture
leaf gains `lyte_pw_capture_set_tick`: a repeating `pw_loop_add_timer` on
the PipeWire main loop, so ticks and frame callbacks are serialized on one
thread with no locking. Policy lives in Swift: `Sink` retains a copy of the
most recent frame (the PipeWire buffer is only valid inside the callback)
and on each tick re-encodes it if no fresh frame was encoded since the
previous tick. Damage frames still encode immediately; pts is monotonic per
encoded frame; only frame 0 forces an IDR. Default on at `opts.fps` (60);
`--no-idle-floor` disables. The encoder also gains two Sunshine recipe
items the repeat load exposed: `qmin=23` and `multipass=qres` — without
two-pass, nvenc CBR keeps spending the full budget re-refining a static
scene (5.5 MB/5s); with it the stream goes quiet (1.93 MB/5s, last-second
packets ~5.5 KB avg).

Verified on `pup`, portal backend, static desktop, twice headless via the
restore token: 301 frames encoded (6–8 damage, rest repeated), 301 packets,
exactly 1 IDR, first packet `VPS SPS PPS PREFIX_SEI IDR_W_RADL`, ~1.93 MB;
ffprobe hevc Main 2048×1280 yuv420p; full ffmpeg decode clean, 301 frames
read. Mutter backend re-verified with the floor active (182 packets/3s,
clean decode). HostCore stays 10/10 on macOS.

## H0a slice 3 — quality-ratchet findings (committed `493b6bd`)

`--ratchet` on the file-output host prototypes the image-quality pillar §3
ratchet. Wiring: `lyte_hevc_enc_new` gains a `cq` argument (0 = the CBR
slice-2 recipe; >0 = capped-CQ VBR with `qmin` pinned at `cq`); the packet
callback gains nvenc's frame-average QP (from `AV_PKT_DATA_QUALITY_STATS`
side data, `(qp-1)*FF_QP2LAMBDA`). Swift policy: after 250 ms damage-quiet,
the idle-floor tick feeds the retained frame at fps/4; stop on an ~all-skip
pass (≤2 KB) or three byte-stable passes (<1% delta) at the QP floor; then
true silence until fresh damage, which aborts/rearms the episode.

**Encoder facts (probed on RTX 4050 / driver 595.71.05 / FFmpeg 8.0.1,
all mid-stream QP-control candidates tested empirically):**

1. **There is no commanded per-frame QP through libavcodec's nvenc.**
   `av_opt_set("cq")` mid-stream returns 0 but is ignored (options are read
   only at `avcodec_open2`); `AVFrame.quality` is ignored; FFmpeg's only
   nvenc reconfig path (`reconfig_encoder` in nvenc.c) covers bitrate/DAR
   only, and a bitrate change sets `resetEncoder=1, forceIDR=1` — i.e. it
   costs an IDR, unusable for refinement (verified: 10→20 Mbps mid-stream
   emitted a fresh `VPS SPS PPS … IDR`).
2. **The ladder is emergent, not commanded.** Under `rc=vbr` + `cq` +
   max-rate cap, feeding identical frames makes nvenc's own rate control
   walk the frame QP down 1–3 rungs per pass (50→…→9 measured). CBR does
   the same walk but `qmin=23` floors it — that's what the slice-2 idle
   floor was already doing, unnamed.
3. **`cq` is a soft target, not a floor** — the walk overshoots ~3 QP below
   the target (to QP 9 with cq=12). Pin `qmin = cq` to hold the floor
   (set it via the *priv* option, not `AVCodecContext.qmin`, which warns
   under vbr).
4. **All-skip is ~5.6 KB, not ~0, at 2048×1280** — skip-CTU signaling costs
   ~5.6 KB/frame regardless of content. The spec's "packet below a small
   threshold" stop condition must be resolution-scaled; byte-stability
   (three passes within 1%) is the detector that actually fires.
5. `frameAvgQP` per packet via quality-stats side data is reliable and free
   — the policy layer can watch convergence without parsing the bitstream.

**Measured (pup's real desktop, portal headless, 15 s, fps/4 pacing):**
full ladder from a fresh IDR: QP 30→12 in 11–16 passes, ~0.9 s from
trigger, ~250 KB total; per-pass bytes ~23 KB (QP 30) → ~19 KB (mid-teens)
→ 5.6 KB (skip floor). The "static" desktop actually damages ~1/s (top-bar
clock seconds), so each episode re-converges in 4 passes / ~22.6 KB /
200 ms; between episodes: zero bytes. Decoded evidence: luma PSNR vs the
raw PipeWire frame (dumped via `LYTE_DUMP_RAW=path`) rises 38.6 dB (IDR)
→ 50.2 dB (post-ratchet) — the pillar's ≥50 dB luma gate passes; RGB PSNR
(32.5→35.3 dB) is chroma-limited by 4:2:0, which is the 4:4:4 argument.
Extracted PNGs confirm visibly crisper text post-ratchet. Non-ratchet
regressions hold: plain 5 s run 301 packets / 1 IDR / clean decode / token
intact; HostCore 10/10 on macOS.

## HS-4 — CNetIO UDP leaf findings (committed `84dd823`)

`Host/Sources/CNetIO/` is the UDP socket leaf (plain Linux syscalls, no
system library): `lyte_netio_new` (nonblocking IPv4 bind + IP_RECVTOS),
`_set_peer` (connect), `_enable_tx_timestamps`, `_send_batch` (sendmmsg,
one IP_TOS cmsg per datagram), `_recv_batch` (recvmmsg, received TOS per
slot), `_poll_txstamps` (MSG_ERRQUEUE drain → (pkt_id, ns)), `_local_port`,
`_free`. `lyte-netio-check [port]` verifies the whole loop on 127.0.0.1
and exits nonzero on any mismatch.

Linux facts verified on pup (kernel 7.0.0-27, no plan-doc contradictions):

1. **Per-packet TOS through sendmmsg cmsgs just works** — no socket-level
   IP_TOS needed; each datagram in one batch carried its own marking,
   confirmed both by tcpdump on lo and by IP_RECVTOS on the receiver.
   The kernel wants the cmsg payload as an int; `_GNU_SOURCE` is required
   for sendmmsg/recvmmsg/struct mmsghdr.
2. **SO_TIMESTAMPING with OPT_ID + OPT_TSONLY is the right recipe**: the
   error queue delivers SCM_TIMESTAMPING (ts[0] = software stamp,
   CLOCK_REALTIME ns) + IP_RECVERR ext-err whose `ee_data` is the
   per-datagram counter, so stamps match to sends without payload
   reflection. 12/12 stamps arrived, monotonic, first +23 µs after
   sendmmsg return, ~2–3 µs apart within the batch.
3. **Netem delay sits after the TX stamp point** — under a 20 ms lo
   profile, delivery slows to 20 ms but send stamps stay ~+50 µs: TX
   stamps measure host egress (their purpose — pacer/dispersion
   instrumentation), not path delay.
4. `sudo -n` works on pup (passwordless), so tcpdump/tc evidence is
   scriptable over BatchMode ssh.
5. `Scripts/netem/lo-netem.sh apply <port> [delay-ms] [loss-pct]` scopes
   impairment to one UDP dport on lo via prio qdisc + u32 filter (all
   other traffic rides an unimpaired band — Sunshine untouched, verified:
   an unpinned-port harness run under the profile saw 0 ms). `remove`
   restores lo to noqueue. LAN R-G1..G8 profiles come later.

## HS-6 — Pacer v1 findings

`Host/Sources/HostCore/Pacer.swift` is the strict-priority token-bucket
send pacer, sans-IO like Wire's doctrine: every entry point takes `now`
(monotonic ns), tokens are opaque byte counts + class tags, no threads,
no sockets, no Wire dependency. API: `enqueue(class, bytes:, frameID:,
urgent:, tag:, now:)`, `nextBatch(now:) -> PacerBatch?`, `nextWake(now:)`,
`setRate(bitsPerSecond:, now:)` (the HS-16 seam — rate is an injected
parameter, default = negotiated ceiling), `telemetry` (per-class
bytes/tokens/max queue delay + aggregate max batch wire time).

Design facts worth remembering:

1. **The ≤1 ms batch bound is the bucket's burst cap** — burst capacity
   is exactly one quantum of bytes at the current rate, so no batch can
   ever exceed 1 ms of wire time; `setRate` re-caps immediately.
2. **Classes are `PacerClass`** (control > audio > freshVideo >
   videoTail > refinement > telemetry, the overview's unified ruling).
   `urgent` jumps only its own class's FIFO (forced IDR ahead of stale
   shards) — never a higher class, so audio protection is structural.
3. **frameByteCeiling at rate R, budget B = min(2/fps, 25 ms):**
   `R×B/8 − higherClassBytes(B)`. At 20 Mbps/60 fps: 62,500 − ~2,100 ≈
   60,000 B. The gate test documents the derivation; a 90 KB IDR at
   20 Mbps is *non-conforming* (needs ≥29.5 Mbps for 25 ms) and the test
   proves the pacer still holds the batch/audio bounds under it while
   the drain lands exactly on rate math (37.5 ms).
4. **Event-driven callers should wake at `nextWake`**; a 1 ms ticker
   also works but clips leftover bucket credit (~4% throughput at
   1,152 B shards) — the pace-check harness wakes at
   min(nextWake, next arrival) and shows ~0.9 ms average spacing during
   a saturated drain.
5. `lyte-pace-check` (Linux, HostCore + CNetIO) is the end-to-end proof:
   pacer schedule → sendmmsg batches with per-class TOS (mapping lives
   in the harness: control/audio 0xC0, video 0xA0, telemetry 0x00) →
   kernel TX stamps measure spacing/drain/audio-wait; exits nonzero if a
   gate bound is violated.

## Immediate next action

1. H0b Lyte-UDP envelope design-to-code: the 24-byte envelope, video
   datagram channel, and RS FEC per the transport/resiliency pillars as
   amended by the decision record. (An untracked `Wire/` directory exists —
   check whether parallel H0b work already started before duplicating.)

## Host strategy and roadmap

- **Protocol: Lyte-UDP only, ever** (decision of 2026-07-20,
  `docs/20260720-215100-lyte-udp-decision.md`). Plain UDP datagrams + a tiny
  homegrown ordered-retransmit sublayer; Noise E2E crypto; PIN-PAKE pairing;
  per-packet DSCP 48/40 restored; QUIC rejected for v1 (facade keeps it
  swappable). No GameStream on the host — no RTSP, ENet, GameStream RTP,
  HTTPS pairing, or Moonlight compat. Idle silence + damage-only video are
  default behavior. Golden pcaps are historical reference for the payload
  interiors (HEVC depacketization, RS FEC math, Opus framing), which carry
  into the new envelope.
- Desktop capture, not a compositor: portal/PipeWire against the real GNOME
  session; Portal RemoteDesktop input is primary and uinput is fallback.
- NVENC through one libavcodec leaf on the host; keep the facade open to other
  hardware backends. GNOME/Mutter + NVIDIA is the H0–H2 supported environment;
  COSMIC and non-NVIDIA configurations fail loudly.
- Client: M0–M6 core complete; M5.5–M7 remainder frozen through H0–H2. The
  GameStream stack is frozen scaffolding — zero new work — deleted once the
  Lyte-UDP path is load-bearing (H0b/H1 target, H2 latest). Sunshine is a
  bootstrap crutch until Lyte↔Lyte streams, then uninstalled.
- Host ladder: **H0a complete (slices 1–3 committed: portal capture+encode
  verified headless; idle-floor steady-rate supply; quality-ratchet
  prototype with measured convergence)** → H0b first pixels over Lyte-UDP
  (envelope + video datagrams + FEC; client debug receive module) →
  H1 honest session (Noise, PIN-PAKE, discovery, control channel,
  idle/active machine, beacon) → H2 parity (input + audio + CC/NACK/
  FROZEN-RECOVERY; exit = Sunshine uninstalled, GameStream scaffolding
  deleted) → H3 feature channel/clipboard → H4 4:4:4+policy+full ratchet →
  H5 files/printing → H6 one binary + macOS host.

Plan of record: `LYTE-PLAN.md §6` +
`docs/20260720-215100-lyte-udp-decision.md`; capture/encode detail in
`docs/HOST-PLAN.md` (wire mandate superseded).

## CP-5 — pre-HS-13 RemoteDesktop input spike (VERDICT)

Spike harness: `lyte-host rd-spike [--portal|--mutter] [--start-only]
[--keyboard] [--seconds N] [--fresh]` (`Host/Sources/lyte-host/RemoteDesktopSpike.swift`)
plus `Host/spike/uinput_probe.c`. Throwaway wiring, rigorous findings. The RD
restore token, if the portal path ever mints one, persists to
`~/.config/lyte-host/portal_rd_token` — the ScreenCast video token at
`~/.config/lyte-host/portal_token` is never touched.

**VERDICT: the sanctioned xdg-desktop-portal RemoteDesktop v2 path is HOSTILE
headless — its combined Start is auto-denied over SSH with no dialog to click.
Do NOT make it the HS-13 primary. Two headless-capable paths are proven
instead; recommend the GNOME-internal `org.gnome.Mutter.RemoteDesktop` as
HS-13 primary (same API family already used for the `--backend mutter` video
fallback, no consent, no token, absolute pointer), with the uinput C-leaf as
the documented secondary fallback.** This matches the plan's "portal hostile →
bless the fallback" branch; it refines *which* fallback.

Environment (pup, GNOME/Mutter Wayland, Ubuntu 26.04): portal
`RemoteDesktop.version = 2`, `AvailableDeviceTypes = 7`
(KEYBOARD|POINTER|TOUCHSCREEN); `ScreenCast.version = 5`. Internal
`org.gnome.Mutter.RemoteDesktop.Version = 1`, `SupportedDeviceTypes = 7`.

- **Q1 — headless Start with persist_mode=2?** PORTAL: **NO.**
  `RemoteDesktop.CreateSession` → Response **0**; `SelectDevices`
  (types=3 KEYBOARD|POINTER, persist_mode=2, no token) → Response **0**;
  `ScreenCast.SelectSources` on the *same* session (MONITOR, cursor EMBEDDED)
  → Response **0** — so the combined session assembles fine. But
  `RemoteDesktop.Start` (parent_window="") → Response **1 (cancelled/denied)**
  in ~1.6 s, both with and without the ScreenCast leg. `xdg-desktop-portal-gnome`
  logs `Failed to associate portal window with parent window`. The fast deny
  (not a 90 s pending dialog) means the GNOME portal backend refuses rather
  than parks a clickable dialog when there is no parent window / seat-hosted
  UI over SSH. Consequence: **no restore token can ever be minted headless**,
  because minting requires one successful interactive Start first, and that
  Start is what fails. The v2 persist/restore flow does not rescue us here.
  MUTTER-INTERNAL: **YES.** `Mutter.RemoteDesktop.CreateSession` →
  `Mutter.ScreenCast.CreateSession` linked by `remote-desktop-session-id` →
  `RecordMonitor(cursor-mode=1)` → `RemoteDesktop.Session.Start` (one Start
  brings up both legs; calling `ScreenCast.Session.Start` separately errors
  `Must be started from remote desktop session`) → `PipeWireStreamAdded` node
  id. All headless over SSH, **no dialog, no token**.
- **Q2 — does injection land?** Injection *calls* succeed on the started
  Mutter session: `NotifyPointerMotionAbsolute(stream, x, y)` and
  `NotifyKeyboardKeycode(keycode, state)` both return without error against a
  live combined session (verified via a Gio probe and the harness). Frame-diff
  pixel confirmation (move cursor to two known points, diff EMBEDDED-cursor
  frames, match centroid to target) is implemented in `rd-spike --mutter` and
  dumps `/tmp/rd_frameA|P1|P2.raw`. **pup went off-network (`Host is down`,
  a KNOWN recurring condition here — see host-facts) mid-spike, before the
  final frame-diff run; re-run `lyte-host rd-spike --mutter --keyboard` when
  pup returns to capture the pixel evidence.** The D-Bus contract + the fact
  that gnome-remote-desktop drives input through exactly these Notify* calls
  make a landing near-certain; the frame-diff is the remaining formality.
- **Q3 — latency.** Harness records NotifyPointerMotionAbsolute →
  first-changed-frame delta (`watchLatencyMs`); pending the same re-run.
- **Q4 — token persistence.** MUTTER-INTERNAL: **not applicable** — no
  consent, no token, every run starts clean, so there is nothing to
  invalidate (strictly better than a token that can be revoked). PORTAL: moot
  — Start never succeeds headless, so no token exists to persist.
- **Q5 — uinput fallback reality check.** **FEASIBLE, PROVEN.** `/dev/uinput`
  is `crw-rw----+` and the Sunshine udev rule
  (`/usr/lib/udev/rules.d/60-sunshine.rules`,
  `KERNEL=="uinput" ... TAG+="uaccess"`) grants the seat user an ACL, so
  `Host/spike/uinput_probe.c` opened it **read-write with no sudo** and
  `UI_DEV_SETUP`+`UI_DEV_CREATE` built a virtual keyboard (kernel sysname
  `input10x`, node `/dev/input/event23`) unprivileged. Injected KEY_A down/up;
  the kernel emitted them — confirmed by evtest-style readback of the event
  node (`value=1` then `value=0`). Readback itself needed sudo because the
  *event node's* `uaccess` ACL is granted to the physically-logged-in seat
  session, not to our SSH login — an SSH-seat artifact of the readback, NOT an
  injection failure; a process inside the graphical session (where the host
  runs in production) reads it freely. No `python3-evdev` and no `evtest` on
  pup (used raw C instead).
- **Q6 — video path undisturbed?** Pending pup's return: re-run a plain 3 s
  `lyte-host --seconds 3` portal video capture and confirm the 36-byte
  `portal_token` is byte-identical and capture still clean. The spike touches
  only `portal_rd_token`; the portal path never reached Start (so never wrote
  any token), and the Mutter-internal path uses no token at all, so no
  disturbance is expected by construction.

Consent step the maintainer must perform on pup's screen (only if we still
want the *portal* path for some future non-GNOME target): run
`lyte-host rd-spike --portal --fresh` while physically at pup and approve the
"Allow remote interaction" dialog if GNOME presents one — but on this GNOME
build the headless Start auto-denies before parking a dialog, so treat the
portal path as unavailable here and use the Mutter-internal path, which needs
**no** maintainer action.

## HS-14 — desktop audio capture + Opus encode (committed)

Two new C leaves + a harness, pulled forward from wave 4 (dependency-free);
the wire side (HS-15: AudioFramer, RS 4+2, DSCP 48, pacing) is NOT here.

- `CPipeWireAudio`: pw_stream CAPTURE of the **default sink's monitor** via
  `PW_KEY_STREAM_CAPTURE_SINK "true"` — no registry scan or node pinning
  needed (unlike video's portal-node-by-serial dance); the session manager
  links to the default sink's monitor ports and follows default-sink
  switches. Negotiates **F32 interleaved 48 kHz stereo** (PipeWire-native,
  no resample stage), `node.latency 240/48000` requests the 5 ms quantum
  and pup's graph honors it (240-frame buffers delivered). Timestamps:
  `pw_stream_get_time_n().ticks` is the graph position at the END of the
  delivered data (units of `pw_time.rate` = samples); buffer start =
  ticks − n_frames, converted to µs. Never wall clock.
- `COpusEncode`: libopus 1.6.1 (apt `libopus-dev`, new `COpus` system-lib
  target via pkg-config `opus`), pinned 48 kHz stereo
  `OPUS_APPLICATION_RESTRICTED_LOWDELAY`, 240-sample frames, hard CBR
  default (dialect), **DTX forced off** (silence must keep 200 pkt/s —
  cadence is the receiver's clock), plus the decoder half for loop-decode
  verification and the client's eventual PLC path.
- `lyte-audio-check [seconds] [bitrate] [--vbr]`: monitor → 5 ms packets →
  length-prefixed `/tmp/lyte-audio-check.pkts` + decode-back
  `/tmp/lyte-audio-check.wav`; exits nonzero if the gate is violated.

Gate evidence (pup, 2026-07-20): silence 10 s hard CBR 128 kbps →
1970 packets, **200.0 pkt/s**, constant 80 B, ts deltas avg exactly
5000 µs, 0 non-monotonic, 2/1969 outside ±1 ms (one complementary
2334/7666 pair at stream start — graph rate-match wobble); decoded WAV
9.85 s pcm_s16le 48 kHz stereo, ffmpeg clean, −91.0 dB (digital silence).
Tone run (440 Hz sine via `pw-play`, `--vbr` evidence mode): 200.0 pkt/s,
deltas 4999–5001 µs, decoded WAV mean −24.1 dB — real signal through the
loop; VBR silence contrast: 3 B packets vs 72–117 B with tone. Hard CBR
pads silence to the same 80 B as signal (expected; that's what CBR means —
use `--vbr` when you need size-based evidence the pipeline is live).
Regressions: 19/19 Mac tests; 3 s portal video capture still clean
(182 packets, 1 IDR, ffmpeg decode clean).

## Audio continuity decisions

The 2026-07-20 assessment in
`docs/20260720-145840-audio-continuity.md` accepts NetEQ’s useful ideas but
rejects vendoring NetEQ. Measurements identify delay variance, not packet
loss, as the dominant impairment.

H2 host send requirements:

- Priority: input/control > audio > fresh video > complete video.
- Pace video across its frame interval at negotiated bitrate; never let a
  line-rate IDR burst trap 5 ms audio packets.
- Keep host-NIC audio inter-send intervals at 5 ms ±2 ms at p99 during a
  worst-case IDR; no audio waits behind more than one video batch.
- Use DSCP 48 / `SO_PRIORITY` 6 for audio and DSCP 40 /
  `SO_PRIORITY` 5 for video.
- Derive audio RTP timestamps from the PipeWire capture clock in Sunshine’s
  packetDuration-ms units.

Current CELT-only, 5 ms, `OPUS_APPLICATION_RESTRICTED_LOWDELAY` audio plus
4+2 RS FEC makes Opus in-band FEC and RFC 2198 redundant audio poor fits.
They target loss that measurements do not show and do not address delay
variance.

Pinned M7 receiver order:

1. Lock-free SPSC render ring.
2. Accelerate-only WSOLA recovery after bursts.
3. Percentile-based predictive target-delay controller.
4. libopus PLC.
5. Measured clock-skew correction.
6. A measured 10 ms `packetDuration` experiment.

## Hard-won protocol and implementation notes

*(Items 1–5 and 8 describe the GameStream scaffolding — relevant only until
its deletion; items 6, 7, and 9 are general macOS/client lessons that
outlive it.)*

1. Encrypted RTSP framing:
   `[typeAndLength BE32 | 0x80000000][seq BE32][tag 16][ciphertext]`;
   IV = `LE32(seq) ‖ 0*6 ‖ "CR"` client→host and `"HR"` host→client.
2. RTSP uses one TCP connection per transaction, but `encSeq` increases across
   the entire handshake. Keep one `SeqCounter(start: 0)`.
3. SDP whitespace is load-bearing: retain the trailing space before each CRLF
   and the double space in `m=video <port>  \r\n`.
4. Control-v2 uses 12-byte GCM IVs with `"CC"`/`"HC"` direction suffixes.
   Sunshine advertises `encSupported=0x5`.
5. `RtspHandshake` must pass `riKey` into `RtspClient`; omitting it silently
   disables encrypted RTSP.
6. An AppKit CLI must run `NSApplication.run()` on the raw C main thread.
   Running it inside `AsyncParsableCommand.run()` starves main-queue display
   attachment and produces a black window despite good packet statistics.
7. The stream view must accept first responder and handle key events; otherwise
   unhandled keystrokes trigger `NSBeep`.
8. The ENet SwiftPM module map must use only `enet/enet.h` as its umbrella.
9. Keychain private keys must be generated in place with
   `SecKeyCreateRandomKey(kSecAttrIsPermanent)`; `SecItemAdd` to unsigned
   binaries fails on macOS 26.

Golden client↔Sunshine evidence is local and gitignored:
`captures/golden-20260720-130325.pcap` plus matching `.meta.txt`. It contains
encrypted RTSP, HTTPS launch, control-v2, video RTP, and audio RTP. Per the
Lyte-UDP decision it is no longer a host acceptance oracle — keep it as
historical reference for the payload interior formats (HEVC depacketization,
RS FEC, Opus framing) that carry into the new envelope. Keep raw session
keys out of git; commit only distilled vectors under `Tests/`.

## HS-5 (2026-07-21): host video-channel wiring — Mac leg done, pup leg pending

- `Host/` now depends on `../Wire` (first host-side cross-package link) and
  grows the cross-platform `HostWire` target: `VideoChannel` (Annex-B packet →
  VideoPacketizer/FEC → paced datagram blobs + PacerClass tags → send sink;
  sans-IO, owns its Pacer until audio joins the send loop) and `SniffFormat`
  (the `lyte-host sniff` line formatter, output pinned by Mac tests).
- Pacer-class ruling for the slice: everything is `.freshVideo`; keyframe
  shards enqueue `urgent` (within-class jump only). The fresh/tail split
  waits for the ratchet/NACK era, which is what would produce tail traffic.
- Capture timestamps: `capture.c` now negotiates `spa_meta_header` and hands
  the frame callback `graph_us` (compositor pts → pw_time → CLOCK_MONOTONIC
  fallback chain). Repeated/ratcheted frames carry the retained frame's stamp.
- Linux-only (UNCOMPILED — pup down all slice, ssh times out): lyte-host
  `--wire-out HOST:PORT [--wire-rate-mbps N]` (WireOut.swift: drains pacer on
  the loop thread, sendmmsg batches, TOS 0xA0) and `lyte-host sniff --port N`
  (Sniff.swift). First action when pup returns: `swift build` + a live
  `--wire-out` → `sniff` loopback run there.
- Gate evidence on Mac: 26/26 green — 13 corpus frames → 214 datagrams, all
  ≤1152 B, 16.4% seeded loss (parity limit per group) → VideoAssembler →
  byte-exact, capture µs verbatim end to end, batches ≤1 ms quantum.

## HS-12 (2026-07-21): connection-ID migration — Mac gate done, live rebind pending pup

- `HostWire` grows the sans-IO migration logic (pure Swift, injected clock
  + RNG, all Mac-tested): `ConnectionId` (8 opaque random bytes — the W0
  `tlv-reserved-types` vector's width — as TLV type 0x01's VALUE codec),
  `PathChallenge`/`PathResponse` (fixed 10 B CTRL bodies, types 0x03/0x04
  pinned host-side because W4a's registry stopped at 0x02; ARQ-exempt on
  purpose — the challenge must travel on the exact unvalidated tuple),
  and `SessionPath`/`PathValidator` (the decision machine).
- **PROMOTE-TO-LyteWire FLAG (for the CL migration slice):** the
  ConnectionId TLV value codec and the 0x03/0x04 path-message codecs must
  be byte-identical on the client (it tags its datagrams and echoes
  challenges). Both files touch only LyteWire types so the promotion is a
  `git mv` into Wire/Sources/LyteWire; delete the HostWire copies then.
- State machine per candidate tuple: unknown ─known-conn-id-datagram→
  PROBING (fresh random token challenged on the new tuple, one probe slot,
  no eviction by flooding) ─token+tuple-matched echo→ PRIMARY (old primary
  → FALLBACK for 3 s, `freshKeyframeNeeded` fires exactly once) /
  ─1 s timeout→ unknown (re-probe mints a NEW token; stale tokens are
  dead). Anti-amplification: until validated, bytes to a tuple ≤ 3× bytes
  received from it (QUIC §8's factor); the 45 B challenge itself is
  accounted, withheld under runt datagrams, and released when later bytes
  afford it. Media never targets an unvalidated tuple (flows to primary
  until promotion; the budget is the backstop).
- Fresh-IDR wiring: `takeFreshKeyframeRequest()` is the encoder-loop poll
  (same shape as a client 0x0302), whose forced IDR enters `VideoChannel`
  as `isKeyframe: true` → urgent class (HS-5's within-class jump).
  `VideoChannelConfig.connectionId` (nil = pre-HS-12 bare envelope) tags
  EVERY outgoing datagram with the TLV — QUIC's every-packet rule; 11 B
  (~1%) per datagram; worst case 24+11+1112 = 1147 ≤ 1152 B.
- Gate on Mac (33/33 green): challenge on B only after the rebind, never
  before; amplification cap held pre-validation; echo promotes B; IDR
  signal exactly once; fallback retained then aged out; spoofed conn-id
  from C never promotes (wrong token, right-token-wrong-tuple, timeout,
  stale-token-after-reprobe all rejected). Modeled resume 79.6 ms ≤
  400 ms = RTT 30 (hotel-grade, G5 profile) + encoder tick 16.7 + IDR
  drain 7.9 (real corpus IDR through the real pacer at 20 Mbps) + one-way
  15 + client decode 10.
- Deferred to pup's return: the Linux send-loop rebind itself (thin —
  execute PathValidator events: connect() to the promoted tuple, send
  challenges via CNetIO, feed the demux trigger from recvmmsg source
  addresses) and the live G7 roam run. (HS-7 landed most of this: the
  demux trigger is fed from recvmmsg source addresses, promotion
  executes connect(); only challenge-to-unvalidated-tuple sends still
  need CNetIO sendto.)

## HS-7 (2026-07-21): host session stub — Mac gate done, J-G1 LIVE RUN pending pup

- `HostWire.Session` is the sans-IO session core: Noise IK **responder**
  (fresh NoiseSession per msg1 attempt; version byte inside the IK
  payload per W5; no hello beyond the handshake — the session-start
  beacon is the first sealed word), holds the NoiseTransport, seals
  EVERY outbound datagram (video shards, beacons, path challenges) with
  header-bytes-as-AAD — the client seam's exact discipline. `--insecure`
  (CP-3) is the same wiring with a passthrough seal; geometry is
  mode-identical by construction. 1 Hz ClockBeacon on CTRL plus one at
  establishment; BeaconEcho → offset/RTT samples (min-RTT-gated
  estimate kept) and the W4a lastEcho mirror on the next beacon.
  HS-12 integrated: conn-id TLV minted at init and on every datagram,
  inbound feeds the PathValidator demux trigger pre-unseal, challenges
  ride sealed CTRL to the exact probed tuple, and
  `takeFreshKeyframeRequest()` merges path-promotion IDRs with client
  0x10 IDR requests into one encoder poll. All traffic classes ride
  VideoChannel's pacer (control enters via `enqueueControl`).
- **Handshake carriage pinned host-side (promote with the CL Noise
  slice):** CTRL types 0x05 (msg1, client→host) / 0x06 (msg2,
  host→client), payload = type byte ‖ raw Noise message, UNSEALED
  (pre-transport; IK messages are self-protecting). Host-side `IdrRequest`
  mirrors the client's 0x10 codec byte-for-byte (root package can't be
  imported from Host/); both copies promote into Wire together.
- **Budget accounting fix (the reason packetization moved in-house from
  LyteWire.VideoPacketizer):** the frozen Wire geometry table fills
  shards to 1112 B, exact only for a bare envelope. With the HS-12
  conn-id TLV (11 B) AND the Noise tag (16 B), a full shard bursts 1152
  (24+11+1112+16 = 1163). VideoChannel now derives geometry from the
  same parity ladder at the real headroom: shard ≤ 1101 B with the TLV
  (24+11+1101+16 = 1152 exactly), 1112 without; the tag is reserved in
  insecure mode too so FEC geometry never depends on crypto mode (§4.2).
  Challenge budget accounting updated 45 → 61 B (sealed challenge).
- Mac gate (SessionGateTests, 37/37 total green): full in-process
  loopback — host Session responder + LyteWire NoiseSession initiator
  holding the host's static; 1-RTT handshake; 13 corpus frames → 216
  sealed datagrams → client unseal → VideoAssembler byte-exact, capture
  µs verbatim; synthetic echo recovers offset 2 500 000 µs / RTT
  10 000 µs exactly and beacon 1 mirrors it; client 0x10 raises the
  keyframe poll exactly once and the forced IDR reaches the wire as
  urgent keyframe shards; conn-id-bearing datagram from a new tuple
  draws a sealed challenge routed to that exact tuple; `--insecure`
  delivers the same frames plaintext. Every session datagram ≤ 1152 B
  with the TLV present.
- Host static key: `~/.config/lyte-host/noise_static.key` (raw 32 B,
  0600, like the portal token); generated on first run, pubkey hex
  printed for the client to pin out-of-band.
- Linux (UNCOMPILED — pup down all slice): CNetIO recv slots now carry
  src_ip/src_port (recvmmsg msg_name; slot struct grew — the three
  Swift construction sites updated to zero-init+assign), lyte-host
  `--wire-out HOST:PORT` is now a real session (Noise default: block for
  msg1, adopt+connect, then capture→encode→Session→CNetIO;
  `--insecure`: stream immediately), `--wire-listen PORT` binds a fixed
  port, WireOut.swift replaced by SessionWire.swift, forced-IDR poll
  wired into the encoder call, idle-floor tick doubles as the
  between-frames service point (inbound + 1 Hz beacon).
- **J-G1 LIVE RUN pending pup** — first commands when it returns:
  1. `rsync -a --delete --exclude .build Wire/ pup:src/Wire/`
  2. `rsync -a --delete --exclude .build Host/ pup:src/lyte-host/`
  3. On pup: `cd ~/src/lyte-host && LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build`
     (first Linux compile of the HS-5/7/12 legs), then
     `swift run lyte-netio-check` (re-verify the grown recv slot on
     loopback).
  4. Host: `lyte-host --backend portal --wire-listen 47998 --seconds 330`
     — prints the static pubkey; hand it to the client.
  5. Mac client: `Scripts/build-cli.sh`, then lyte-cli wire-view against
     `10.0.0.249:47998`. NOTE: the client's Noise transport-open (CL-1
     leg) is still `noisePending` — if it hasn't landed, run the gate
     once with `--insecure` on BOTH ends (host `--wire-out MAC_IP:PORT
     --insecure` against `lyte-cli wire-view --insecure`), per the CP-3
     ruling, and MANDATORY re-run with Noise when the client leg lands.
  6. Inject 1% loss on pup's egress (adapt `Scripts/netem/lo-netem.sh`
     to the LAN iface, or `sudo tc qdisc add dev <iface> root netem loss 1%`).
  7. Confirm: window renders; `sudo tcpdump -v -i <iface> udp port PORT`
     shows per-packet tos 0xa0 (DSCP 40) on video and 0xc0 on CTRL;
     kill/corrupt the stream → client 0x10 → fresh IDR heals; client
     logs beacon offset; ≥5-min soak with both ends' (chan, seq, frame)
     accounting logs in agreement.

## RESUME HERE — 2026-07-21 ~11:05 MDT (written before a Cursor restart)

- The section above is PARTIALLY STALE: the insecure J-G1 ran and PASSED
  in full (5.5-min soak, 19,800/19,800 frames byte-exact, FEC heal under
  5% netem, DSCP verified, ~15 ms fresh-frame latency; details earlier in
  this file). CP-5 upgraded to "pixels moved" (Mutter RemoteDesktop is
  HS-13 primary; portal is hostile headless).
- Since then, four more commits landed (through `0443beb`): the codec
  promotions into Wire/ (conn-id TLV, path 0x03/0x04, Noise carriage
  0x05/0x06, IDR 0x10) and the CLIENT NOISE LEG — `NoiseTransportCrypto`
  is real (IK initiator, sealed payloads); `wire-view` grew `--host-key`.
- THE ONLY REMAINING H0b ITEM: the live ENCRYPTED J-G1 re-run (CP-3's
  mandatory re-gate) + the human visual. Sequence: rsync Wire/ →
  pup:src/lyte-wire/ and Host/ → pup:src/lyte-host/ (siblings); build both
  with LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat; pup+Mac test suites
  green; pup: `./.build/debug/lyte-host --wire-listen 41000 --seconds 330`
  (prints pubkey); Mac: `swift run lyte-cli wire-view 41000 --host-key
  <hex>`; verify handshake/soak/netem-heal/DSCP/beacon; netem off;
  Sunshine + tokens intact.
- A worker (a773fa89) was mid-flight on exactly that when this note was
  written; it may have died with the restart — check `git log` for its
  fixes and just re-run the sequence above if its verdict never arrived.
- After the re-gate: open the H1 wave — W3 ARQ, W4b state machine,
  W6 PAKE, W7 capabilities, HS-8, CL-10 clock model, HS-9/CL-6 pairing,
  HS-10/CL-5 discovery. Plan of record: docs/20260720-222500 master plan.
- Repo: ~26 commits ahead of origin/main, unpushed by convention.
- Operational notes: subagent launches were chronically stalling all
  session (1 tool call then silence, needed interrupt-kicks ~every 8 min;
  a 7-min watchdog loop pattern worked well) — possibly related to the
  pending Cursor security approval that prompted this restart. pup
  crashed/dropped off-network twice in 24 h (hard down ~00:15–04:20);
  if unreachable, check power/Wi-Fi physically.
