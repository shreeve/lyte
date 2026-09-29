# Browser relay: a generic datagram relay at the edge (Janus)

**Status: Binding.** Refines the carrier leaf left open by the
[browser platform slice](20260807-021425-browser-client-platform-slice.md).
Setup and measurements: [BROWSER.md](../BROWSER.md#live-setup-janus-relay).

## Decision

A browser reaches a host through a generic WebTransport ↔ UDP datagram
relay at the host's edge: Janus capability 10, `webtransport`. `lyte-host`
does not terminate WebTransport, and no Node or Bun process sits in the
daily path. The Node sidecar stays as the proof harness's test relay.

## Why

- A page cannot send UDP; something must terminate WebTransport (HTTP/3
  over QUIC) and forward datagrams. The slice already fixed its role: an
  opaque leaf that sees only ciphertext, because Noise runs end to end
  between the page's WASM and the host.
- The owner ruled out Node; Bun has no WebTransport server.
- Terminating QUIC in `lyte-host` would bring a QUIC stack, TLS
  certificates and page serving into the host, which the Lyte-UDP
  decision kept out.
- The edge already owns what the browser needs around the relay: TLS
  certificates, serving the page, mDNS names and local-CA trust
  onboarding. The relay is not Lyte-specific: it forwards datagrams on a
  host and path to one UDP address.

## What the relay must do

These are Lyte's requirements, and Janus's contract adopts them:

- Carry 1152 B datagrams both ways from the first packet, with no
  path-MTU dependency. Count every refusal.
- One WebTransport datagram is one UDP datagram: never coalesce, split,
  pad, retry, reorder or batch. The host's estimator reads arrival
  dispersion.
- Each session gets its own connected UDP socket. Its source port stays
  fixed for the session and is closed when the session ends.
- Toward the browser, drop rather than queue: bound the queue by age and
  count, and drop the oldest.
- The UDP target is fixed in configuration, never chosen by the client.
- `Origin` is required. Sessions are capped, and idle timeouts do not
  undercut Lyte's 30 s liveness.

## Consequences

- **Pinned certificate hashes.** Chrome enforces Certificate Transparency
  on WebTransport QUIC even for a locally trusted root. Janus's
  descriptor therefore publishes a short-lived leaf's hash, and the
  viewer reads the descriptor before every dial.
- **IPv4-only names.** A browser's QUIC dial never falls back from a
  refused IPv6 address, so a relay's name must resolve A-only.
- **Janus is required for browsers only.** The browser path needs Janus
  v1.19.0 or later. The native UDP path is unchanged and needs no edge.
- **Revisit** only if a host must serve browsers without any edge beside
  it.
