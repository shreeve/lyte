# Glossary

Terms and identifiers that appear in code comments, commit messages and the
dated records.

## Slice and gate identifiers

Commit messages, dated records and some test comments cite the slice that
introduced a behavior; production code comments do not
([AGENTS.md](../AGENTS.md#change-discipline)). The identifier names a
planning unit, not a current contract; the code and
[PROTOCOL.md](PROTOCOL.md) are the contract.

| Prefix | Meaning | Examples |
|---|---|---|
| `W<n>` | Wire (LyteWire) build slice | W0 envelope, W1 FEC field, W3 ARQ, W4a beacon, W4b lifecycle, W5 Noise, W6 pairing, W7 capabilities, W10 bulk |
| `W-G<n>` | Wire gate (acceptance check for a W slice) | W-G1 byte-exact vectors on macOS and Linux |
| `H<n>`, `H0a` | Host-and-client wave (campaign) | H2 parity, H3 feature channels, H4 4:4:4 |
| `HS-<n>` | Host slice | HS-9 msg1 rate limit, HS-13 input, HS-17 NACK responder, HS-18 host audio routing, HS-32 repair refusal |
| `CL-<n>` | Client slice | CL-3 IDR request, CL-9 input, CL-11 audio player, CL-15 clipboard text |
| `F-<n>` | Feature slice | F-2 bulk channel, F-5 roaming |
| `V-<n>` | Video-quality slice (H4) | V-3 corpus harness |
| `P-1` | Clipboard images (clipboard v2) | |
| `Q-1` | The video quality probe | |
| `E<n>` | Direct Eye phase | E0 probe … E5 portal removal (`self-hosted` tag) |
| `B-<n>` | Browser commissioning ladder | B-0 decision … B-6 interaction shell; see [BROWSER.md](BROWSER.md) |
| `CP-<n>` | Clipboard platform probe | CP-5 GNOME portal probe |
| `#<n>` | Pull request number on `main` | |

Section references such as "master plan §4.6", "core plan §5" or "host
build plan §6" point into retired planning documents; the
[docs catalog](README.md#retired-records) lists the command that recovers
each.

## Protocol and session

| Term | Meaning |
|---|---|
| Lyte-UDP | The one Lyte protocol, over plain UDP ([PROTOCOL.md](PROTOCOL.md)) |
| envelope | The 24-byte datagram header, sent as AEAD associated data |
| CTRL | Channel 0: control messages, ARQ ordered stream plus bare datagrams |
| bare | A CTRL datagram outside ARQ (beacons, path messages, handshake, IDR requests) |
| ARQ | Lyte's reliable retransmission sublayer; group 0 is the ordered stream, other groups are one-shots |
| one-shot group | An independent ARQ message that cannot block, or be blocked by, other groups |
| capability key | A numbered entry in the capability declaration; features are gated on the intersection |
| flag key | Keys 9–16: a `key: true` entry carried outside the typed v1 set |
| IRAP / IDR | HEVC random-access picture; the frame a decoder can start from |
| NACK | Client request for specific missing shards of a frame |
| repair refusal | Host's explicit "that repair will not come" (CTRL 0x23) |
| ACTIVE / IDLE | The two wire session modes |
| FROZEN / RECOVERY | Local path-loss overlays: on the client, FROZEN after 2.5 s of media silence (350 ms once audio flows), RECOVERY while it returns; never on the wire |
| liveness timeout | 30 s without authenticated evidence ends a session |
| teardown | Typed goodbye (0x0A): `takenOver` or `shuttingDown` |
| roaming | The client re-acquiring a host that moved or restarted, keeping the window |
| path migration | The host promoting a client's new address after a challenge/response |
| pinned host | A host whose static key the client stored at pairing |
| retry cookie | Stateless HMAC token the host demands under a handshake flood |
| capped-CQ | The encoder posture: constant quality under a rate cap sized so a frame fits one FEC group |

## Playout: the Conductor

Decision record: [Conductor](decisions/20260803-050422-metronome-playout-design.md).

| Term | Meaning |
|---|---|
| Conductor | The client's playout authority (`VideoBeatConductor`): one clock, every instrument on the beat |
| score | The host's capture timeline, stamped on every part |
| instrument | A media stream (video, audio) with its own verbs |
| part | One unit of an instrument (a frame, an audio packet) |
| beat | One period of the playout grid (16,667 µs at 60 Hz) |
| cue | Score-to-glass interval: score + measured path delay + cushion |
| cushion / reserve | Parts held in reserve, counted in beats; derived from evidence, never a setting |
| late | A part whose beat has passed: ingested, never shown |
| hole | The cushion ran dry: video holds, audio conceals; re-cue one beat once |
| slip | One scheduled beat-slip when the cushion leaves its band |
| stretch | Re-cue one beat after sustained sub-beat lateness (the mirror of slip) |
| chain | Dependent parts are always ingested, even when their beat is lost |
| rubato | Audio time-stretch toward the beat (filed, not built) |
| renderer handoff | The bounded queue between sample build and the renderer (`VideoRendererHandoff`) |

## Host capture and encode

| Term | Meaning |
|---|---|
| Direct Eye | The host's capture path: read the KMS scanout with `CAP_SYS_ADMIN`, fingerprint it on the GPU, blit and encode with VAAPI; no portal, no compositor API |
| pixel fingerprint | 16×16-tile GPU hash of the scanout; the only damage truth ([record](decisions/20260805-084033-direct-eye-pixel-observation.md)) |
| pens | Lyte's own Swift HEVC bitstream writers (parameter sets, slice headers) in `HostCore` |
| seat | The DRM device and display the host captures; one Direct Eye per seat |
| keepalive | Re-encoding the retained frame on a still screen (about 1 Hz) |
| admission | Pre-encode skip of a changed frame while queued video holds its latency budget |
| HRD / VBV buffer | Encoder rate-control buffer; bounded so a ceiling frame fits one FEC group |
| service loop | One `lyte-host` process serving sessions in turn (`HostServiceLoop`) |

## Postures

Decision record: [postures](decisions/20260802-013946-postures-design.md).

| Term | Meaning |
|---|---|
| posture | An announced mode the peer can rely on, never inferred from silence |
| quiet / active (audio) | Tripwire: capture never stops; transmission gates during silence and resumes instantly on sound (0x25) |
| quiet / active (video) | The keepalive backs off toward 30 s after ~30 s without damage; damage or input wakes it (0x26) |
| pre-roll | The ~200 ms audio ring shipped first on wake so the onset is intact |
| rewind | A deeper host-side replay ring (filed, not built) |
| chroma tier | Good = 4:2:0, Better = 4:2:2 (dormant), Best = 4:4:4; fixed per session |
| host audio routing | Host speakers audible, muted (virtual "Lyte Audio" sink), or stream off |

## Browser

| Term | Meaning |
|---|---|
| sidecar | `lyte-wt-sidecar`: relays opaque datagrams between WebTransport and UDP |
| control peer | `lyte-control-peer`: a DRM-free `HostWire.Session` serving the browser proof |
| session proof | The page's scripted run whose PASS lines the Chrome smoke checks |
