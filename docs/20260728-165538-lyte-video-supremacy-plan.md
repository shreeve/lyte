# Lyte video supremacy — the ranked battle plan (2026-07-28)

*Commissioned by the owner: "Analyze the best strategies to make the video
as clean and beautiful as possible. We CANNOT LOSE to Sunshine and
Moonlight — we are DESIGNED SPECIFICALLY TO BEAT THEM at high resolution
and motion as well as low motion." An analysis-only doc: evidence from
today's quality probe (`docs/20260728-164746-lyte-video-quality-probe.md`),
the HS-22a/b wave ledger (HANDOFF.md), the image-quality pillar
(`docs/20260720-191701-...`), the Sunshine source analysis
(`docs/sunshine-v2026.715.205118.md`), the host encoder sources, and
2026 web evidence on what Sunshine/Moonlight actually ship. No live runs;
no package sources touched.*

---

## 0. TLDR verdict — where we stand today, honestly

**What we already beat them at, with evidence:**

- **Static and ordinary-desktop quality.** The ratchet converges static
  content to 53.5 dB luma (gate ≥ 50 — visually lossless), QP 12, then
  goes silent; the 1 Hz pulse is retired (183 → 3 IDR over 5-minute
  runs). Sunshine re-encodes the last frame at fps/2 under CBR forever —
  a static desktop costs ~half the stream bitrate and never sharpens
  past its fixed rate posture (sunshine doc §7 "idle floor", §14.1).
  We spend ~0.4 Mbps where they spend ~10, and our pixels are better.
- **Loss behavior.** Our wire heals: 0.02% datagram loss fully repaired
  (FEC + targeted NACK, 0 unseal failures, 5,692 emitted → 5,689 decoded
  + 2 repaired). Sunshine's client loss stats are *parsed and logged
  only — zero adaptation* (§6, §14.2); past FEC parity, Moonlight's only
  remedy is a full IDR request. Loss on their wire is smear; on ours it
  is invisible.
- **Idle bandwidth, encryption, adaptation** — the COMPARISON.md wins
  stand: damage-driven silence, Noise on every datagram, measured-
  delivery congestion control vs their configured-blind CBR.

**Where we are still behind, today, on our own numbers:**

1. **Heavy motion plateaus at ~38 fps, not 60.** Full-quality motion
   content at QP 17 wants ~24 Mbps of payload; the recipe caps the pacer
   at 20 Mbps, the pacer backs up (296 ms max queue delay), capture
   supply adapts down. A Moonlight user on the same LAN drags the
   bitrate slider to 50–150 Mbps and streams 60 fps — their pacing
   *assumes* a gigabit link (hard-coded 80% of 1 Gbps, sunshine doc
   §6.9). Our own estimator measured the path delivering 90 Mbps while
   our recipe sat on 20. We are losing this leg to a config default.
2. **The armed VBV policy makes motion uglier than their no-policy.**
   105 directives / 110 IDR / QP sawtooth 16↔50 in 150 s of saturated
   motion, one crash to the 500 kbps floor — where the
   `--no-vbv-reconfigure` twin spent 0 directives / 3 IDR at QP 17
   FLAT, and where Sunshine's fixed CBR never reconfigures at all. On a
   clean overprovisioned LAN, their *dumbness is currently smoother
   than our intelligence*. Every directive is an encoder reset + forced
   IDR (FFmpeg nvenc.c, read at HS-22); findings (i) climb-ladder churn
   and (ii) estimator self-reference are the named owners.
