# Wi-Fi throughput study — why the 6 GHz link gives 150 Mbps in bulk and 13–17 Mbps to the estimator

**Date:** 2026-07-28 (measurements 19:58–20:11 UTC) · **Machines:** M5 MacBook Pro
(client, 10.0.0.211) ↔ pup (Linux host, 10.0.0.249) · **Network:** SSID "Shreeve",
Xfinity gateway, both endpoints on 6 GHz channel 197 (6935 MHz, 160 MHz width).

## Verdict

**Bulk (~130–180 Mbps):** the link is uplink-limited by 6 GHz LPI client transmit
power. The AP (30 dBm EIRP advertised) delivers downlink at HE-MCS 7–8 NSS 2
(865–1633 Mbps PHY) to both clients, but the clients — capped at 22 dBm over a
160 MHz channel at −63 to −67 dBm range — can only close uplink at HE-MCS 2–4
(pup: 432 Mbps PHY with 5–8 % retries; Mac: 288 Mbps PHY, MCS 3, **one** spatial
stream). Every transfer between the two machines crosses the same channel twice
(client→AP, AP→client), so end-to-end goodput collapses to the sender's uplink
goodput minus shared airtime: exactly the 128–180 Mbps measured.

**Real-time (13–17 Mbps with stalls):** the Mac's radio adds a heavy delay tail
even when idle — spike trains every ~500 ms rising 70→100 ms (measured, isolated
to the Mac side; **not** AWDL — disabling `awdl0` changed nothing) — plus genuine
residual air loss on the Mac's uplink at even trivial rates (1.7 % at 20 Mbps
offered). A loss/delay-driven estimator sees a congestion signal twice a second,
forever, and pins low. The micro-stall distribution, not average capacity, is
what the Lyte estimator's 13–17 Mbps read reflects.

## Hardware & config inventory (Phase 1, passive)

| Item | pup | Mac |
|---|---|---|
| Wi-Fi chip | Intel AX211 160 MHz (CNVi, Meteor Lake, `8086:7e40`) | Broadcom (`0x14E4, 0x4388`), fw 23.50.20.0 |
| Driver / firmware | `iwlwifi`, fw `89.123cf747.0 ma-b0-gf-a0-89.uc` | IO80211 12.0 |
| Reg domain | US (self-managed phy) | US (FCC locale) |
| Channel | 197 (6935 MHz), 160 MHz, center 6985 MHz | 6g197/160 (same BSS network) |
| BSSID | c4:50:9c:ac:fc:6b | same gateway |
| Signal | −63…−65 dBm (beacon avg −69…−72) | RSSI −66/−67, noise −92 dBm |
| TX power cap | **22 dBm** (`iw dev wlp0s20f3 info`); 6 GHz range is `NO-OUTDOOR` (LPI) in `iw reg get` | n/a to read; same LPI regime |
| RX bitrate (from AP) | 865–1633 Mbps, HE-MCS 4–8 NSS 2 | (downlink healthy) |
| **TX bitrate (to AP)** | **367–576 Mbps, HE-MCS 2–4** (sometimes NSS 1) | **288 Mbps, HE-MCS 3, NSS 1**, GI 800 |
| Power save | off (`iw … get power_save`); NM `wifi-powersave-off.conf` present; `iwlmvm power_scheme=2` | CCA 6 %, BTC off |
| Channel busy | `survey dump` returns nothing on iwlwifi (unsupported without scan); Mac-side CCA **6 %** — the channel is mostly idle | — |

Commands: `lspci -nnk`, `modinfo iwlwifi`, `ethtool -i wlp0s20f3`, `iw reg get`,
`iw dev wlp0s20f3 info/link/station dump`, `sudo dmesg`, `system_profiler
SPAirPortDataType`, `sudo wdutil info`, `nmcli dev wifi list --rescan no`.

