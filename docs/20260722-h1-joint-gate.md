# H1 Joint Gate — the honest session, formally closed

*2026-07-22, ~07:50–09:00 MDT. Verification run, not a feature slice: both
ends at committed HEAD `bf7c6b5`, live against pup (10.0.0.249) over the
real Wi-Fi LAN. No feature code was touched.*

## Verdict

**H1 IS CLOSED.** Every criterion in the decision record's H1 definition
(`docs/20260720-215100-lyte-udp-decision.md` §5 — Noise handshake, PIN-PAKE
pairing, discovery, session lifecycle, control channel on the reliable
sublayer, the idle/active machine with idle silence + reliable sparse
frames + IDR-on-wake, liveness beacon) passed in one coherent joint run.
One adjacent item is deferred by design, not failed: the live
retry-cookie posture (host-side HandshakeGate cookie-mode escalation was
explicitly deferred out of W8/HS-11; the client leg is armed in every dial
and gate-tested in-tree). Details in the ledger below.

## Environment

- Host: pup, Ubuntu 26.04, GNOME/Mutter Wayland, RTX 4050, Swift 6.1.2,
  PipeWire; `lyte-host` built on pup from a `git archive` of committed
  HEAD (`~/src/h1gate/` — the Host/ working tree was mid-HS-15-edit and
  was never used or synced). Portal capture ran headless off the persisted
  restore token throughout; Mutter RemoteDesktop injection backend.
- Client: this Mac, `lyte-cli` built + signed via `Scripts/build-cli.sh`
  at the same HEAD; persistent client identity from the login Keychain
  (`357a83cc…cd52`), host static pinned in `pinned_hosts.json`
  (`10e0f084…6201`).
- Port: 41031 for every leg (an HS-15 audio worker ran concurrently on
  41021 early in the window; no contention artifacts observed — handshake
  and latency numbers are consistent across the busy and quiet periods).
- Netem: scoped egress prio+u32 on pup's `wlp0s20f3`, udp dport 41031
  only (the `Scripts/netem/lo-netem.sh` pattern), removed after; Sunshine
  untouched and `active` throughout.
- Logs: Mac `/tmp/h1gate-{discover,keychain-probe,runA-client,runB-client,
  runC-client,runD-client,runE-client,pair-client,reqpair-client}.log`;
  pup `/tmp/h1gate-{run1,runA,runB,runC,runD,runE,pair,reqpair}-host.log`
  + `/tmp/h1gate-netem.log`. Run C/D/E client logs carry per-line
  epoch-ms timestamps (piped through perl).

## The runs

- **Run A** (40 s, `--ratchet`, input script): the full ladder, host-first
  teardown.
- **Run B** (client 20 s inside host 45 s): client-first teardown.
- **Run D** (102 s, phase-swept single moves every 3.106 s): input-wake
  attribution with timestamped logs.
- **Run E** (84 s): adversity — 45 s of 5 % loss + 20 ms delay, then a
  5.0 s full blackout (100 % loss), then clean removal, all mid-session.
- **Pairing** + **require-paired reconnect**: fresh PIN-PAKE, then 1-RTT
  enforcement.

## Ledger — H1 exit criteria, pass/fail

