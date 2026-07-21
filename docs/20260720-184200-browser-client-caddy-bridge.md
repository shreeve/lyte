# Browser Client via Caddy WebTransport Bridge (design consult, 2026-07-20)

*(Amended same evening — see the §6 addendum: the Lyte-UDP decision
supersedes this doc's host-protocol premise; the bridge concept survives,
simplified to a dumb datagram relay.)*

## TL;DR

Plan of record for a **post-H6** enhancement, explicitly deferred until the
native path runs flawlessly: reach lyte-host from any browser by compiling the
same Swift client protocol layer to WebAssembly and bridging the browser's
transport gap with a **Caddy (Go) module** that terminates
WebTransport/QUIC/HTTP3 on port 443 and relays to lyte-host's native
GameStream dialect on localhost UDP. The host speaks exactly one wire protocol
forever; the bridge is a protocol-dumb session proxy; the browser gets real
TLS certificates for free via Caddy's ACME automation. A "new Lyte-native
protocol from day one" was considered and **rejected** (§1). Nothing in H0–H6
changes because of this doc.

---

## 1. Context and the reaffirmed protocol decision

lyte-host speaks **exactly one wire protocol from day one**: the
Sunshine/GameStream dialect — plain UDP RTP + Reed-Solomon FEC, ENet control,
encrypted RTSP handshake, HTTPS pairing/launch (docs/HOST-PLAN.md §4). This
was reaffirmed after considering and rejecting a new Lyte-native protocol from
day one, for reasons recorded so they are not re-litigated:

- **The verifier argument.** The battle-tested Mac client plus the golden
  pcap captures are the only trustworthy oracle we own. A new protocol means
  two unproven ends debugging each other — every bug is ambiguous about which
  side owns it. Speaking the dialect means every host bug is isolated against
  a known-good peer.
- **The dependency argument.** A new protocol in 2026 means QUIC, and a QUIC
  stack is a large, churning dependency in a host that otherwise needs
  nothing beyond plain UDP sockets (C only at OS boundaries — LYTE-PLAN §4).
- **The interop argument.** The dialect gives free compatibility with every
  Moonlight client on every platform, today.

Host internals stay transport-agnostic regardless: capture, encode, and
session logic are engine modules; packetization is a leaf. Any future
transport is an additional leaf beside the GameStream RTP+FEC packetizer,
never a rewrite.

## 2. The browser client (same Swift, compiled to WASM)

Swift now officially targets WebAssembly: official Swift SDKs for Wasm ship
on swift.org since Swift 6.2, JavaScriptKit provides JS interop (35–40×
faster safe bridging than earlier releases), and experimental Embedded Swift
mode offers drastically smaller binaries. The browser client is therefore
**the same Swift client protocol layer compiled to WASM** — it already speaks
the GameStream dialect end to end; it only needs a datagram pipe where the
native client has a raw UDP socket. Video decode in the browser uses
WebCodecs via JS interop.

The hard constraint that forces a bridge: **browsers cannot send or receive
raw UDP.** The GameStream dialect is unreachable from a web page directly. A
standards-based transport at the browser edge — WebTransport over
QUIC/HTTP/3 — is required.

## 3. The bridge: a Caddy module

The chosen architecture is a **Caddy (Go) module** that terminates
WebTransport/QUIC/HTTP3 from the browser and relays to lyte-host's native
dialect on localhost UDP.

**Division of labor.** Browser↔Caddy is standard QUIC/WebTransport on
port 443 — automatic TLS certificates (Caddy's ACME/Let's Encrypt automation
is the killer feature) and normal firewall traversal. Caddy↔lyte-host is the
native dialect over localhost, where the extra hop costs microseconds.

**A session proxy, not a port forwarder.** A GameStream session spans the
HTTPS pairing/launch endpoint, the encrypted RTSP handshake, the ENet control
channel, and separate RTP video/audio UDP streams. The module must map these
onto WebTransport primitives — reliable streams for HTTPS/RTSP/control,
unreliable datagrams for RTP — and keep them associated per session. That
mapping is the module's whole job.

**Protocol-dumb by design.** Session intelligence lives in the two Swift ends
(lyte-host and the WASM client), which already share the dialect. The bridge
only moves bytes between transports; it never parses, decrypts, or interprets
session content. This keeps the module small and keeps the single-protocol
invariant intact: lyte-host never learns a second protocol.

**Trade-off acknowledged.** Caddy modules are Go — a new language in the
stack. Accepted because the bridge is an optional, self-contained deployment
artifact: nothing in lyte-host or the native clients depends on it, and a
deployment that never wants browser access never installs it. Fallback of
record if Go proves unacceptable: an optional WebTransport listener inside
the H6-era unified `lyte` binary, at the cost of owning a QUIC dependency in
the host (§1's dependency argument, paid deliberately).

**End state.** A work desktop reachable from any browser at
`https://desk.example.com` with real certificates — while lyte-host itself
still speaks only the dialect it spoke on day one.

## 4. The H6 endgame: one binary named `lyte`

For the record alongside this plan: the H6 endgame is **one binary named
`lyte`** containing both host and client — this is already LYTE-PLAN §6's
ladder (H6 = one binary + macOS host). The current executable names
(Lyte.app, lyte-cli, lyte-host) are build-out scaffolding kept until H6, then
collapsed into subcommand routing (`lyte host`, `lyte connect`). The browser
bridge slots in after that collapse, as a companion artifact beside the
binary, not inside it.

## 5. Sequencing and status

- **Deferred, post-H6.** Nothing in H0–H6 changes because of this doc. The
  bridge earns attention only after the native path runs flawlessly.
- **Current work in progress: H0a.** Next slices: idle-floor/steady-rate
  frame supply, then Sunshine-dialect RTP+FEC into the debug client.
- What H0–H6 must preserve for this plan to stay cheap is already doctrine:
  transport-agnostic engine modules with packetization as a leaf (§1). No
  additional obligations.

## 6. Addendum (2026-07-20, ~21:51): the Lyte-UDP decision simplifies the bridge

The same-evening decision
([20260720-215100-lyte-udp-decision.md](20260720-215100-lyte-udp-decision.md))
changes the host-side protocol and, with it, the bridge's job — for the
simpler:

- **The host speaks Lyte-UDP, not the GameStream dialect.** §1's reaffirmed
  protocol decision is superseded: its verifier argument collapsed
  (Lyte-UDP reuses the proven payload interiors — new skeleton, proven
  organs) and its interop argument was withdrawn (no third-party clients).
  §1's dependency argument, by contrast, won outright: QUIC was rejected
  for the host too.
- **The bridge simplifies from session proxy to dumb datagram relay.**
  Because everything — including the reliable sublayer — rides plain UDP
  datagrams, the §3 stream/datagram mapping disappears. The Caddy module
  becomes a WebTransport-datagram ↔ UDP-packet relay in the CONNECT-UDP
  (RFC 9298) shape: one session association, bytes through, nothing parsed.
- **Untrusted by construction, still.** End-to-end Noise encryption
  (transport pillar §5) means the bridge relays ciphertext it cannot read —
  the "protocol-dumb" goal of this doc, now enforced by crypto rather than
  discipline.
- Sequencing is unchanged: still post-H6, still deferred until the native
  path runs flawlessly.
