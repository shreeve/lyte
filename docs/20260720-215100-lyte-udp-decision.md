# Lyte-UDP: The Only Protocol (decision record, 2026-07-20)

## TL;DR

**lyte-host will never speak the GameStream dialect. Lyte-UDP — our own
protocol over plain UDP datagrams — is the only protocol the host ever
implements.** Maintainer's directive tonight, near-verbatim: *"DROP EVERYTHING
BUT Lyte-UDP."* This settles the transport question in the same stroke:
homegrown Lyte-UDP over plain UDP (topology **T1 dumb-relay**), QUIC rejected
for v1. The end state is **pure Lyte-UDP everywhere, client included** — no
long-term dual-protocol ambition. The macOS client's battle-tested GameStream
stack is frozen scaffolding effective immediately: zero new work, kept
compiling only because it is the working streaming path against Sunshine
during the transition, and **deleted as soon as it stops being load-bearing**
(target: when the Lyte-UDP client path streams the desktop end-to-end, the
H0b/H1 era; at the absolute latest at H2 parity). Sunshine's only remaining
role is bootstrap crutch on the host machine until Lyte↔Lyte streams; then
it is uninstalled. This supersedes the compat-first sequencing in LYTE-PLAN §5–§6,
docs/HOST-PLAN.md §4/§6, and the H2.5/DSCP rulings in the protocol overview
(20260720-193000). The four pillar docs remain the protocol spec; only their
QUIC and compat-dialect assumptions are overridden.

## 1. The reasoning chain

1. **We own both ends.** The whole point of LYTE-PLAN §2 was to control host
   and client together.
2. **Interop was the dialect's only value.** Everything else about the
   GameStream wire — RTSP framing quirks, ENet, the ECB pairing dance — is
   legacy we were reproducing solely so third-party peers could connect.
3. **No third party needs to connect.** Our client is the only client;
   Sunshine's job ends at parity. A protocol whose sole virtue is
   compatibility with peers we don't serve is pure cost.
4. **The verification-risk argument collapses.** The strongest case for the
   dialect (browser-bridge doc §1: "two unproven ends debugging each other")
   assumed a wholly new protocol. Lyte-UDP v1 is not wholly new: it is a
   **new skeleton around proven organs** — the client's soak-tested HEVC
   depacketization layout, the Reed-Solomon FEC math (nanors-compatible),
   and the Opus audio framing all carry over inside the new envelope. The
   ambiguous-bug surface shrinks to the envelope/handshake/reliable layer,
   which is small, ours, and testable in isolation.

The maintainer's five arguments, recorded: **total control** of every byte
and send instant; **pure Swift, lightweight** (no protocol-stack dependency);
**Tailscale-transparent** (plain UDP traverses it natively); **no external
requirements** (nothing to vendor, pin, or track); **focus** (one wire to
build, one wire to debug, one wire to document).

The corollary that finishes the chain, also the maintainer's reasoning:
**dual support is a split brain** — the two envelopes share the
media-pipeline interior, so every refactor and bug carries double surface.
"One protocol, one host, one client per platform" is the product; the
client's GameStream stack is scaffolding to remove, not a mode to maintain (§3).

## 2. What is dropped

lyte-host never implements any of the following. Not deferred — dropped:

- The RTSP handshake (plain or `rtspenc://`).
- The ENet control channel and control-v2 GCM envelope.
- The GameStream RTP layout (frame headers, `streamPacketIndex`, `fecInfo`
  packing, RTP `0x90`, SS_PING gating, `X-SS-Ping-Payload`).
- The HTTPS pairing dance (SHA256(salt‖PIN)→AES-ECB, cert pinning ceremony).
- Moonlight-client compatibility, Sunshine byte-exactness, and the
  golden-pcap acceptance gates for the host.
- The decaying-heartbeat compat mode. Idle silence + damage-only video
  (reliable sparse idle frames, IDR-on-wake) are Lyte-UDP's **default
  behavior**, not a negotiated extra.
