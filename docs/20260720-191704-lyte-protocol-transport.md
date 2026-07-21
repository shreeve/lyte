# Lyte Protocol: Transport & Session Architecture (2026-07-20)

*One of four pillar documents for the native Lyte protocol. This one owns the
skeleton: wire transport, channels, framing envelope, negotiation, crypto,
session lifecycle. Siblings own image quality/codecs, timing/pacing, and
resiliency/FEC — where a sibling owns a policy, this doc defines the envelope
and stays out of the semantics. Builds on tonight's decisions (damage-driven
video; IDLE = sparse frames + liveness on a reliable channel; ACTIVE =
unreliable datagrams; idle→active = fresh IDR; explicit mode transitions;
negotiated superpowers; H6 = one `lyte` binary) and on
docs/20260720-184200-browser-client-caddy-bridge.md (browser client = same
Swift protocol layer in WASM behind a protocol-dumb Caddy bridge).*

## TL;DR

**QUIC is the native transport** — one connection, streams + datagrams
(RFC 9000/9221), carried by **swift-nio-quic** (Apple's Swift-native QUIC,
open-sourced June 2026), with **msquic via C FFI as the fallback of record**
behind a one-week validation spike. Mutual authentication and end-to-end
payload encryption live **above** the transport in a Noise-IK session layer
keyed by the existing PIN-pairing trust model, so the Caddy bridge relays
WebTransport↔QUIC without ever holding session plaintext — the bridge stays
protocol-dumb *and* untrusted. A custom-UDP reliable layer and a homegrown
QUIC subset were both considered and rejected (§1). The GameStream compat
dialect and the native transport are front-ends on one session core (§6);
native lands as H2.5, after the compat dialect has verified H0–H2 (§7).

---

## 1. The core decision: QUIC vs custom UDP vs hybrid

Three candidates, weighed honestly:

