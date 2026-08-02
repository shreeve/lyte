# Postures — silence with a signed IOU

*2026-08-02, owner design session. The insight: Lyte controls both
ends of the protocol, so idle silence can be a CONTRACT (announced,
bounded, honest) instead of an ambiguity (VNC's social forgiveness)
or a non-option (today's always-on wire). One wire, three
personalities: VNC's zero-idle, RDP's office thrift, Moonlight's
fluidity — each posture announced, never inferred.*

## Why

- VNC users EXPECT long silence and forgive it — but the protocol
  cannot distinguish idle from wedged; the user just assumes.
- Lyte today is always-on: ~200 audio pkts/s + 1 Hz video keepalive
  + 1 Hz CTRL beacon even on a dead-still desktop. Correct for
  presence; wasteful for the "glance at a headless box" pattern.
- The fix is NOT inference (guessing why the wire went quiet). The
  host ANNOUNCES posture changes as typed control messages, and
  every client consumer (FROZEN detector, clock model, link pill)
  switches contracts. Silence with a signed IOU.

## The two axes (independent, both announced)

### Video posture
| Posture | Behavior |
|---|---|
| **active** | today: damage-driven frames + 1 Hz retained keepalive |
| **quiet** | entered after ~30 s no damage: keepalive backs off exponentially 1→2→4→…→30 s (or to zero, beacon-only); each step rides the announcement |
| **wake** | instant, from: host damage (the frame IS the wake), or client input (the input packet IS the wake — zero added latency for "I'm back") |

### Audio track
| Track | Behavior |
|---|---|
| **on** | today: continuous 5 ms Opus CBR + RS FEC, silence included |
| **auto-quiet** | silence-detected fade (the audio detector exists): stream stops after N s of digital silence, restarts on sound; concealment covers the ramp |
| **mute** | USER-chosen (client UI + negotiated like the 0x18 routing flip — "routing: none"): the host never captures/encodes; the whole track is zero bytes. Mute at the SOURCE, never decode-and-discard |

## The dethroned metronome

Today the 5 ms audio stream is secretly the wire's clock feed and
path probe — the "wire is never silent anyway" argument behind the
1 Hz keepalive's cheapness. Auto-quiet and mute remove it BY DESIGN,
so the announced heartbeat inherits those duties:

- **Clock model**: re-syncs on wake (one RTT + the machinery roams
  already exercise); the low-rate beacon bounds drift meanwhile.
- **FROZEN detector**: arms against the ANNOUNCED heartbeat interval,
  not the 3 s active-video expectation — no false pills on idle.
- **Link pill**: shows an honest calm "idle" state during quiet
  postures instead of guessing.
- **Path probing**: suspended in quiet by contract; the first wake
  exchange re-probes (acceptable: the user just acted, the cushion
  covers discovery).

Floor: fully idle + muted ≈ one 40-byte beacon per 30 s — below
VNC's idle (which still pays TCP keepalives) — while one announced
state-change away from full-rate cushioned streaming.

## Wire notes

- Posture announcements are NEW typed control messages (Wire is
  frozen append-only — new message IDs, capability-gated so old
  clients never see them; a non-declaring peer keeps today's
  always-on contract).
- Wake-on-input needs no new message: any input packet in quiet
  posture is the wake signal.
- Mute rides the existing audio-routing negotiation surface as a
  third routing value.

## Sequencing

Post-E5 (the flip and burn come first — postures build on the
self-hosted host). Estimated two PRs: (1) wire messages + host
posture machine + client contract switches, (2) mute routing + UI
(Settings + control strip). Serves the Lyte Terminal north star
directly: an endpoint that idles at VNC cost and wakes at Moonlight
fidelity is the thin-client story in one sentence.

## Strategic frame (owner, 2026-08-02)

Refuse the "Sunshine+Moonlight only" box. RDP's semantic drawing
commands are unreachable (and weld it to Windows' graphics stack);
hardware encode + damage-driven capture + ratchet-refined static +
quiet postures gets asymptotically close on RDP's office turf while
keeping the motion ceiling RDP lacks. North star: **Lyte Terminal**
— a sealed appliance (E4 packaging = appliance boot, pairing =
TPM-backed identity, reconnect speed = a product number) competing
with IGEL/Wyse/ThinPro rather than remote-desktop apps, with the
moat no thin-client vendor has: both ends of the protocol. Honest
caveat recorded: that market mostly demands Windows/cloud desktops —
a Linux-served-verticals positioning (e.g. practice software) or a
future Windows host story is the demand-side answer.
