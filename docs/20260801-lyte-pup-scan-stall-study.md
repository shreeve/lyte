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

## Addendum (same day, ~13:30 UTC) — the smoking gun and the 5 GHz move

Kernel tracepoint capture on pup (trace-cmd, mac80211 + cfg80211 + iwlwifi
families, 46 s spanning four stall doublets) settled the last question.
**The AP is the absent party.** Anatomy of one 120 ms stall at full trace
resolution: pup submitted frames on schedule throughout the window, the
first frame through needed **4 on-air retries**, pup received *nothing*
(no MPDUs, no beacons) for ~120 ms, then 10 MPDUs flushed in one burst —
with **zero** host-side scan/ROC/chanctx/queue-stop events. A frame
retried on-air proves pup's radio was present and transmitting; unACKed
retries plus RX silence prove the **gateway's 6 GHz radio went off-air**.
Verdict: the Xfinity gateway's 6 GHz radio leaves the air ~170 ms every
~10.0 s (its own channel-monitoring sweep), and pup was its only 6 GHz
client. Two side-findings from the same trace: the AP's 6 GHz MBSSID
beacons (3 co-located BSSes) churned BSS updates ~2/s, driving iwlmvm to
re-send `SCAN_CFG_CMD` every 507 ms — all of it 6 GHz-association noise,
gone after the move; and iwlmei/CSME is not loaded (ruled out).

**Fix applied:** pup moved to the 5 GHz BSS `c6:50:9c:a5:fc:6a` (ch 157,
−64 dBm) via a cloned NM profile `Shreeve-5g-test` (band a, BSSID-pinned,
autoconnect priority 100; old `Shreeve` profile autoconnect off; revert =
`nmcli con up Shreeve` / re-enable its autoconnect). The switch used a
systemd-run rollback timer, since cancelled.

**Validation results (5 GHz):**
- Idle probe: p50 1.95 ms, p99 13.6 ms, max 41.9 ms (was p99 ~105, max
  123 on 6 GHz). The 84–135 ms doublets are gone; a residual ~40 ms
  single brush remains at the ~10 s cadence.
- BSS cache stamp frozen across 24 s (was refreshing every ~10 s) — the
  scan-config churn died with the 6 GHz association.
- Benchmark leg (`motion-pipeline-20260801T123654Z-76774`): **the audio
  gate now passes** (`bounded_path_tail_concealed`, PLC 21→5, underruns
  5753→1327, all de-click-protected); host egress still clean.
- **Remaining:** under 50 Mbps load the client ingress still shows ~127 ms
  stalls at ~10 s cadence (3 in 30 s) — `motion_transport_burst` still
  FAILs. The periodic sweep is an ecosystem behavior (gateway + extender
  radios alike); the Mac's leg rides the extender's 5 GHz ch 44. The
  bounded remainder is now split across the two remaining radio hops.

**Standing recommendation, unchanged and now twice-proven: wire pup with
Ethernet** (removes pup's radio hop entirely); the Mac-side extender hop
then carries the only residual sweep, and if it still bites, the same
trace method applies to the extender. Cheap alternative worth one test:
put the Mac on the gateway's own 5 GHz BSS (`c6:50:9c:a5:fc:6a`) instead
of the extender, collapsing the path to two radios on one box.

## Addendum 2 (same day, ~14:00 UTC) — 6 GHz radio disabled at the gateway

The owner disabled the private 6 GHz network outright (gateway admin →
Connection → Wi-Fi → Edit 6 GHz → Disable). The Mac immediately re-roamed
to ch 157 at −56 dBm / 720 Mbps PHY (macOS's 6 GHz band bias had kept
dragging it back to the sweeping radio; CoreWLAN steering cannot override
it — `associate` returns tmpErr for in-ESS moves, twice confirmed). pup
(pinned profile) reached HE-MCS 7 / 720 Mbps on the same BSS — up five
MCS steps from the 6 GHz association's MCS 2.

Post-change timeline, pup→gateway 20 Hz probes: the AP's automatic
optimizer churned for ~15 minutes after the save (dense ~100 ms sweep
trains; a mid-window probe read p99 105 ms — do not benchmark inside
that window). After settling: **p50 1.83 / p99 9.3 / max 42.5 ms, three
sub-45 ms brushes in 45 s** — the best figures ever measured on this
link, on either band. Mac→pup end-to-end idle: p99 14.8 / max 25 ms.

The final motion-pipeline gate run is owed: it launches the signed
Lyte.app in the GUI session, and the Keychain identity path fails closed
without the owner present (`authenticationUI: fail`). Run
`Scripts/benchmark-app.sh --no-build motion-pipeline` with the session
unlocked. Ethernet for pup (adapter en route: Realtek RTL8153/8156-class
USB-C GbE, in-kernel r8152 driver, plug-and-play on the 7.0 kernel)
remains the terminal move; on arrival, verify NM routes over the wire,
then optionally disable pup Wi-Fi and re-run the full benchmark suite.