| # | Criterion (decision record §5) | Verdict | Evidence |
|---|---|---|---|
| 1 | Discovery (Bonjour + manual) | **PASS** | `wire-discover` found `pup 10.0.0.249:41031 v=1 pkh=3cf2bcc1… PINNED-KEY MATCH` against the live Avahi advertisement (HS-10/CL-5 path); every dial leg also exercised the manual IP:port path. |
| 2 | Noise handshake, paired identity | **PASS** | Zero-UI Noise IK on every leg: Keychain client static `357a83cc…` + pinned host static `10e0f084…`, no `--host-key`. Handshakes 13.5 / 16.1 / 18.3 / 23.3 / 23.5 / 32.3 ms across six dials. 0 unseal failures in ~54,000 sealed datagrams across all legs, both directions. |
| 3 | PIN-PAKE pairing | **PASS** | Fresh non-interactive pairing: host `--pair` minted PIN 354201 on its console (read over SSH), client `wire-pair` → handshake 14.1 ms → share A → share B (attempt 1/3) → host tag verified → confirm → **PAIRED both ends**; client static already pinned (no-op re-pin, keystore byte-identical). Persistence proven by the next leg. |
| 4 | Pairing persisted / enforced | **PASS** | `--require-paired` host ("enforcing 3 paired client static(s)") accepted the paired identity 1-RTT in 18.3 ms, first frame 4.7 ms, 0 unseal failures. |
| 5 | Control channel on the reliable sublayer | **PASS** | Capabilities as first reliable words BOTH ways (client 0x0F first reliable word; host declaration first `sendReliable`) → `capabilities: agreed — wire minor 0, codecs [1], chroma [1], idle-silence true, max datagram 1152 B` mirrored on both consoles, every leg. Mode transitions (0x09), idle frames (0x15 one-shots), input (0x16/0x17), teardown (0x0A) all rode the sealed ARQ stream. Under 5 % loss: ARQ 65 delivered / 16 duplicate retransmits ignored as routine, exactly-once semantics held. |
| 6 | Session lifecycle + teardown with reason | **PASS** | Host-first (run A): host `teardown 0x0A queued (shuttingDown)` → "teardown acknowledged — clean close"; client `CLOSED — peerTeardown(shuttingDown)`. Client-first (run B): client `teardown 0x0A sent (shuttingDown)` + ARQ quiescent; host `CLOSED (peerTeardown(shuttingDown))`. |
| 7 | Idle/active machine: idle silence + reliable sparse frames | **PASS** | Run A: **13 full idle cycles** (26 mode transitions, both consoles mirroring `mode → IDLE/ACTIVE` label-for-label); run D: 30 cycles/60 transitions. Every flip gated on the converged frame's one-shot ack ("converged frame riding one-shot group N — its ack is the idle flip"). 0x15 idle frames delivered every cycle: on the clean LAN all deduped against the datagram path (wrap-aware dedupe); under loss (run E) **2 idle frames were ARQ-rendered** — the reliable copy carried a converged frame the datagram path lost, live proof of the CL-8 seam. Datagram-level idle silence live-verified by HS-11's tcpdump leg (28 silent windows, zero video datagrams inside); this run's per-cycle dedupe/render accounting is consistent with it. |
| 8 | WAKE on input, IDR-on-wake | **PASS** | Run D (timestamped): input seq 3 sent while the client's mirror stood IDLE → `mode → ACTIVE` **14 ms later** — an order of magnitude inside the idle windows' natural damage-bounded lifetime (52–443 ms), attributable to the event, not the 1 Hz clock damage. 29/29 events injected via Mutter, 29/29 echoes, host receive→inject p50 1316 µs / p99 1580 µs (HS-13's <2 ms gate re-held); run A p50 1284 µs. IDR-per-wake exact both runs: run A 14 IDR = startup + 13 wakes; run D 31 IDR = startup + 30 wakes. Client latency books live: inject p50 13.1 ms, photon p50 44.0 ms (run D). |
| 9 | Liveness beacon | **PASS** | 1 Hz beacons on CTRL every leg (run D: 103 beacons / 102 echoes); HostClockModel through the session object: residual rms 75.6 µs / max 130.4 µs (run D, well under the 1 ms joint gate); min RTT 6.8–7.9 ms on this Wi-Fi path. |
| 10 | Resiliency under loss (FEC + ARQ hold the session) | **PASS** | Run E, 5 % loss + 20 ms delay scoped to 41031: 959 seq-missing of 18,507 host datagrams (5.2 % — the netem rate), **9 FEC-impossible → 9 coalesced IDR requests → 9 forced IDRs → healed every time**, 830 frames decoded, layer `.rendering` throughout, **0 unseal failures both ends** (retransmits ride fresh sealed datagrams — also pinned by W9's replay-window integration test), 16 ARQ duplicates deduped, converged frames byte-exact (dedupe accepted them; byte-equality pinned by CL-8's in-tree gate). |
| 11 | Blackout → FROZEN pill → recovery (CL-8 semantics) | **PASS** | Run E: 5.02 s of 100 % loss mid-session. `PILL ON — path dark (FROZEN)` exactly 2.52 s after blackout onset (the client's documented 2.5 s detector). Pill cleared ~0.2 s after netem removal on first returning evidence; idle cycles and decodes resumed immediately; the receiver never entered RECOVERY (its machine has no receiver-side RECOVERY by design). Host side kept liveness off client feedback (unimpaired direction) and never tore down. |
| 12 | Retry-cookie posture | **DEFERRED (not an H1 criterion)** | The host at HEAD never escalates to cookie mode — HandshakeGate's W8 consumption is an explicitly deferred slice (HS-11's deferred list), so no live dial can draw a 0x13. The client answer path (same verbatim msg1 wrapped in 0x14) is armed in every dial and pinned by CL-8's gate against a real minted cookie. Flood posture itself was live-gated at HS-9 (500-msg1 flood → 10 Noise attempts, 0 sessions). The live cookie leg lands with the host enforcement slice. |

Per-slice gates recorded in HANDOFF (W3/W4b/W6/W7/W8/W9, HS-8/9/10/11/13,
CL-5/6/7/8/9/10) stand as the depth behind each row; nothing in this run
contradicted any of them.

## Headline numbers

- Handshake (paired 1-RTT, zero UI): 13.5–32.3 ms across six dials.
- Pairing (fresh PIN-PAKE, end to end): 14.1 ms handshake, whole exchange
  well under 1 s.
- First frame after handshake: 4.7–33.6 ms.
- Idle cycles: 13 in 40 s (run A), 30 in 102 s (run D); IDR count =
  startup + exactly one per wake, both runs.
- Input: 29/29 + 3/3 injected exactly-once in order; host rx→inject p50
  1.3 ms / p99 1.6 ms; input→photon p50 44 ms (run D).
- Clock: residual rms 75.6 µs after 102 s (gate: <1 ms).
- Netem leg: 5.2 % delivered loss, 9/9 FEC-impossible healed by IDR,
  0 unseal failures, session never dropped.
- Blackout: 5.0 s dark → FROZEN pill at +2.52 s → recovery on first
  evidence, no receiver RECOVERY, no teardown.
- Accounting: every leg's totals line showed ALL datagrams ok — 0
  malformed, 0 unseal-failed, both directions, every run.

## Cleanup (verified after the last leg)

netem removed (`wlp0s20f3` back to `noqueue`); port 41031 free; no
lyte-host processes; Sunshine user unit `active`; and the three secrets
byte-identical to the pre-run snapshot:
`portal_token dadf9a66…37cf`, `noise_static.key 72860390…cfed`,
`paired_clients 8dc1f88a…55fd`.

## Deferred items (named, none gating H1)

1. **Live retry-cookie dial** — blocked on the host's HandshakeGate
   cookie-mode slice (W8's consumption seam, already specified).
2. **Human-at-the-glass legs** — the app-row click → stream window visual
   and the takeover/reconnect UX (CL-7/CL-8 deferred rows; H2-era polish).
3. **0x15/0x16/0x17/TLV-0x03 promotion into Wire/** — byte-pinned mirrors
   exist on both ends; the promotion is a Wire-territory file move.