- The "H2.5 native transport upgrade" sequencing (overview §3, question 2):
  void — there is no upgrade because there is no compat protocol to upgrade
  from.
- The single-connection DSCP compromise (overview §2 DSCP row, conflict 7):
  void — we own the UDP socket outright, so per-packet TOS/DSCP via
  `sendmsg` cmsg is available from day one. The audio doc's original
  commitment is restored: **DSCP 48 audio / 40 video, per packet.**

## 3. What survives

- **The pillar docs are the protocol spec.** The 24-byte datagram envelope,
  connection IDs, 1152-byte payload budget, Noise-based end-to-end crypto,
  PIN-as-PAKE pairing, app-level congestion control (burst-dispersion
  estimator, `RateBudget`), the FEC+NACK+IDR hybrid, the ≤1 ms pacer, the
  ACTIVE/IDLE/FROZEN/RECOVERY machine, the priority order, the beacon, the
  quality ratchet — all stand exactly as written. Only the QUIC carriage and
  compat-dialect assumptions are overridden (adjudications in §8).
- **The proven payload interiors**, reused inside the new envelope: HEVC
  depacketization layout, RS FEC math (nanors-compatible), Opus framing.
- **The client's GameStream stack — temporarily, as frozen scaffolding.**
  Zero new work, zero enhancements; it keeps compiling only because it is
  the working streaming path against Sunshine during the transition. It is
  **deleted as soon as it stops being load-bearing** — target: when the
  Lyte-UDP client path streams the desktop end-to-end (H0b/H1 era), and at
  the absolute latest at H2 parity. Deletion is the default, not a decision
  point; git history and the protocol docs preserve everything if it is
  ever needed again. Sunshine is likewise a bootstrap crutch on the host
  machine only — uninstalled once Lyte↔Lyte streams.
- **The golden pcaps**, demoted from acceptance oracle to historical
  reference for the payload interior formats.

## 4. The QUIC rejection, honestly

The scout's verdict on swift-nio-quic was **workable-with-friction**, not
broken: the RFC 9221 datagram API is gated behind SPI, the package requires
Swift 6.3+, the API is 0.x and churning, and adopting it pulls a 9-package
dependency tree into a host that otherwise needs nothing beyond a UDP
socket. Against that, the honest accounting of what QUIC would still buy us
shrank to almost nothing: congestion control, pacing, FEC, and recovery were
already app-level in the pillar designs (QUIC's own CC was to be bypassed),
and the only reliable-delivery consumers are the control/input channel,
sparse idle-mode frames, and the final ratchet frame — a **few-hundred-line
ordered-retransmit sublayer**, not a transport stack. The transport pillar's
custom-UDP disqualifier (the bridge would have to translate semantics) is
dissolved by T1: the bridge is now a dumb datagram relay (§6).

QUIC is rejected for v1, not forever: if swift-nio-quic matures (datagrams
out of SPI, 1.0 API), it can be re-evaluated. The `LyteTransport` facade
keeps the carrier swappable; nothing above the socket knows it is plain UDP.

## 5. The new H-ladder

Replaces the GameStream-shaped H0b–H6. H0a is unchanged and partially
complete (slices 1–2 committed).

- **H0a (in progress).** Portal capture → NVENC encode proven headless —
  done. The old "Sunshine-dialect RTP+FEC into the debug client" slice is
  **dropped**. Remaining H0a: the quality-ratchet prototype on the existing
  file-output host (already approved).
- **H0b — first pixels, Lyte-UDP.** Envelope v1 + video datagram channel +
  RS FEC on the host; a Lyte-UDP receive module in the client (debug mode).
  Acceptance: the client renders lyte-host's live desktop over the LAN.
- **H1 — honest session.** Noise handshake, PIN-PAKE pairing, discovery
  (Bonjour + manual), session lifecycle, control channel on the reliable
  sublayer, the idle/active state machine including idle silence + reliable
  sparse frames + IDR-on-wake, liveness beacon.
- **H2 — parity.** Input injection (portal RemoteDesktop primary, uinput
  fallback) + audio (Opus per the audio-continuity doc's send pacing;
  per-packet DSCP 48/40) + the congestion/resiliency machinery (app-level
  CC, NACK, FROZEN/RECOVERY). **Exit criteria: Sunshine is uninstalled, and
  the client's GameStream stack is deleted** (earlier if H0b/H1 already made
  it non-load-bearing — deletion happens the moment it stops earning its
  keep, per §3).