The dmesg line `Limiting TX power to 30 (30 - 0) dBm as advertised by
c6:50:9c:a5:fc:6a` shows the **AP side** operating at up to 30 dBm — an 8 dB
uplink/downlink budget asymmetry against the clients' 22 dBm. That asymmetry
is the whole story of the MCS split: SNR at the AP receiving the clients is
~8 dB worse than SNR at the clients receiving the AP, which at −65 dBm over a
160 MHz noise bandwidth lands the uplink in MCS 2–4 territory while the
downlink cruises at MCS 7–8. The Mac dropping to NSS 1 uplink is its own rate
control conceding the same fight.

Retry counters (`iw station dump`, sampled twice): pup's previous full
association logged 33 714 retries / 625 570 tx packets (**5.4 %**) and 50 060
`rx drop misc` / 1.08 M rx (4.6 %); a fresh association ran 7.6 % retries
within its first minute, idle.

Same-SSID alternatives visible from pup (`nmcli dev wifi list --rescan no`,
signal /100): 2.4 GHz ch 1 @ 100, **5 GHz ch 157 @ 79**, 5 GHz ch 44 @ 70
(extender), **6 GHz ch 197 @ 57** ← both machines chose the weakest-signal
band. Channel 197 is a PSC channel; one neighbor BSS shares it at −67 dBm but
CCA 6 % says contention is minor.

## Load measurements (Phase 2 — run 20:04–20:09 UTC, joint-gate port 41168 idle, iperf3 on port 41200)

### TCP (`iperf3 -c 10.0.0.249 -p 41200 -t 12 [-P 4] [-R]`)

| Direction | 1 stream | 4 streams |
|---|---|---|
| Mac → pup | **128 Mbps** | 120 Mbps |
| pup → Mac | **180 Mbps** | 169 Mbps |

