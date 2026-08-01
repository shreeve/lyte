# The 10-second stall — it is not AWDL, and it is not the Mac

**Date:** 2026-08-01 (measurements 11:47 UTC benchmark + 13:00–13:30 UTC live
probes) · **Machines:** M5 MacBook Pro (client, 10.0.0.235, now on 5 GHz
ch 44) ↔ pup (Linux host, 10.0.0.249, still on 6 GHz ch 197) ·
**Supersedes the attribution in** `docs/20260728-201150-lyte-wifi-throughput-study.md`
(whose *measurements* stand, but whose "the tail belongs to the Mac's radio"
verdict no longer describes the live link).

## Verdict

**The remaining streaming bottleneck is pup's Wi-Fi radio leaving its channel
for a background scan every ~10 seconds, going dark for a ~50 ms + ~125 ms
doublet each time.** AWDL is definitively excluded. The software pipeline —
host and client, after the #26–#38 campaign — is measured clean end to end;
the only stage that still stalls is the air, and the air's stall is periodic,
pup-sided, and scan-shaped.

## Evidence chain (each leg independently reproducible)

1. **Dual-endpoint pcaps, three independent 60 s benchmark runs**
   (`.build/benchmarks/motion-pipeline-20260801T{113533Z,114204Z,114722Z}-*`):
   43,301 host→client datagrams matched by (IP id, length) at both NICs.
   Host egress: **zero** inter-packet gaps > 20 ms during streaming (p99.9
   gap 5.7 ms). Client ingress: 22–29 stalls totalling ~1.5 s per run
   (2.6 % of wall time), arriving as bursts up to 134.7 ms late. Stall
   onsets in every run are spaced **9.4–10.4 s** apart, each a doublet
   (~45–55 ms hit, then 160–420 ms later a ~124–128 ms hit).

2. **Live simultaneous ping probes, idle link (13:15 UTC):** Mac→gateway
   p99 18.2 ms, max 26.1 ms, zero spikes > 30 ms — while in the same
   35 seconds pup→gateway showed 111/84/119/123 ms spikes at ~10.0 s
   spacing. The spike source is on **pup's side** of the AP, not the Mac's.
   (Mac→pup end-to-end shows the same spikes because it crosses pup's leg.)

3. **pup's BSS scan cache refreshes itself every ~10 s:** two
   `iw dev wlp0s20f3 scan dump` reads 12 s apart both showed all BSS
   entries "last seen ~1.9 s ago" with boottime stamps ~12 s apart —
   an unrequested periodic scan is running continuously. Each sweep takes
   the radio off-channel; the dwell is the doublet in (1) and (2).
   (`iw event` and the journal show nothing — the scan is offloaded /
   logged below the default level; the requester is NM or wpa_supplicant,
   identifiable with NM trace logging if it ever matters.)

## Why AWDL is excluded (three independent falsifications)

- **The stall lives on a Linux box.** AWDL does not exist on pup, and the
  Mac's own leg (Mac→gateway) is simultaneously clean.
- **07-28 study:** `sudo ifconfig awdl0 down` did not remove the tail.
- **Statistical shape (from the 90 stall events in the newest run):** no
  16 ms dwell comb (4 gaps in the 16 ms bin vs ~550 predicted by AWDL
  windowing), and Rayleigh phase-concentration at AWDL's 440 ms / 1.024 s
  periods is non-significant (R = 0.065 / 0.142, threshold 0.183). The
  observed period is ~10.0 s — not an AWDL number.

## What the #26–#38 campaign already retired (software, all measured)

The campaign found and killed software stalls of the same magnitude as the
radio's, which is why the air is now the *only* remaining term: 90–180 ms
RS-FEC/Annex-B scheduling tails under the Session lock and the 100+ ms
usleep-under-lock on UDP backpressure (#38), the client playout
double-count that turned one bounded burst into two stalls, the eager audio
target decay (20→5 packets in 3 s), retained-refinement false-IDR storms
(#33/#37). Newest run: encode p99 8.7 ms, admission→first-transmit p99
0.32 ms, client queueWait max 0.46 ms, enqueue max 3.8 ms, renderer drops 0,
ENOBUFS 0, EAGAIN 0, estimator 0 downshifts. Quality is finished work:
45.897 dB / 0.99991 SSIM, bit-identical across 5 runs; VBV knee at
48–64 kB, nothing above 96 kB.

## Topology note (changed since 07-28)

The Mac has moved from the marginal 6 GHz ch 197 association to **5 GHz
ch 44 — the extender's BSS** — and its leg is currently clean (the study's
~500 ms Mac-side spike trains are gone with the move). pup remains on
6 GHz ch 197 at −63 dBm (beacon avg −74), TX pinned at HE-MCS 2. Both
radios have now each had their own pathology; today's is pup's.

## Fixes, ranked

1. **Wire pup with Ethernet** (unchanged from the 07-28 study, now doubly
   justified: it removes the scanning radio from the path entirely, plus
   the LPI-capped MCS-2 uplink). Kills the 10 s stall outright.
2. **Stop the scanner** if pup must stay wireless: identify the requester
   with NM trace logging (`nmcli general logging level TRACE domains WIFI`),
   then either pin/steer to a stronger BSS (placement or the 5 GHz BSS —
   the scan pressure is signal-driven), or disable NM's periodic Wi-Fi
   scanning for this connection. Verify with the 35 s ping probe: the
   ~10 s spikes must vanish.
3. **Client-side concealment is already in place** (adaptive playout
   15–50 ms, PLC + de-click, fresh-burst debt bound) — it grades these
   holes `bounded_path_tail_concealed`; it cannot remove them.

## Secondary findings (separate defects, filed for the train)

- **Host-side 151 ms handshake stall** (`noise-stall-pup.txt`, t=+192 ms):
  the host emitted nothing for 151.59 ms mid-handshake while receiving the
  client's 40 ms-cadence probes on time. Host-side, real, unexplained.
- **Cold identity cost:** first handshake attempt pays 3.1–4.6 s in
  `identity_ms` (Keychain/signing warm-up); warm attempts run 22–28 ms.
- **Analyzer ladder mislabel:** transit stretch of 7.4–7.8 ms (just under
  the 8 ms rung) falls through to `motion_client_presentation_jitter`
  although client queueWait maxes at 0.46 ms — on this hardware
  `client_presentation` is never the right verdict; the rung order or
  threshold needs one nudge.