- **H3+.** Feature channel (clipboard); 4:4:4 + Work/Play policy + the full
  quality ratchet; files/printing; one `lyte` binary; macOS host — same
  shape as before, all riding Lyte-UDP feature channels.

## 6. Reachability posture

- **LAN:** direct UDP. Bonjour + manual host:port, as today.
- **Remote, native clients (v1 answer):** Tailscale or a port-forward.
  Plain UDP is exactly what these carry best; no rendezvous service ships
  in v1.
- **Browsers (future):** the Caddy module survives, simplified — a **dumb
  WebTransport-datagram ↔ UDP-packet relay** (CONNECT-UDP / RFC 9298
  shape), not a protocol adapter. End-to-end Noise keeps the bridge
  untrusted by construction, exactly as the transport pillar intended.

## 7. What we give up (the honest costs)

- **No Moonlight mobile/TV clients, ever**, unless a compat leaf is added
  later. No iPhone/Android/Apple TV client can connect to lyte-host until
  Lyte clients exist for those platforms.
- **No off-the-shelf debugging dissectors.** Wireshark understands RTSP,
  RTP, and ENet; it will never understand Lyte-UDP. Mitigation: build a
  small `lyte sniff` debug tool eventually (ledgered in TODO.md).
- **We own ARQ correctness and the DoS posture ourselves.** The reliable
  sublayer's retransmit/ordering logic and the pre-handshake packet-flood
  surface are ours to get right, with no RFC 9000 lineage to lean on. The
  sublayer's small scope (three consumers, low rate) is the mitigation, not
  an excuse to skip adversarial tests.

## 8. Adjudications against the pillar docs

Made here so the pillars need no edits; where a pillar says "QUIC stream,"
read the equivalent below.

1. **Channel carriage.** CTRL, video-idle, and feature channels ride the
   homegrown ordered-retransmit sublayer over datagrams instead of QUIC
   streams. The stream-per-sparse-frame HOL-avoidance pattern (transport §2)
   is re-expressed as independent retransmit groups per idle frame.
2. **Crypto layers collapse to one.** The transport pillar's two-layer
   design (TLS 1.3 + Noise) loses its TLS layer; Noise IK is the only
   handshake and the only AEAD. The PAKE's "bind via TLS exporter" becomes
   binding to the Noise handshake transcript. Nothing weakens: the TLS layer
   was unauthenticated by policy and load-bearing only for QUIC's machinery.
3. **Version negotiation.** ALPN `lyte/1` (transport §3) has no TLS to ride;
   the wire major version moves into the first handshake datagram. The
   capability and TLV layers are unchanged.
4. **Migration.** QUIC connection migration (transport §4, overview roam
   walkthrough) becomes ours: the envelope's connection IDs already identify
   the session independent of the 4-tuple — the resiliency pillar assumed
   exactly this — so path change = validate new address, fresh IDR, same
   FROZEN/RECOVERY ladder.
5. **Overview open questions 1–4 are answered**: (1) QUIC — no; (2) H2.5 —
   void; (3) v1 DSCP posture — reversed, per-packet 48/40 restored; (4) the
   ratchet — prototyped now, on the H0a file-output host.

The pillar rulings on resiliency, timing, and quality are untouched by any
of this; they were app-level all along, which is precisely why dropping QUIC
was cheap.