**Custom UDP with a reliable sublayer (ENet-style).** Total control of every
byte and every send instant; zero new dependencies; DSCP per socket for free.
But it re-invents, from scratch and solo: a TLS-equivalent handshake, a
reliable/ordered sublayer with its own ACK/RTO machinery, connection
migration, PMTU discovery, and anti-amplification — each one a place where
QUIC already encodes a decade of deployed lessons (RFC 9000, RFC 9002). The
disqualifier, though, is the bridge: the browser edge is WebTransport
(streams + datagrams over HTTP/3), and a custom protocol forces the Caddy
module to *translate semantics* — associate flows, track session state, map
reliability classes — making it protocol-aware, stateful, and trust-bearing.
The bridge doc's whole premise is a dumb relay. Parsec's BUD proves the
custom path is viable for a funded team (custom CC + DTLS 1.2 over UDP,
[parsec BUD](https://medium.com/parsec/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007));
it is the wrong trade for one maintainer who also owns a bridge.

**A minimal homegrown QUIC subset** is folly, and worth saying plainly: RFC
9000's machinery interlocks (loss recovery ↔ CC ↔ flow control ↔ TLS key
schedule per RFC 9001); every "minimal subset" grows into a bad, unaudited
QUIC that still doesn't interoperate with WebTransport. Not considered
further.

**QUIC (RFC 9000) with the unreliable datagram extension (RFC 9221).** Buys,
for one dependency: streams with per-stream reliability and no cross-stream
head-of-line blocking; unreliable datagrams; TLS 1.3 handshake and 0-RTT;
connection migration on client IP change (RFC 9000 §9 — the resiliency
sibling's requirement, free); PMTU discovery; and a **1:1 mapping onto
WebTransport** so the Caddy bridge is a byte relay. Costs: a dependency
(priced below), one 5-tuple (the DSCP consequence in §2), and CC/pacing
control that must be verified per-library rather than assumed.

**The dependency, priced in 2026.** The landscape has changed since the
bridge doc's "a QUIC stack is a large, churning dependency" (written when
that was true):

- **swift-nio-quic** ([github](https://github.com/apple/swift-nio-quic)) —
  Apple rewrote its production QUIC transport in Swift and open-sourced it
  (June 2026, [swift.org](https://swift.org/blog/whats-new-in-swift-june-2026/)).
  Pure Swift, Apache-2.0, macOS + Linux (Ubuntu 22.04+), built on
  swift-crypto/swift-certificates — the same crypto family Lyte already
  trusts. **This is the first time "QUIC without a C dependency" is real in
  Swift.** Honest caveats: 0.x API, Swift 6.3+, swift-crypto beta pin, and
  datagram/pacing/priority surface unverified.
- **msquic via C FFI** ([settings](https://microsoft.github.io/msquic/msquicdocs/docs/Settings.html)) —
  mature, cross-platform, ships datagrams, per-stream priority
  (`QUIC_PARAM_STREAM_PRIORITY`), pacing toggle (`PacingEnabled`), and
  per-connection DSCP (`QUIC_PARAM_CONN_SEND_DSCP`). A large C leaf, but a
  *leaf* — boundary-shaped like enet/nanors, consistent with the C-only-at-
  boundaries doctrine, unlike a mid-pipeline C++ engine.
- **quiche via C FFI** — solid (Cloudflare production), but drags a Rust
  toolchain into the build; pacing rides Linux `SO_TXTIME`+FQ, which
  measurably misbehaves under loss ([Kempf et al. 2025](https://zirngibl.github.io/files/kempf2025quicpacing.pdf)).
  Third choice.
- **Quiver** (pure-Swift community QUIC/H3/WebTransport) — encouraging
  existence proof, too young to bet the product on.

**Decision record.** Native transport = QUIC. Primary stack =
**swift-nio-quic**, gated on a validation spike with pass/fail criteria:
(a) RFC 9221 datagrams exposed; (b) app-controlled send timing — library
pacing off or bypassable, because the host paces video deliberately per
docs/20260720-145840-audio-continuity.md §4 and must not have a second pacer
fighting it; (c) socket access for DSCP; (d) sustained 100+ Mbps datagram
flow on Linux without allocation storms; (e) migration works. Any failure →
**msquic C FFI**, no redesign — the transport is wrapped behind one Swift
facade (`LyteTransport`: open/close connection, open stream, send datagram,
callbacks) either way. Latency control is *verified adequate*, not perfect:
RFC 9221 datagrams are congestion-controlled and ack-eliciting; the
resiliency sibling owns CC policy and gets a pluggable-CC requirement in the
facade contract.

## 2. Channel model

One QUIC connection per session. Channels, delivery class, and mapping —
identical over native QUIC and over WebTransport through the bridge
(WebTransport exposes exactly bidi streams, uni streams, and datagrams;
[W3C WD 2026-07-06](https://www.w3.org/TR/webtransport/),
[draft-ietf-webtrans-http3-16](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/);
Baseline in all major browsers since Safari 26.4, March 2026):

| Channel | Carrier | Delivery | Priority | Notes |
|---|---|---|---|---|
| CTRL | one bidi stream, client-opened, lives for the session | reliable, ordered | highest | handshake, capabilities, Noise IK, input, mode transitions (IDLE⇄ACTIVE), IDR requests, liveness beacon, takeover |
| Audio | datagrams (`chan=1`) | unreliable, sender-paced | audio-first dispatch | envelope only; packetization per audio doc |
| Video-active | datagrams (`chan=2`) | unreliable | after audio | ACTIVE mode media path |
| Video-idle | one uni stream **per sparse frame**, host-opened | reliable | below audio | stream-per-frame avoids inter-frame HOL blocking (the pattern MoQ standardized as subgroup-per-stream, [draft-ietf-moq-transport-19](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/)) |
| Feature channels | one bidi stream per feature, opened on demand | reliable, ordered per feature | below media | clipboard (H3), files/printing (H5) — separate streams so a file transfer never blocks a clipboard paste; no new connections ever |
| Telemetry | datagrams (`chan=3`) | unreliable | lowest | stale telemetry is worthless; session-end summary rides CTRL reliably |

Send-side ordering is the audio doc's rule, now transport-wide: **CTRL/input
> audio > fresh video > everything else**, enforced in our sender (and via
per-stream priority where the stack exposes it), with the measurable
acceptance criterion already pinned there (audio inter-send 5 ms ± 2 ms p99
during a worst-case IDR).

**DSCP: the honest QUIC cost.** One QUIC connection is one 5-tuple, and no
mainstream stack marks DSCP per-packet (msquic: per-connection), so the
decided 48-audio/40-video split cannot be expressed inside one connection.
Resolution of record: the native connection is marked **DSCP 40** (video
class); audio's protection comes from send scheduling (which we control and
measure) rather than network marking. Where DSCP 48 mattered most — Wi-Fi
EDCA VO access on the downlink — the H2.5 A/B against the compat dialect
(which keeps per-socket 48/40) will measure the regression, if any. The
escape hatch is reserved as a capability bit, `audio-express`: a second
QUIC connection from the same session identity carrying only audio
datagrams at DSCP 48. It is negotiable without protocol surgery and is
**not built** until telemetry proves it necessary. Browsers can't set DSCP
at all, so the bridge path loses nothing.

## 3. Framing: the datagram envelope

Every datagram begins with a fixed v1 envelope; all multi-byte fields are
little-endian (both ends are ours; no network-order tax):

```
offset size field
0      1    chan      (1=audio, 2=video-active, 3=telemetry; 0, 4–15 reserved)
1      1    flags     (bit0: TLV extensions present; bits1–7 reserved, MUST be 0 on send, ignored on receive)
2      2    seq       (per-channel monotonic datagram sequence)
4      4    frame     (frame number; audio: packet number in audio-doc units)
8      8    timestamp (64-bit; units/epoch/clock owned by the timing sibling)
16     8    fec       (opaque 8-byte FEC group envelope; layout owned by the resiliency sibling — enough for group id, shard index/count, and scheme bits)
24     …    payload
```

24 bytes fixed. Payload budget: envelope + payload ≤ **1152 bytes** — safely
inside QUIC's 1200-byte minimum UDP payload (RFC 9000 §14) after QUIC's own
overhead, and inside typical WebTransport datagram limits so shards transit
the bridge unfragmented. The resiliency sibling shapes shards to this budget;
PMTUD may raise it via a negotiated session parameter, never per-packet.

**Versioning and extension.** Three layers, so a v2 field lands without
breaking v1 peers:

1. **ALPN** carries the wire major version: `lyte/1`. A true incompatible
   break is `lyte/2`, negotiated at connection time, never mid-session.
2. **Capabilities** (§4) gate behavior: new semantics ship as capability
   keys; unknown keys are ignored by rule.
3. **Datagram TLVs**: flags bit0 appends `count:u8 (type:u8 len:u8 value)*`
   after the fixed envelope. Unknown TLV types MUST be skipped. New per-packet
   fields land as TLVs first and are folded into a fixed v2 envelope only at
   an ALPN bump.

Stream-carried messages (CTRL, features, video-idle) are length-prefixed:
`type:u16 len:u32 body`. Unknown message types on CTRL are skipped by rule —
same forward-compatibility contract as TLVs.

## 4. Session lifecycle & negotiation

**Discovery.** Bonjour `_lyte._udp` advertising host identity key hash,
protocol versions, and port — plus manual host:port entry, exactly today's
UX. The rendezvous/hole-punching story (LYTE-PLAN §7) is unchanged; QUIC
migration makes punched paths sturdier, and the relay-shaped hole in the
candidate enumeration survives as-is.

**Pairing: keep the PIN UX, upgrade the crypto.** The user story stays:
enter a PIN once, trust forever after. Underneath, pairing becomes a
**PIN-authenticated key exchange over the CTRL stream**: connect (TLS accepts
the as-yet-unknown peer), run a PAKE (CPace or SPAKE2) on the PIN, bind it to
the connection via a TLS exporter, and on success exchange and **pin the
peers' static Noise public keys** (Keychain / Linux keystore). This replaces
GameStream's SHA256(salt‖PIN)→AES-ECB dance with an actual PAKE and makes the
PIN unbruteforceable offline. Paired identity = the pinned static key, not a
certificate.

**Two crypto layers, deliberately (see §5 for why).**

- *Transport:* QUIC's mandatory TLS 1.3 (RFC 9001) with self-signed
  certificates, **unauthenticated at the TLS layer** by policy (raw-public-key
  TLS per RFC 7250 would also serve, but library support is spotty; not
  load-bearing either way).
- *Session:* **Noise IK** (initiator knows the responder's static key — which
  pairing guarantees; the WireGuard pattern,
  [noiseprotocol.org](https://noiseprotocol.org/noise.html)) runs inside CTRL
  immediately after connect: 1-RTT, mutual authentication against pinned
  statics, forward secrecy. Its output keys AEAD-encrypt **every channel
  payload end-to-end** (ChaCha20-Poly1305; per-channel nonce = chan‖seq‖epoch).

**Capability negotiation.** First messages on CTRL after Noise completes:
each side sends a versioned capability set (CBOR map): protocol minor,
codecs, chroma modes (4:2:0/4:4:4), idle-silence, feature channels
(clipboard/files/printing), `audio-express`, resume support. Rule set:
intersect; unknown keys ignored; capabilities are session-scoped and fixed
after exchange except where a capability itself declares renegotiability.
This is the superpowers handshake — idle-silence now, clipboard H3, 4:4:4
H4, files/printing H5 — as data, not code paths.

**Reconnect and resume.**

- *Client IP change (Wi-Fi→wired, sleep/wake on a new address):* QUIC
  connection migration, transparent; host sends a fresh IDR on migration
  confirmation as cheap insurance.
- *Client sleep/wake, same address:* idle timeout ~30 s; within it the
  connection simply resumes. Past it, **session resume**: at session start the
  host issues an opaque resume token over CTRL; a reconnecting client presents
  it inside the new Noise-authenticated CTRL, and the host restores session
  state (mode, capabilities, feature-channel state) and sends an IDR. Media
  state is never resumed — only re-keyed and re-IDR'd.
- *Host restart:* sessions die; resume tokens are host-epoch-scoped and
  refused after restart. Pairing (pinned keys) survives; the client
  auto-reconnects and re-establishes. Surviving host restarts mid-session is
  explicitly a non-goal.

**Multi-client policy.** One active session per host. A second paired client
connecting completes Noise and capabilities, then receives `session-busy`
carrying the active client's name — and may send `takeover-request`. Host
policy (user-configurable: allow / prompt / deny) decides; on takeover the
old session gets a typed teardown reason (`taken-over-by`) and the new
session starts with a fresh IDR. Explicit, named, designed-in — no ghost
sessions.

## 5. Security posture

**Threat model.** LAN adversaries (passive capture, active MITM on
first-contact, rogue hosts advertising over Bonjour) and, once bridged,
internet adversaries plus a **semi-trusted bridge host**: the Caddy machine
terminates WebTransport TLS (its ACME cert), so whoever operates it could
read anything protected only by transport TLS.

**The two-layer answer.** Transport TLS protects each hop and feeds QUIC's
machinery; the Noise session layer provides mutual authentication and
end-to-end confidentiality of all channel payloads. Direct connections carry
both layers (double AEAD is noise at desktop-streaming rates — ChaCha20-
Poly1305 runs in GB/s per core); bridged connections get their real
protection from the Noise layer. **One code path, always on** — the bridge is
untrusted *by construction*, not by configuration. This is the
differentiator: RDP, Parsec, and PCoIP all terminate their crypto at relay
infrastructure they operate; Lyte's bridge moves ciphertext it cannot read.

**Keys and rotation.** Static Noise keys live in platform keystores, rotated
only by re-pairing. Session keys: fresh per connection (Noise ephemerals);
epoch-based rekey (epoch counter in the AEAD nonce) every 2^24 datagrams per
channel or hourly, whichever first, via a CTRL `rekey` message — cheap,
bounds nonce reuse and key exposure. TLS session tickets may enable 0-RTT
transport resumption, but no application data rides 0-RTT (replay surface;
RFC 9001 §9.2) — the Noise handshake gates everything anyway.

## 6. Coexistence: one session core, two dialects

```
                       ┌────────────────────────────┐
                       │        SessionCore          │  pure Swift (HostCore)
                       │ capture · encode · audio ·  │
                       │ input · features · modes ·  │
                       │ pairing store · telemetry   │
                       └──────┬──────────────┬───────┘
                    frames/events        frames/events
                       ┌──────┴─────┐  ┌─────┴────────┐
                       │ GameStream │  │ LyteDialect  │   per-dialect leaves
                       │  Dialect   │  │              │
                       │ RTSP·ENet· │  │ QUIC·Noise·  │
                       │ RTP+RS-FEC │  │ chan framing │
                       └──────┬─────┘  └─────┬────────┘
                          UDP/TCP        QUIC (UDP)
                              │              │            ┌─ browser (WASM client,
                        Moonlight/      native client ────┤  same Swift protocol
                        Lyte clients    or Caddy bridge ──┘  layer, WebTransport)
```

Shared (SessionCore, pure Swift): capture, encode facade, audio pipeline,
input injection, feature logic (clipboard/files/printing), idle/active mode
state machine, pairing trust store, telemetry. Per-dialect: handshake
(RTSP/pairing-HTTPS vs QUIC/Noise/capabilities), control encoding (ENet
control-v2 vs CTRL messages), media packetizers (RTP+RS-FEC vs datagram
envelope + sibling FEC), and socket/DSCP handling. Both dialects can listen
concurrently; a session binds to exactly one. This is the existing Host/
layout's doctrine — transport-agnostic engine, packetization as a leaf —
with the second leaf now specified. The compat dialect never gates the
native one: GameStream keeps stock Moonlight clients working; superpowers
are native-only.

## 7. Migration plan

MoQ, for the record: draft-ietf-moq-transport-19 (July 2026) is a
pub/sub-through-relays protocol — the wrong shape for point-to-point remote
desktop, and not RFC before 2027. **Steal, don't adopt**: stream-per-group
for video-idle, priority-and-drop semantics for the resiliency sibling.

Sequencing (my call, consistent with the H-ladder's verifier discipline):

- **H0–H2 stay 100% GameStream compat.** The shipping client is the only
  trustworthy oracle; nothing about the native transport may touch the
  H0a→H2 critical path.
- **H2.5 — native transport thin slice** (after H2's "daily-drivable"
  acceptance, before H3): the transport validation spike (§1 gates), then
  one QUIC connection carrying CTRL (Noise IK + capabilities + input) +
  video-active datagrams + video-idle streams, host `--native-listen` flag,
  client `lyte://` toggle. Acceptance: the Mac client streams the `pop`
  desktop over the native transport, idle→active transitions with fresh IDR
  work, and an A/B against the compat dialect measures the audio DSCP
  question (§2). Media crypto may stub through TLS-only for the first week
  of the slice, but the slice does not pass without Noise e2e on.
- **H3 — clipboard rides the native feature channel.** Amended from
  LYTE-PLAN's Stage-2 "extension channel over the GameStream wire": with
  H2.5 landed, building the feature channel twice (once over ENet, once
  native) is waste. Superpowers are the native dialect's reason to exist;
  compat clients simply never see them. (If H2.5 slips badly, the ENet
  extension channel remains the recorded fallback.)
- **H4–H6 unchanged**, native transport hardening in parallel (migration,
  resume, rekey soak). Pairing-crypto upgrade (PAKE) lands with H2.5's Noise
  work — one crypto push, not two.
- **Post-H6:** the Caddy bridge (per its own doc) — which, with this design,
  relays streams↔streams and datagrams↔datagrams and nothing else.

First thin slice that proves the transport end-to-end: **CTRL echo + input
+ video datagrams to the debug client** — two weeks of work sitting entirely
in new leaves, touching zero compat code.

## References

RFC 9000 (QUIC), RFC 9001 (QUIC-TLS), RFC 9002 (loss/CC), RFC 9221
(unreliable datagrams), RFC 7250 (raw public keys);
[WebTransport W3C WD 2026-07-06](https://www.w3.org/TR/webtransport/) (CR
track, Recommendation targeted Aug 2026; Baseline since Safari 26.4);
[draft-ietf-webtrans-http3-16](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
(WGLC); [draft-ietf-moq-transport-19](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/);
[Noise protocol](https://noiseprotocol.org/noise.html) (IK pattern;
WireGuard precedent); [swift-nio-quic](https://github.com/apple/swift-nio-quic);
[msquic settings](https://microsoft.github.io/msquic/msquicdocs/docs/Settings.html);
[QUIC pacing evaluation, Kempf et al. 2025](https://zirngibl.github.io/files/kempf2025quicpacing.pdf);
[Parsec BUD](https://medium.com/parsec/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007);
[MS-RDPEUDP](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeudp/fe211d97-92dd-47e6-8fa3-b23f2c1a5af9).
