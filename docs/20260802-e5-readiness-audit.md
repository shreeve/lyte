# E5-Readiness Audit — what the portal host does that the direct host doesn't (yet)

*2026-08-02, the morning after `first-light` and the #67 eye demolition.
Goal: the punch list between today's standing `--backend portal` loop
and the one-line flip to `--backend direct --encoder native` — the flip
that deletes the portal path, burns `vendor-ffmpeg.sh`, and mints the
`self-hosted` tag.*

## Capability matrix (code-audited, main.swift + DirectEyeLeg)

| Capability | Portal host | Direct host | Verdict |
|---|---|---|---|
| Video capture/encode | PipeWire → hevc_nvenc (vendored libav) | KMS doorbell → EGL blit → native VAAPI | ✅ direct proven (parity, live legs, first-light) |
| Input injection | Mutter RemoteDesktop | **same leaf — shared** ("independent of the portal capture", main.swift HS-13) | ✅ no gap |
| Clipboard (text+images) | MutterClipboardLeaf | **same leaf — shared** (constructed in sessionMode, backend-agnostic) | ✅ no gap |
| Audio (Opus 5 ms + RS FEC) | PipeWire monitor capture | **same AudioWire — shared** | ✅ no gap |
| Cursor | composited into video | 0x24 shape channel (E3) | ✅ direct is *better* |
| Rate directives | vendored no-reset reconfigure | RC misc buffer, next frame | ✅ no gap (applies live) |
| Advertise / pairing / Noise / teardown | shared SessionWire | shared SessionWire | ✅ no gap |
| **IDR-on-demand while screen is static** | idle-floor tick re-encodes → demand honored within a tick | **`takeForcedIdrDemand()` polled only inside the fb-changed branch — a recovery IDR demanded on a static screen waits for the next pixel change, potentially forever** | 🔴 **GAP 1 (correctness)** |
| **Chroma declaration truthfulness** | probeRext444Encode opens a real NVENC Rext leaf → [420, 444] honest | **same probe runs (NVENC!) and declares [420, 444] — but the native VAAPI seat encodes NV12 4:2:0 only; a Best-tier client would negotiate a chroma the seat cannot produce** | 🔴 **GAP 2 (correctness)** |
| Idle-floor steady supply + quality ratchet (`--ratchet`) | tick timer re-encodes retained pixels; capped-CQ refinement walks quality up when idle | **absent — direct encodes only on damage; no refinement** | 🟡 GAP 3 (quality parity) |
| Mid-session mode change (resolution/refresh) | PipeWire renegotiates | **width/height read once at start; new-dims tickets get scaled into the original-size encoder target** | 🟡 GAP 4 (robustness) |
| Login-screen capture | impossible (needs session portal) | possible in principle (CAP_SYS_ADMIN) | ➕ future direct advantage, not a blocker |

## The punch list (ranked)

*Items 1 and 2 landed same-day (the static-IDR re-encode + the
truthful [420] declaration on direct); `static_idrs` joined the
direct books. The live static-IDR path awaits its first real
recovery-on-quiet-desktop to show a nonzero count.*

1. **Serve forced-IDR demands on a static screen** — move the
   `takeForcedIdrDemand()` check out of the fb-changed branch; on
   demand with no new damage, re-encode the last blitted surface as
   IDR. Small, testable (a gate: demand while static → IDR within a
   poll interval). Without this, a client that loses the opening IDR
   on a quiet desktop stares at await-IDR until something moves.
2. **Truthful chroma on direct** — the declaration must follow the
   seat: direct+native declares [420] only, until Rext 4:4:4 lands in
   the native pens (the existing ladder item). One conditional plus a
   banner line; the Best tier honestly disappears on direct rather
   than lying.
3. **Idle-floor / ratchet decision** — either port the steady-supply
   tick + ratchet refinement to the direct leg, or consciously accept
   damage-driven-only for the flip and file refinement as post-E5
   work. (Recommendation: a minimal 1 Hz retained-surface keepalive
   first — it also carries GAP 1's re-encode machinery — ratchet
   refinement later.)
4. **Mode-change survival** — detect ticket dims ≠ encoder dims;
   minimum viable: end the session cleanly with a typed reason (the
   client auto-re-dials and the fresh host reads new geometry);
   deluxe: re-open the encoder in place.
5. **Soak evidence** — a multi-hour owner-driven direct+native
   session (the portal loop's daily-driver bar), plus the #34 storm
   replay pointed at a direct leg.

## Flip-day checklist (after the list is empty)

- `lyte-loop.sh`: `--backend direct --encoder native
  --advertise-interface enxf8e43b7ede7c` (or graduate the loop to a
  systemd user unit — filed).
- setcap posture: direct KEEPS cap_sys_admin (GETFB2); the portal
  cap-shed (#65) becomes dead code and burns with the portal path.
- Delete: portal/mutter ScreenCast backends, PipeWire video capture,
  CHevcEncode + CLibAV + vendor-ffmpeg.sh + the no-reset patch,
  synthetic-motion's nvenc leg (or rebase it on the native seat).
- Mint the `self-hosted` tag with the burn in its annotation.