3. **Chroma.** We stream 4:2:0 with the RGB→YUV conversion happening
   inside NVENC on a `bgr0` input, colorspace/range unpinned in code.
   Sunshine ships YUV 4:4:4 on Windows stable (since v2025.118) and on
   Linux NVENC in master (PR #4965); Moonlight-qt advertises "YUV 4:4:4
   support (Sunshine only)" as a headline feature. The pillar already
   decided HEVC Rext 4:4:4 is our Work mode; it is unbuilt. On colored
   text fringing, they currently ship something we only planned.

**The shape of the campaign:** our losses are all policy and roadmap, not
architecture. Nothing below requires new wire vocabulary or touches the
frozen vectors' semantics. The two supply-side fixes (R1, R2) are the
whole visible difference under motion; chroma (R3) is the desktop-beauty
crown; the rest compounds.

---

## 1. The ranked ladder

Each rung: what, evidence, expected visible effect, effort, risk,
territory. Ranked by visible-payoff-per-effort with dependencies
respected.

### R1 — HS-22c: silence the directive-IDR churn and cut the estimator's self-reference

**What.** Two coupled fixes in the rate-policy seam:

- *Coalesce the climb ladder.* Today every ~10%-rung loosening on the
  way out of a squeeze is a directive — a KNOWN encoder reset + forced
  IDR — so one dip-and-recover cycle costs ~8–10 IDRs
  (`EncoderVbv.swift` rise path; HANDOFF finding (i)). Candidate
  policies, in order of preference: **restore-only** (inside a squeeze,
  tighten freely but never loosen until the clean-path restore — one
  directive down, one directive up per episode); failing that, a much
  longer rise-hold (5–10 s) plus rung hysteresis (a rise must clear the
  *next* k-rung, not just the deadband). The k-ladder itself
  (`vbvBudgetWindows`) stays — it priced the squeeze correctly in
  HS-22b leg (c); the churn is purely the *stepping*.
- *Fix estimator self-reference under a squeezed pacer.* Finding (ii):
  when the pacer is the bottleneck, ≥8-packet trains measure OUR OWN
  pacing, each directive-IDR bumps the queue exactly when the estimator
  is touchy, and overuse re-anchors to 0.85× of self — the spiral that
  crashed run A to the 500 kbps floor on an unimpaired wire. The
  estimator (`RateEstimator.swift`) needs a self-limitation gate: when
  delivery samples arrive at ≈ the pacer's own configured rate while
  the pacer reports standing backlog, they are measurements of us, not
  of the path — they may hold the rate, never anchor a fall. (The
  min-train gate stopped garbage anchors; this stops *honest
  measurements of the wrong thing*.)

**Evidence.** The strongest A/B in the repo: 105 directives / 110 IDR
(44/min), QP p95 47, one floor crash vs **0 / 3 at QP 17 flat** on the
same content, same wire, same build (probe §3). HS-22b leg (b): 26
directives / 38 IDR from three Wi-Fi weather dips the disarmed twin
self-healed invisibly. The load-bearing mechanism is pinned in
`EncoderVbv.swift`'s header: every rate/VBV reconfigure sets
`resetEncoder = 1, forceIDR = 1`.

**Expected visible effect.** The QP 16↔50 sawtooth — the thing an
eyeball reads as pulsing/choppiness under motion — disappears. Under
real squeezes the policy still conforms frames (that machinery passed
leg (c)); it just stops paying ~10 IDRs per recovery. This is the #1
lever and it is pure win: the twin already *shows us the target state*.

**Effort.** M. Both components are sans-IO policy classes with existing
suites (Host 142/142 pins every HS-20/22 shape — the new behavior needs
new pins, not reshaped ones). A live A/B rerun of the probe's motion leg
is the gate.

**Risk.** Low. Restore-only inside a squeeze risks running tighter than
necessary for a few seconds (quality slightly lower mid-squeeze) — the
safe direction. The estimator gate must not blind us to *real* path
degradation that coincides with backlog; the gate should require
"delivery ≈ own pacer rate" (a signature, not a mere coincidence).

**Territory.** Host/ only.

### R2 — Raise the ceiling: the recipe must not lose to a Moonlight slider

**What.** Three moves on the budget recipe:

- **Raise the LAN default.** `--bitrate-mbps` defaults to 10 and the
  probe's "quality" posture is 20; the pacer default (`--wire-rate-mbps`)
  is 20. On a wire our own estimator measured at 90 Mbps, this is a
  self-inflicted 38 fps. A LAN session should open at **50 Mbps cap**
  (pacer to match) — comfortably inside gigabit *and* inside 5 GHz
  Wi-Fi reality, ~2× the content demand the probe measured (~24 Mbps at
  QP 17). Capped-CQ means an idle desktop still costs ~0.4 Mbps: unlike
  Sunshine, raising OUR cap costs nothing when content doesn't want it.
  That asymmetry is the structural advantage — press it.
- **Adaptive per-path, not per-knob.** The estimator already measures
  delivery continuously; the ceiling (`RateEstimatorConfig
  .ceilingBitsPerSecond` = the session rate) is the one number still
  configured, not measured. Medium-term: open at the LAN default and
  let sustained clean evidence raise the *session* ceiling toward
  measured delivery × a safety factor (the pillar's congestion sibling
  already owns "available-bandwidth estimate"). No wire change — the
  W7 spine carries no bitrate key in v1; this is host policy.
- **Session posture split, minimal version.** A full "desktop vs
  motion" session mode is premature — capped-CQ already *is*
  content-adaptive (bits flow only where damage is). What the probe
  actually shows is a single scalar shortage. Recommendation: one
  recipe, higher cap, and revisit a posture split only if 4:4:4 (R3)
  forces one (its natural shape: 4:4:4 Work / 4:2:0 Play — §R3).

**Evidence.** Probe §3: offered load ~24 Mbps vs 20 Mbps recipe → both
runs plateau ~38 fps; file mode does 60 fps on identical content at the
same cap (proof the encoder isn't the limiter); freshVideo max queue
delay 296 ms (pacer backpressure is the mechanism). Sunshine: client-
configured bitrate, pacing assumes gigabit (§6.9); Moonlight defaults
~20 Mbps at 1080p60 but the slider runs to 150 Mbps and LAN users use
it. Audio strain (94k underruns, probe §5) rides the same squeezed wire
and is relieved by the same headroom.

**Expected visible effect.** Heavy motion at 60 fps instead of 38 —
the single most legible "we don't lose to Moonlight" number. Also
un-strains audio under motion.

**Effort.** S for the default + pacer pairing (config recipe, books
already print everything needed to verify); M for the
evidence-raised ceiling. Gate: rerun the probe's motion leg, expect
~60 fps host supply and client decode with QP flat.

**Risk.** Low for the default (the estimator still governs the live
rate downward; a 50 Mbps cap on a 20 Mbps path just engages the
existing machinery — after R1 that engagement is cheap). The
evidence-raised ceiling needs the R1 estimator fix landed first, or
the self-reference spiral gets a bigger stage.

**Territory.** Host/ (recipe, estimator ceiling policy); root only if
the client's stats line should show the negotiated cap.

### R3 — Chroma supremacy: 4:4:4 Work mode + colorspace hygiene (the H4 pillar work, pulled forward)

**What.** Two stages, deliberately split:

- **Stage A (cheap, immediate): pin the colorspace/range we already
  ship.** Today `encode.c` feeds `bgr0` straight into `hevc_nvenc` and
  sets no `colorspace`/`color_range`/VUI fields — the RGB→YUV matrix
  and range are whatever NVENC defaults to, unsigned in the bitstream,
  and the decoder guesses. The pillar (§2) calls the limited/full
  mismatch "the classic smeared-desktop bug" and notes the client's
  Rec.601-limited posture as a known bug. Set explicit BT.709
  (full-range where the conversion honors it), write it into the VUI,
  assert it client-side. This costs a few lines and can recover real,
  visible text contrast *now*, in 4:2:0.
- **Stage B (the crown): HEVC Rext 4:4:4 as the negotiated Work mode**
  per the pillar's standing decision — host-side RGB→YUV444 conversion
  (implemented independently in Lyte's native direct-eye GPU path), Rext
  profile bit, capability tuple negotiation,
  client `VTIsHardwareDecodeSupported` + real test decode. Apple
  Silicon VideoToolbox hardware-decodes HEVC Rext 4:4:4 8/10-bit on
  every generation — this is where we structurally beat Moonlight:
  their 4:4:4 rides Sunshine's newest code and falls back to *software
  decode* on clients without GPU 4:4:4 support (moonlight-qt #1852
  shows exactly that failure on current hardware); our client fleet is
  Apple Silicon, where the hardware path always exists.
  Shape: 4:4:4 is the Work-mode default at desktop fps; Play mode
  (motion-first) stays 4:2:0@60 — the pillar's split, which is also the
  honest bandwidth answer (4:4:4 costs ~2× chroma samples; at R2's
  50 Mbps LAN budget, 4:4:4 desktop work is easily affordable).
  10-bit stays deferred per the pillar (§2): measure banding after the
  ratchet converges at 4:4:4; don't pay for two mitigations before
  measuring one.

**Evidence.** Pillar §1–2 (the decision + hardware matrix, with the
NVENC/VideoToolbox citations); sunshine doc §8 (their 4:4:4
implementation inventory — what to crib); web: Sunshine Windows 4:4:4
since v2025.118, Linux NVENC 4:4:4 in master only (PR #4965, merged
after long absence — stable releases lack it); moonlight-qt README
lists YUV 4:4:4 as a flagship feature. COMPARISON.md already concedes
"the one axis where RDP currently beats us" is 4:4:4 text.

**Expected visible effect.** Stage A: text contrast/tint correctness —
subtle but real, and it removes a latent "why does the desktop look
slightly off" class of bug. Stage B: color fringing on sharp edges
gone — syntax-highlighted terminals, single-pixel colored strokes, UI
hairlines. This is THE visible "beautiful desktop" feature, and the §7
pillar gates (chroma gratings ±2 codes — "the gate 4:2:0 cannot pass,
which is the point") make the win objective.

**Effort.** Stage A: S. Stage B: L — conversion kernel (CUDA leaf or
shader), profile/negotiation plumbing through the capability tuple,
client decoder config, the §7 harness to gate it. It is the largest
item on this ladder and the pillar already scoped it as its own wave
(H4).

**Risk.** Stage B: encoder throughput at 4:4:4 (Ada encodes it, but
budget the fps check into the probe); the full-range-through-
VideoToolbox round-trip trap the pillar names (0/255 byte-exact gates
exist for exactly this). Mitigated by the Work/Play split — motion
never rides 4:4:4.

**Territory.** Host/ (conversion + encode), Wire/ (capability tuple —
vector APPEND), root (decode config + assert). A full wave, not a
slice.

### R4 — Encoder recipe audit: stop shipping Sunshine's floor

**What.** We currently run **Sunshine's exact recipe**: `p1` preset,
`ull` tuning, `multipass qres`, surfaces 1, no AQ, no lookahead,
infinite GOP, zero B-frames (`encode.c` — the comment even cites their
doc). That was the right H0 posture: match the incumbent, ship. But p1
is NVENC's *fastest/lowest-quality* preset, and NVIDIA's own guidance
reserves p1 for throughput-bound cases; quality presets (p4+) buy
measurable BD-rate at the same bitrate. At 2048×1280@60 a single Ada
NVENC has enormous headroom (their published benches run 4K).
Candidates, each a one-flag A/B against the §7-style PSNR harness:

- **Preset p4** (same ULL tuning — tuning, not preset, controls the
  latency shape; ULL forbids lookahead/B-frames regardless). Expect
  low-single-digit dB or bitrate-equivalent gains, content-dependent.
- **Spatial AQ (+ temporal AQ)** — steers bits toward complex regions;
  on desktops that's text edges and gradients. Sunshine exposes it but
  defaults it off; we don't set it at all.
- **Keep**: zero B-frames (a B-frame is a reorder delay by definition —
  one frame of added latency minimum, and our packetizer/PTS invariant
  assumes display order; same invariant Sunshine's protocol rests on),
  zero lookahead (`rc-lookahead N` = N frames of buffered latency —
  poison for input→photon), infinite GOP + damage-driven IDR (already
  strictly better than any cadence), capped-CQ + ratchet (the pillar's
  §3 reasoning stands; the probe validates it at QP 12/53.5 dB).

**Evidence.** `encode.c` lines 113–122 (the recipe); NVENC programming
guide (P1 fastest → P7 slowest, tuning table recommending ULL+CBR only
for *strictly bandwidth-constrained* channels — LL is the recommended
posture for high-bandwidth cloud gaming, worth an A/B too); 2026
longitudinal NVENC study (arxiv 2605.01187): standard-latency modes
hold ~constant low latency across P1→P4 while UHQ tuning is the thing
that explodes latency — i.e., preset moves are cheap, tuning moves are
not. Sunshine ships p1 as *their* default — matching them here
surrenders a free axis.

**Expected visible effect.** Honest answer: modest and content-
dependent — sharper motion at the same bitrate (better bit placement),
slightly better gradients with AQ. This is a compounding win, not a
headline. It matters most *after* R2 (at 50 Mbps the encoder is rarely
starved, so preset gains show up as texture retention under motion).

**Effort.** S per flag + the probe rerun. The discipline: one flag per
A/B, PSNR + fps + input-photon numbers, adopt only what measures.

**Risk.** Encode-time regression eating the 60 fps budget at higher
presets — the A/B gate catches it; revert is one flag.

**Territory.** Host/ (encode.c + a probe leg).

### R5 — Measurement doctrine: the beauty bar as a standing gate

**What.** Today's probe was a one-off with a rediscovered method. Make
it a leg that cannot rot:

- **Script the probe** (`Host/Scripts/quality-probe.sh` or a doc'd
  runbook): the LYTE_DUMP_RAW static leg + the motion leg + the wire
  A/B, emitting one summary block.
- **The beauty bar** — a small set of standing numbers with pass bars,
  reported per release/wave in HANDOFF:
  - static converged luma PSNR ≥ 50 dB (holds today: 53.5);
  - motion last-frame PSNR ≥ 55 dB at the recipe cap (today: 56.7 median);
  - heavy-motion sustained fps ≥ 55 on a clean LAN (today: FAILS at 38 — R2's gate);
  - clean-path IDR rate ≤ 2/min under motion (today: FAILS armed at 44/min — R1's gate);
  - clean-path directives = 0 (holds by construction since HS-22a);
  - wire frame loss ~0 (holds: ≤1 per 150 s).
- **The §7 corpus harness lands with R3 Stage B** (text-region RGB
  PSNR, chroma gratings, range round-trip, visual goldens) — the pillar
  already specifies it; it is the acceptance gate for 4:4:4 and the
  regression guard for every later recipe change (R4's A/Bs should
  reuse it the moment it exists).

**Evidence.** The probe itself: its method had to be *rediscovered*
from a month-old gate (`493b6bd`), and its two FAIL rows above are
precisely the two competitive losses. A number that isn't standing
doesn't defend itself.

**Expected visible effect.** None directly — this is what keeps every
other rung's win from silently regressing, and it converts "we beat
Sunshine" from a claim into a per-release number.

**Effort.** S–M (scripting + ledger convention; the corpus harness is
inside R3's estimate).

**Risk.** None. **Territory.** Host/ scripts + docs.

### R6 — Weaponize the structural advantages (make them visible, not architectural)

**What.** We hold four assets Sunshine/Moonlight structurally cannot
match; each should surface as a *visible* behavior:

- **Damage-driven encoding** → the bit-budget asymmetry: we never pay
  for unchanged pixels, so our *cap* can sit high (R2) with zero idle
  cost, and our saved bits already fund the ratchet. Sunshine burns
  ~half its bitrate re-encoding a static desktop (fps/2 floor) and
  never sharpens past its rate posture. Post-R2, the demo line writes
  itself: "same 50 Mbps ceiling; their desktop idles at 25 Mbps and
  stays lossy, ours idles at 0.4 and converges to visually lossless."
- **FEC + NACK repair** → keep the probe's drop table in COMPARISON.md
  current; on lossy-Wi-Fi legs the difference is smear vs nothing, and
  the netem harness (`Scripts/netem/`) can reproduce it on demand.
- **Per-frame policy visibility (the books)** → after R1/R2 land,
  the quality line (QP avg, frame percentiles, applied posture,
  ceiling/pacer) is the receipts. Consider a client-side one-key
  "session quality report" dump — the honest-numbers culture as a
  user-facing feature. Fix the estimator summary's absurd delivery
  figures (probe §5 — cosmetic formatter bug) so the receipts aren't
  embarrassing.
- **Sans-IO testability** → every rung above gates on deterministic
  suites before a live leg; that is *why* this ladder is cheap to walk.
  Nothing to build — just the note that policy experiments (R1's
  restore-only vs hysteresis variants) can be raced in virtual time
  instead of live-run-per-variant.

**Effort.** S (mostly reporting/doc); the substance rides R1/R2.
**Territory.** docs/ + small host/client polish.

### R7 — AV1: a reach play, not a quality play — hold the pillar line

**What.** Confirm and keep the standing decision: AV1 exists for the
browser client (B-4's `av1 = 2` capability append, `av1_nvenc` for
browser sessions), NOT for native-session quality.

**Evidence.** Three hard facts, all already pinned in the pillar and
scoping docs and re-verified against 2026 sources: (1) Ada NVENC AV1 is
**4:2:0 only** — no 4:4:4 AV1 encode exists in the NVENC line, so AV1
is disqualified from the Work-mode chroma crown by hardware; (2) macOS
AV1 decode is hardware-only on M3+/A17+, *no software fallback in
VideoToolbox*, and moonlight-qt's own M3 testing found the AV1 decoder
choking at high bitrates where HEVC held (issue #1125) — an M1/M2 Mac
cannot play AV1 at all; (3) AV1's quality-per-bit edge (~1.5–2 dB /
~40% vs H.264 per NVIDIA's Ada numbers) is an edge over *H.264* and at
*low bitrates* — at 20–50 Mbps desktop rates vs HEVC the gap narrows
toward noise, and our fidelity numbers (QP 12–18, 53–57 dB) show the
codec is not the limiter anywhere on our ladder.

**Expected visible effect.** None for native sessions — that is the
point. Browser reach (Chrome/Linux, Firefox) arrives via B-4 as
planned.

**Effort/risk.** Zero new work; the risk would be *doing* it — spending
an encode profile and a packetizer seam on a codec that can't carry
4:4:4 and that a third of the Mac fleet can't decode.

**Territory.** Unchanged (B-4 in the browser ladder).

### R8 — Client presentation polish (the last inch to the glass)

**What.** Smaller items the evidence flags, none urgent, all cheap to
check while the big rungs land:

- **Pixel-exact rendering audit.** The pillar (§5) mandates decoded
  pixel → device pixel identity on Retina; verify the
  `AVSampleBufferDisplayLayer` path actually renders 1:1 at the default
  window size and that fit-to-window is the *labeled* exception. Any
  silent resample is a text-quality tax no host work can refund.
- **Present-ASAP stays.** No jitter buffer by design; the probe shows
  delivery is not the stutter source. Note for the WAN future, not now.
  (Moonlight's macOS renderer choice — AVSampleBufferDisplayLayer vs
  Metal — is currently a live latency bug on their side, #1885; ours
  present-ASAP through the same layer with measured 21 ms first-frame.
  Keep the measurement standing, nothing to copy.)
- **Audio reserves under motion** (probe §5: 94k underruns while the
  wire was squeezed): R2's headroom is the real fix; verify the
  estimator's audio/control reserve subtraction
  (`frameByteCeiling = R×B/8 − reserves`) keeps the audio lane honest
  at the new cap, and that the k-ladder's window borrowing can't starve
  a 5 ms cadence.
- **Estimator summary formatter** (272,666 kbps "delivery") — fix the
  cosmetic bug before it ends up in a screenshot.

**Effort.** S each. **Territory.** root (render audit, formatter), Host/
(reserve check).

---

## 2. Proposed next-wave slice list

Ordered; territories per AGENTS.md (one worker per package).

| Slice | Territory | What lands | Gate |
|---|---|---|---|
| **HS-22c** (first — the known #1 lever) | Host/ | R1: climb-ladder coalescing (restore-only posture, or rise-hysteresis if restore-only measures worse in virtual time) + the estimator self-reference gate | Suites: new pins for episode-shaped directives, every HS-20/22 squeeze pin intact. Live: rerun the probe's 150 s saturated-motion A/B — armed policy within ≤ 3 IDR and ≤ 2 directives of the disarmed twin on a clean path; leg (c) squeeze conformance unchanged |
| **HS-23** | Host/ | R2: LAN recipe 50 Mbps cap + pacer pairing; audio-reserve verification at the new cap; (stretch) evidence-raised session ceiling | Live: probe motion leg sustains ≥ 55 fps decoded at QP ≤ 20 flat; audio underruns ~0; static leg unchanged (0.4 Mbps idle) |
| **HS-24** | Host/ | R4: encoder A/B ladder — p4, then ±spatial/temporal AQ, then LL-vs-ULL tuning; one flag per leg against the beauty bar | Adopt only flags that improve PSNR-at-bitrate with fps ≥ 60 and input→photon within the H2 band; every change re-runs the probe |
| **Q-1** | Host/ scripts + docs | R5: the probe as a script + the beauty-bar table in HANDOFF convention; estimator formatter fix | Script reproduces today's numbers at HEAD; bar rows green except the two known FAILs (which HS-22c/23 turn green) |
| **H4 wave: 444a** | Host/ | R3 Stage A: explicit BT.709 + range on the encoder, VUI signaled; client asserts | Range/tint gates from pillar §7 (d) patches; no PSNR regression |
| **H4 wave: 444b…** | Wire/ + Host/ + root | R3 Stage B: capability tuple (vector APPEND), CUDA RGB→YUV444 leaf, Rext profile, client Rext decode + §7 corpus harness | The pillar §7 gates verbatim — chroma gratings ±2 codes, text-region RGB PSNR, goldens; Work/Play split negotiated |
| (unchanged) | Web ladder | R7: AV1 stays exactly B-4 | B-4's own gates |

HS-22c and Q-1 can run as one Host/ worker's sequence; HS-23 follows
HS-22c (the estimator fix must precede a bigger cap). The H4 wave is
the next *big* commitment after the supply-side pair — it is where
"beautiful" stops meaning "correct and smooth" and starts meaning
"indistinguishable from local."

---

## 3. Open owner decisions

1. **The LAN ceiling number.** 50 Mbps recommended (2× measured content
   demand, ~half of what the estimator saw the path deliver). Higher
   (80–100) is defensible on wired; 50 keeps 5 GHz Wi-Fi honest.
   Decide the default; the estimator governs below it either way.
2. **Session posture split.** Recommendation: NO desktop/motion recipe
   split now (capped-CQ is already content-adaptive); the split arrives
   naturally as Work(4:4:4)/Play(4:2:0) with H4. Confirm.
3. **H4 priority.** Chroma (R3 Stage B) vs the H3 feature ladder
   (F-3/F-4 file drop, browser slices) — this doc argues Stage A is
   free NOW and Stage B is the biggest remaining *visible* quality
   move, but it is a full wave and H3 is mid-flight. Where does 4:4:4
   sit in the queue?
4. **Preset adoption bar.** R4 proposes: adopt a flag only on measured
   PSNR-at-bitrate gain with fps and input→photon held. Bless the bar
   (it prevents recipe drift by vibes).
5. **10-bit.** The pillar defers it until the §7 gradient goldens band
   after 4:4:4 converges. Reaffirm (this doc found no new evidence to
   move it).

---

*Method note: competitor claims above cite the in-repo Sunshine source
analysis (master @ 9d2409f), the Moonlight-qt repo/issues (#1125, #1852,
#1885), Sunshine PR #4965 and release v2025.118 (4:4:4 timeline), the
NVENC 13.1 programming guide, NVIDIA's Ada AV1 numbers, and the 2026
NVENC longitudinal study (arxiv 2605.01187) — specifics, not folklore.
Our own numbers cite the 2026-07-28 quality probe and the HS-22a/b wave
ledger. Nothing here changes wire bytes; the frozen vectors sleep
untouched except the two named APPENDs (capability tuple, av1 id) that
were already planned.*
