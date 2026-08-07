# Browser client — peer platform slice (2026-08-07)

> **Verdict: open the browser client as a peer platform**, not a side demo.
> Harsh-path control plane and Conductor Wi‑Fi bars are closed on `main`
> (#209–#222 family). Remaining native posture items in `TODO.md` are
> demand-gated or GNOME-blocked; none is a performance gate that must
> delay this slice. Living direction stays in [`BROWSER.md`](BROWSER.md);
> this record freezes naming, carrier, ownership, and the commissioning
> ladder for the first real `LyteClientBrowser` work.

## 1. Why now

The macOS-client / Linux-host path has earned its celebration bar: one
protocol, Noise always on, capped-CQ FEC, rate without IDR reset, sparse
hold, IRAP ownership, and Conductor cue/reserve on the live Wi‑Fi rig.
`LyteWire` already attests 511 tests under `wasm32-unknown-wasip1` via
`Wire/Scripts/wasm-test.sh` — that proves **protocol portability**, not a
browser client.

The product role is still **client**. The browser is another platform
shell and carrier around the same IO-free cores (`LyteWire`, `LyteCore`,
`LyteClientCore`, `LyteClientSession`), beside Mac, Windows, and Linux —
not a second product and not a JavaScript reimplementation of policy.

## 2. Naming and ownership

| Concept | Name | Owns |
|---|---|---|
| Client platform adapter | `LyteClientBrowser` | Browser IO ports: WebTransport pump, WebCodecs/WebGPU/AudioWorklet adapters, DOM input mapping, JS↔WASM boundary |
| Product composition (later) | `LyteBrowserApp` under `Applications/` | Page shell, permissions, lifecycle; no protocol policy |
| Carrier leaf (host or sidecar) | deferred name until B-2 | Opaque WebTransport ↔ UDP relay; ciphertext only |

This extends
[`20260803-084328-source-layout-and-migration.md`](20260803-084328-source-layout-and-migration.md)
§2 / §4: platform identifiers gain **`Browser`** alongside `MacOS`,
`Linux`, and `Windows` for the client role. No empty SwiftPM target lands
until B-1 needs a real dependency boundary.

Dependency law is unchanged: browser adapters sit at the platform edge and
consume IO-free session/core; they never invert that arrow.

## 3. Frozen carrier and security

**Browser-edge carrier: WebTransport datagrams over HTTP/3.**

- Unreliable, unordered datagrams without TCP head-of-line blocking.
- Pairing and Noise remain end-to-end between WASM client and host.
- Any bridge or host leaf sees only opaque ciphertext envelopes.
- Native raw UDP on 41151 is undisturbed when browser support is absent.
- Usable datagram ceiling is **measured in B-2** and negotiated downward
  per session if needed — never assumed from the 1152 B Lyte budget alone.

Rejected for v1 browser path (unchanged from scoping): WebSocket as media
carrier, WebRTC data channels as the Lyte dialect, plaintext or
transport-trusted modes, and a second application protocol on the host.

**B-2 adapter decision:** same-box sidecar (`lyte-wt-sidecar` under
`Browser/Scripts/`) for the Chrome proof and local harness. An optional
in-process Linux host leaf remains a later packaging choice, not a product
fork.

## 4. Capability matrix (session intersection)

| Organ | Native shipping | Browser path |
|---|---|---|
| Wire codecs / Noise / FEC / ARQ | `LyteWire` | Same module; WASM attested under wasmtime; B-1 proves JS boundary |
| Client session policy | `LyteClientSession` | Same IO-free boundary; no JS policy fork |
| Conductor playout | `LyteCore` | Same sole authority; browser queues execute, never replace |
| Datagram carrier | plain UDP | WebTransport datagrams + opaque relay |
| Video encode (host) | HEVC (shipping) | Capability intersection; AV1 remains a negotiated browser-era hook, not a silent substitute |
| Video decode | VideoToolbox | `VideoDecoder.isConfigSupported()` only; no high-latency software decode as the normal path |
| Present | `AVSampleBufferDisplayLayer` | WebCodecs → GPU `VideoFrame` → WebGPU → `<canvas>` / `OffscreenCanvas` |
| Audio playout | native render path | Decoder → small ring → `AudioWorklet` |
| Input | AppKit / CG | DOM, wheel, keyboard, Pointer Lock → existing typed messages |
| Clipboard / bulk / print | negotiated channels | Same wire contracts after media path; consent-gated |

Chroma, color, and reconnect laws from standing rulings still apply: chroma
is connect-time posture; changing it is a clean reconnect.

## 5. Commissioning ladder (done means)

Independently testable slices; each keeps Mac/Linux package gates and the
Wire WASM suite green:

| Stage | Proof | Not yet |
|---|---|---|
| **B-0** (this record) | Naming, WebTransport carrier, matrix, ladder frozen; living docs point here | Runtime code |
| **B-1** | Load Lyte WASM in Chrome; exercise frozen envelope + Noise IK vectors across the JavaScript boundary (`Browser/`, smoke-chrome) — **landed** | Network |
| **B-2** | Opaque datagram round-trip through same-box WT↔UDP sidecar; measured ceiling ≥ 1152 B in Chrome — **landed** | Session |
| **B-3** | Pair, Noise, capabilities, control-only session (HostWire peer via WT; pup optional) — **landed** | Media |
| **B-4** | One timestamped frame via WebCodecs + WebGPU (canned corpus IRAP in Chrome) — **landed** | Live stream |
| **B-5** | Live Conductor-driven video — **next** | Audio / input product surface |
| **B-6** | AudioWorklet, input capture, clipboard, product UI | “Done” browser client |

**“Browser client done”** for product purposes means B-6 against a real host
without forking protocol policy. Celebrate intermediate bars honestly;
do not claim a streaming browser client before B-5.

## 6. Performance posture

No open performance campaign blocks this start. Banked, demand-gated items
(Opus DTX warm rung, DSP fades, instant-replay ring) stay in `TODO.md`.
Wayland host clipboard remains GNOME-blocked and orthogonal. Browser work
must not reopen encoder-reset rate paths, uncapped FEC, or Conductor-as-
browser-buffer anti-patterns named in [`BROWSER.md`](BROWSER.md).

## 7. Immediate next code

**B-1 through B-4 landed** in `Browser/` (`LyteClientBrowser` + Page +
`Scripts/{build,serve,smoke-chrome,wt-sidecar}.sh|.mjs`) with Host
`lyte-control-peer` for the DRM-free control gate and a canned Wire-corpus
IRAP for the WebCodecs + WebGPU frame bar. Living runbook:
[`BROWSER.md`](BROWSER.md).

**B-5 next:** live Conductor-driven video. No claim of a streaming browser
client before that bar. Do not displace standing UDP 41151.