Four streams gain nothing — the ceiling is airtime/PHY, not the TCP stack.
(Matches the owner's dd-over-ssh 137/156 Mbps.)

### UDP sweep (`iperf3 -u -b {20,50,100,200}M -t 8 -l 1200 [-R]`)

| Offered | Mac → pup loss | pup → Mac loss |
|---|---|---|
| 20 Mbps | **1.7 %** | 0.11 % |
| 50 Mbps | **7.8 %** | 0.15 % |
| 100 Mbps | **9.8 %** | 0.06 % |
| 200 Mbps | 28 % | 0.18 % (155 Mbps delivered — sender self-paced) |

pup→Mac barely loses anything because Linux mac80211 backpressures the sender
at the queue; the Mac fires at the offered rate into its 288 Mbps NSS-1 uplink
and the residue dies in the air. **1.7 % loss at 20 Mbps offered** is the
number that murders a loss-sensitive rate estimator.

### MCS under sustained load (30 s pup→Mac TCP; `iw station dump` every 2 s)

TX rate stayed pinned at HE-MCS 2–3 (408–576 Mbps PHY) for the entire run —
it never climbed. Retries jumped from 1 842 to 2 721 in the 14 loaded seconds
(**~60 retries/s**). Rate control isn't being lazy; higher MCS genuinely fails
at this SNR. 137 Mbps goodput from a 432 Mbps PHY rate ≈ 32 % efficiency —
retries and backoff eat the rest.

### Latency distribution (idle link, `ping -i 0.1`, ms)

| Path | p50 | p90 | p99 | max |
|---|---|---|---|---|
| Mac → pup | 9.4 | 82 | 95–140 | 142 |
| Mac → router | 8.2 | 24 | 82 | 97 |
| **pup → router** | **2.0** | **3.2** | **6.5** | 84 |

The spikes arrive in trains: one every ~5 pings at 100 ms spacing (≈ every
500 ms), rising 72→81→92→96 ms, then a quiet gap, then another train. The
signature suggested AWDL availability windows, but **`sudo ifconfig awdl0
down` did not remove the tail** (p90 91 ms with AWDL off; restored
immediately after). pup's path to the router is clean — the tail belongs to
the Mac's radio, most plausibly roam/location scan dwells: at RSSI −67 the
Mac sits near its roam-scan threshold and keeps going off-channel to look for
better BSSes. For a 60 fps stream this is a 4–6-frame hole up to twice a
second — precisely the stall cadence the Lyte estimator reports as 13–17 Mbps.

## Why bulk ≫ realtime

Bulk TCP rides the retries: a 100 ms radio absence just delays ACKs and the
window refills — average throughput barely notices. A real-time stream cannot
hide a 100 ms hole inside a 16 ms frame budget; each hole is a loss/latency
event, and each event tells the congestion controller to back off. With an
event every ~500 ms there is never a clean probing interval, so the estimate
never ramps toward the ~150 Mbps the link can actually carry. Add the Mac
uplink's 1.7 %-at-20 Mbps floor for the return/input path and the estimator's
13–17 Mbps steady state is exactly what this link deserves.

## Recommendations, ranked

1. **Wire pup to the router with Ethernet.** pup is the stationary reference
   host; this removes one of the two radio hops entirely and removes pup's
   LPI-capped uplink from the video path. The stream becomes a single
   AP→Mac downlink at MCS 7–8 (865+ Mbps PHY). Expected: bulk pup→Mac
   180 → **500–800 Mbps**; streaming capacity ceiling rises ~5×, leaving only
   the Mac-side stall tail to manage. Highest gain, zero risk, no radio knobs.
2. **Get both clients off marginal 6 GHz — either move to the 5 GHz ch 157
   BSS or raise 6 GHz RSSI by ~10 dB (placement).** The same gateway serves
   "Shreeve" on 5 GHz at signal 79/100 vs 6 GHz at 57/100; 6 GHz at −65 dBm
   over 160 MHz under LPI power rules is simply the wrong operating point.
   Either fix moves the client uplink several MCS steps (2–4 → 6–9).
   Expected: bulk 130–180 → **300–500 Mbps** both directions; the Mac's
   roam-scan spike trains should also stop once RSSI clears the scan
   threshold. (macOS offers no supported band-pinning CLI, so this is
   placement, or a router-side 5 GHz-only SSID for these two machines —
   owner's call; not attempted here to avoid disturbing the live session.)
3. **Attack the Mac's 500 ms spike trains directly for streaming.** Raising
   RSSI (see #2) is the likely cure since the trains look like weak-signal
   roam scans; verify during a live Lyte run by watching whether stalls
   disappear when the Mac sits closer to the AP. AWDL was ruled out idle but
   should be re-checked under load (`sudo ifconfig awdl0 down` during a
   stream — Lyte's own helper uses AWDL, so know the interaction). Expected:
   estimator ramps from 13–17 to **50–100+ Mbps on today's PHY** once the
   twice-a-second events stop; combined with #1 the streaming path should
   comfortably hold 100+ Mbps.

Lesser knobs, for completeness: narrowing pup to 80 MHz would trade half the
subcarriers for ~3 dB per-subcarrier SNR (roughly goodput-neutral, somewhat
more stall-resistant); `iwlmvm power_scheme=1` (CAM) is available but power
save is already off and pup's latency is already clean, so expect nothing;
the Xfinity gateway offers no per-band transmit-power or airtime-fairness
knobs worth chasing.

## Anomalies logged along the way

- pup **rebooted at ~14:02 local** during this study (uptime reset; not
  network-related, not initiated by this work). It wiped the joint-gate
  sandbox in `/tmp`; the owner's 41151 host loop auto-restarted.
- Roams: only 4 in the prior 26 h uptime, 3 clustered 12:07–12:18, including
  one association denial `code=53` (invalid PMKID — SAE cache artifact on
  the 6 GHz BSS, retried and succeeded). Roam flapping is real but episodic,
  not the steady-state limiter.
- `iw survey dump` reports nothing on this iwlwifi firmware without a scan;
  channel-busy evidence comes from the Mac's CCA (6 %) instead.
- `aptd` had released the dpkg lock by 20:04 UTC; iperf3 installed cleanly
  on both ends (pup: apt, Mac: brew) and the pup server (port 41200, under
  `timeout 1200`) was killed and its logs removed after the runs. `awdl0`
  was restored up. Nothing under `~/.config/lyte-host/` was touched —
  `portal_token`, `noise_static.key`, `paired_clients` all verified present.
