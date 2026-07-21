# Lyte Protocol — Image Quality Pillar (2026-07-20)

## TL;DR

**HEVC Rext 4:4:4 is the codec decision; everything else follows from it.**
HEVC is the only codec that carries full-chroma desktop text end-to-end on our
reference hardware today (Ada NVENC encodes HEVC 4:4:4; Apple Silicon
VideoToolbox hardware-decodes HEVC Rext 4:4:4 up to 10-bit). AV1 stays a
negotiated hook for the Chromium browser client, not the primary. Work mode is
**4:4:4, full-range BT.709, capped-CQ VBR with a quality ratchet** that
refines a settled desktop toward visually lossless using otherwise-idle
bandwidth; Play mode is today's 4:2:0 low-latency CBR. Per-region QP is
**rejected for v1** — HEVC skip blocks already give static regions a free
ride, and NVENC's region machinery isn't reachable through libavcodec anyway.
Pixel-exact 1:1 rendering is the Work default the protocol must guarantee, not
merely permit. §7 defines the objective "crisp text" gates every future slice
must pass.

Sibling interfaces assumed (stated once, used throughout): the congestion
sibling provides a continuously updated **available-bandwidth estimate and a
loss/backoff signal**; the timing sibling owns pacing and A/V scheduling; the
transport sibling provides **session-parameter renegotiation** (a codec or
chroma change is a clean stream restart with IDR, not a midstream mutation)
and the capability-negotiation carrier for every field named below.

---

## 1. Codec strategy: HEVC primary, AV1 as a negotiated browser-era hook

**Decision: HEVC Rext is the primary and only v1 codec. H.264 remains the
compatibility floor. AV1 is negotiated, off by default, and exists for the
future WASM/WebCodecs client — not for quality.**

The hardware facts that force this:

- **Host encode (RTX 4050, Ada).** NVENC on Ada encodes HEVC 4:2:0/4:4:4 at
  8/10-bit including lossless mode; Ada's much-advertised AV1 encoder is
  **4:2:0 only** (8/10-bit) — no 4:4:4 AV1 encode exists on Ada (4:2:2/4:4:4
  AV1 encode arrives nowhere in the current NVENC line; even Blackwell's
  additions are HEVC-side). See the
  [NVENC application note feature matrix](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvenc-application-note/index.html).
- **Client decode (Apple Silicon).** VideoToolbox hardware-decodes **HEVC
  Rext 8/10-bit 4:0:0/4:2:0/4:2:2/4:4:4** on all Apple Silicon
  ([community-verified support matrix](https://github.com/StaZhu/enable-chromium-hevc-hardware-decoding)).
  AV1 decode is **hardware-only on M3+/A17 Pro+, Main profile (4:2:0)**, with
  no system software decoder at all
  ([Bitmovin's Apple AV1 tracker](https://bitmovin.com/blog/apple-av1-support/)) —
  an M1/M2 Mac cannot play AV1, period, and early M3 AV1 decode showed
  high-bitrate 4K instability in exactly our use case
  ([moonlight-qt #1125](https://github.com/moonlight-stream/moonlight-qt/issues/1125)).
- **Browser client (post-H6).** WebCodecs decode support splits cleanly:
  HEVC is near-universal on Safari and Chrome-on-macOS (both ride
  VideoToolbox) and nearly absent on Firefox/Edge; AV1 is universal on
  Chromium/Firefox and hardware-gated on Safari. Together they cover ~99.7%
  of sessions
  ([WebCodecs Fundamentals 2026 dataset](https://webcodecsfundamentals.org/datasets/codec-analysis-2026/)).

So the matrix has exactly one column that satisfies "crisp text on the wire
today": HEVC Rext. Sunshine/Moonlight already ship this path — Sunshine
negotiates `chromaSamplingType=1`, switches the HEVC profile Main→Rext, and
advertises SCM bits `0x1000`/`0x2000` for Rext 8/10-bit 444 from live encoder
probes (docs/sunshine-v2026.715.205118.md §4, §7); the Moonlight-macOS lineage
decodes it through stock VideoToolbox. Nothing exotic: Rext 4:4:4 is an
ordinary profile bit plus a chroma_format_idc, and Apple's decoder eats it.

**Negotiation.** The native protocol advertises per-codec capability tuples:
`(codec, profile, chroma, bitDepth, maxLumaPixelRate)`, populated from
**empirical encoder probes on the host** (Sunshine's probe discipline, already
adopted in HOST-PLAN §3) and from decoder probes on the client
(`VTIsHardwareDecodeSupported` + a real test decode; WebCodecs
`isConfigSupported` in the browser). The client picks; Work policy prefers
`hevc/rext/444/8` and falls to `hevc/main/420/8` with a **named degradation
the user can see** — never a silent chroma fallback (the #4836 lesson).
AV1 negotiation slots in later with zero protocol surgery: it is one more
tuple, chosen only when the client is a Chromium browser without HEVC and the
session accepts 4:2:0.

## 2. Chroma and text: the Work/Play split, bit depth, and the range bug

**Chroma policy.** Work mode = 4:4:4. Play mode = 4:2:0 at full display rate.
This is the product's one toggle expressed in chroma: subsampling is what
turns single-pixel colored text (syntax-highlighted terminals are the worst
case) into smeared fringes, and no amount of bitrate at 4:2:0 buys it back.
The wire carries exactly two chroma modes, fixed at session negotiation — a
chroma change is a reconnect (LYTE-PLAN §2.2). Keep that: mid-stream chroma
switching buys nothing a 2-second restart doesn't, and costs decoder
reconfiguration on every platform.

**Bit depth: 8-bit now, 10-bit as the banding fix when measured.** 10-bit
HEVC 4:4:4 encodes on Ada and decodes in Apple hardware, so the capability
tuple carries it from day one. But 10-bit costs ~25% raw-surface bandwidth and
a second conversion path, and its payoff — banding on smooth gradients
(wallpaper, dark-mode UI washes) — is exactly what the §3 quality ratchet also
fixes by driving static QP toward lossless. Decision: ship Work mode as
`444/8`, add a `444/10` policy escalation **only if** the §7 golden gradients
still band after the ratchet converges. Don't pay for two mitigations before
measuring one.

**RGB→YUV matrix and range — the classic smeared-desktop bug, pinned.** The
protocol carries `(matrix, range, primaries, transfer)` as **explicit,
mandatory session fields** — H.273 code points, no defaults, no inference
from resolution. The encoder writes the same values into the bitstream VUI;
the client asserts VUI == negotiated and surfaces a doctor diagnosis on
mismatch. Policy:

- **Work mode: BT.709 matrix, full range.** Desktop content is born
  full-range RGB; studio-swing quantization throws away 12% of the code space
  and every limited↔full mismatch produces either washed-out gray-on-gray or
  crushed blacks with chroma ghosting around text. Sunshine's
  `encoderCscMode` (bit 0 = full range, bits ≥1 = 601/709/2020 —
  docs/sunshine-v2026.715.205118.md §5) proves both ends of our lineage
  already plumb this; our client's current Rec.601-limited request is a known
  bug to fix independently (LYTE-PLAN §4).
- The conversion matrices are generated per ITU-T H.273 constants exactly as
  Sunshine does (`video_colorspace.cpp` constexpr tables — same doc §5); the
  CUDA `RGBA_to_YUV444` kernels from PR #4965 are the GPL→GPL reference for
  the host's 4:4:4 conversion (HOST-PLAN §7).
- One trap to test explicitly: **full-range 4:4:4 through VideoToolbox must
  round-trip 0 and 255**. The §7 gates include literal black/white/primary
  patches asserted byte-exact after decode, because the failure mode
  (double range expansion in the render layer) is invisible in casual use and
  ruinous for text contrast.

## 3. Rate control: capped-CQ VBR plus the quality ratchet

**CBR is the wrong tool for a damage-driven desktop and we stop using it in
Work mode.** CBR answers "how do I fill a fixed pipe smoothly" — a gaming
assumption where every frame matters equally. A desktop stream is bursty
damage separated by silence; what we actually want is *bounded quality* when
damage flows and *convergence to perfection* when it stops.

**Active-phase rate control (Work): `rc=vbr` + `cq` target + hard cap.**
libavcodec's `hevc_nvenc` exposes exactly this — `-rc vbr -cq N -maxrate M
-bufsize (M/fps)`
([NVIDIA's FFmpeg guide](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/ffmpeg-with-nvidia-gpu/index.html)):
constant-quality encoding with a single-frame VBV cap at the negotiated
bitrate, so a worst-case damage burst (full-screen scroll) degrades exactly
like today's CBR, but a two-line terminal update spends only what two lines
cost. The cap `M` is the congestion sibling's available-bandwidth estimate,
updated by encoder reconfiguration (a supported dynamic-reconfig path in
nvenc), never by stream restart. `qmin` stays (the lesson from H0a slice 2:
without a quality floor-ceiling, nvenc burns the whole budget polishing
static scenes); B-frames stay zero; GOP stays infinite; multipass qres stays.
Play mode keeps the Sunshine-style CBR recipe unchanged — motion smoothness
at a fixed budget is the correct gaming contract, and it's what the client is
tuned against.

**The quality ratchet (Work mode's headline behavior).** Prior art is
mainstream, not exotic: PCoIP's
[build-to-lossless](https://docs.omnissa.com/bundle/Horizon-Remote-Desktop-FeaturesV2603/page/PCoIPBuild-to-LosslessFeature.html)
and Citrix Thinwire's
["fuzzy-first" Build to Lossless](https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/graphics/thinwire/thinwire-selective-encoder/build-to-lossless.html)
both ship exactly this: lossy while moving, sharpen to pixel-perfect when
still. Ours, specified:

- **Trigger.** Damage has been quiet for **T_settle = 250 ms** (tunable;
  long enough to skip mid-typing churn, short enough that the sharpening is
  perceived as instant when you stop scrolling). The idle-floor tick
  machinery from H0a slice 2 is the scheduler — the ratchet is what the
  idle floor *becomes* in the native protocol.
- **Mechanism.** Re-encode the retained last frame as ordinary P-frames at a
  stepped-down QP ladder (e.g. current → 20 → 16 → 12), one step per pass,
  paced by the timing sibling at a fraction of display rate (ratchet frames
  are not latency-critical). Blocks whose reconstruction already matches the
  source at the new QP quantize to zero residual and skip — so successive
  passes naturally concentrate bits on the not-yet-converged regions.
  **No wire semantics change: refinement frames are frames.** The client
  cannot tell and must not need to; frame numbering stays contiguous;
  damage-driven "no frames when static" still holds *after the ratchet
  completes*.
- **Budget.** The ratchet spends only the congestion sibling's reported
  surplus (negotiated cap minus active-stream needs, with their backoff
  signal as a hard pause). It is the lowest-priority sender class: below
  input, audio, and fresh damage frames (the H2 priority order extends by one
  row).
- **Stop conditions.** (a) A new damage event — abandon instantly, the fresh
  frame wins; (b) the QP floor reached — **QP ≈ 10–12 in 4:4:4 full-range is
  the "visually lossless" cap**, not transquant-bypass true lossless: NVENC
  can encode lossless HEVC but the bitrate is enormous, and a visually
  verified floor (§7 gates) is the right product bar; (c) an encoder-side
  cheap check — when a pass's output is ~all-skip (packet size below a small
  threshold), convergence is done regardless of the ladder position. After
  stop: true silence, liveness on the reliable channel (sibling's area).
- **Interaction with idle→active.** The decision of record stands: idle→
  active restarts with an IDR. A ratcheted-to-lossless desktop that stays
  idle for minutes then wakes gets a fresh IDR anyway — the ratchet does not
  create a new resume path.

**Per-frame QP policy.** Beyond the ladder above, no per-frame QP
micromanagement in v1. `init_qpP`/`qmin`/`qmax`/`cq` through libavcodec are
sufficient control surface; if a slice needs per-frame forcing, `constqp`
mode with per-pass reconfigure is the fallback. Anything finer is §4's
territory and shares its verdict.

## 4. Damage-aware encoding: skip blocks win, region QP rejected for v1

Investigated, with the reachability facts:

- **NVENC emphasis maps** (`NV_ENC_QP_MAP_EMPHASIS`) are **H.264-only** per
  the SDK header and docs, and are incompatible with spatial/temporal AQ
  ([NVENC programming guide §8.9](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-video-encoder-api-prog-guide/index.html)).
  Dead on arrival for an HEVC-primary protocol.
- **Per-block delta-QP maps** (`NV_ENC_QP_MAP_DELTA` via
  `NV_ENC_PIC_PARAMS::qpDeltaMap`) exist for HEVC — but **only through the
  raw NVENC SDK**. libavcodec's `hevc_nvenc` consumes neither the qpDeltaMap
  nor FFmpeg's own `AV_FRAME_DATA_REGIONS_OF_INTEREST` side data (ROI side
  data is honored by libx264/x265/qsv/vaapi encoders, not nvenc — a
  [long-standing gap](https://stackoverflow.com/questions/64645704/emphasis-level-map-with-ffmpeg-using-nvenc)).
- **Long-term reference frames**: per-picture LTR marking
  (`ltrMarkFrame`/`ltrUseFrameBitmap`) is likewise raw-SDK-only; libavcodec
  exposes no per-picture LTR control. LTR's value here is loss recovery
  (reference invalidation), which is the resiliency sibling's call — noted as
  an interface: **if they want LTR/RFI, the encode leaf must move to the raw
  NVENC SDK; that decision is theirs to force, not ours.**

**Verdict: rejected for v1, recorded so it isn't re-litigated.** The damage
signal already reaches the encoder the cheap way: static CTUs predict
perfectly from the reference, quantize to zero, and skip — that's *why* the
settled stream costs ~5.5 KB/frame today (HANDOFF, slice 2). A delta-QP map
that says "coast on static regions" duplicates what skip blocks do for free;
"emphasize damaged regions" duplicates what the §3 CQ mode does (damaged
blocks are where the bits already go). The remaining theoretical win —
starving the *first* frame of a burst everywhere except the damage rectangle
— is worth pennies against its costs: leaving libavcodec for the raw SDK
(a second, NVIDIA-only encode leaf), a per-CTU map pipeline, and a tuning
surface we'd carry forever. Revisit only if §7 measurements show damage-region
quality visibly starved during bursts *and* the raw-SDK move is already paid
for by the resiliency sibling's LTR needs.

## 5. Resolution and scaling: pixel-exact is a protocol guarantee

**Work default: pixel-exact mode.** Capture at native panel resolution
(2048×1280 on `pop`), encode 1:1, decode 1:1, and render **decoded pixel →
device pixel with no resampling**. On a Retina client this means the stream
window's backing store is mapped at device-pixel identity, not scaled by the
2× UI factor. Every resampling step — host fractional scaling, client
window-fit scaling — is a text-quality tax that no codec work can refund.

What the protocol carries:

- **Stream dimensions in physical pixels**, always. Plus the **host's UI
  scale factor** (GNOME fractional scaling included) as advisory metadata so
  the client can present sensible default window sizes — but scale never
  changes the meaning of the pixel grid on the wire.
- **A pixel-exact session flag.** When set (Work default), the client renders
  1:1 and scrolls/letterboxes rather than resamples; the UI shows a truthful
  indicator when the user forces fit-to-window and pixel-exactness is lost.
  When unset (Play), the client may scale freely with its best filter.
- **Dynamic resolution as renegotiation, not adaptation.** A resolution
  change (host display reconfigured, or a future host-follows-client-window
  virtual display) is a session-parameter change: new SPS, fresh IDR, one
  clean restart through the transport sibling's renegotiation path. The
  encoder never silently rescales mid-GOP — resolution-adaptive streaming is
  a video-conferencing behavior that destroys text and is explicitly out.
- **Host fractional-scaling advice.** A host desktop at 125%/150% fractional
  scale is already rendering blurry text locally (compositor downsampling);
  the doctor should *name* this ("host is fractionally scaled; text quality
  capped at the source") rather than let Lyte take the blame. Integer scale
  or native is the recommended host configuration for Work.
- **Host-follows-client and virtual displays are H6+ product work.** The
  portal capture path streams the real desktop; creating/resizing virtual
  displays is a different capability with its own consent surface. The
  protocol reserves the resolution-renegotiation message now (it's the same
  message dynamic resolution already needs) so the feature lands without wire
  surgery later.

## 6. Color management: one paragraph of policy

The v1 pipeline is **sRGB end-to-end, honestly tagged**. The host captures
what the compositor gives it (sRGB-ish desktop RGB), converts with BT.709
full-range as §2 pins, and the bitstream VUI says so; the client hands
correctly-tagged buffers to the display system and lets ColorSync map sRGB
into the Mac's P3 panel (that mapping is the OS's job and it is good at it —
what we must not do is *lie in the tags* and ship BT.601-labeled 709 or
limited-labeled full). Wide-gamut host capture (a P3 Linux desktop) and HDR
are **out of scope for v1 and negotiated later**: the capability tuple
already carries `(primaries, transfer)`, so P3/BT.2020/PQ arrive as new
negotiated values plus Moonshine's banked HDR SEI construction
(HOST-PLAN §5), not as a protocol change. Until then the host advertises
sRGB only, and a mismatch is a named doctor line, never a silent tint.

## 7. Verification: "crisp text" as a number, then a gate

Objective measurement, not vibes. The test corpus is synthetic and versioned
in-repo: (a) terminal frames — dense monospaced text, white-on-black and
syntax-highlighted (the saturated-color single-pixel-stroke worst case), at
100%/125%/200% zoom; (b) a 1-px checkerboard and single-pixel color
gratings (chroma torture); (c) smooth 16-step and 256-step gradients (banding
witness); (d) black/white/primary flat patches (range round-trip witness);
(e) one photographic frame (regression guard for Play).

The harness runs the *real pipeline* — RGB source → host conversion + encode
(on `pop`) → decode via VideoToolbox on the client → readback — and compares
**in RGB space after full decode**, because YUV-domain PSNR hides exactly the
chroma and range bugs we care about. Metrics and gates:

- **Text-region PSNR (RGB, per-channel min)** over glyph bounding boxes:
  Work-mode active phase ≥ 40 dB; post-ratchet ≥ 50 dB or byte-identical
  glyph rows. 4:2:0 baseline numbers are recorded alongside to quantify the
  4:4:4 win in every report.
- **SSIM over full frame**: post-ratchet ≥ 0.995 on corpus (a)–(c).
- **Range round-trip**: patches (d) decode byte-exact (0=0, 255=255,
  primaries within ±1 code) — a hard gate, any drift fails the slice.
- **Chroma fidelity**: on corpus (b), per-channel error at grating edges
  ≤ ±2 codes in Work mode — the gate 4:2:0 cannot pass, which is the point.
- **Ratchet behavior**: from damage-stop, converged (all-skip stop condition)
  within ≤ 3 s at LAN surplus; bytes spent during ratchet ≤ the congestion
  sibling's reported surplus at all times; zero frames sent after
  convergence until new damage.
- **Visual goldens**: decoded post-ratchet PNGs of corpus (a) committed and
  diffed per slice; a human looks only when the diff is non-empty.

Acceptance wiring: the H4 (4:4:4 + policy) slice ships only when Work-mode
gates pass end-to-end on the reference pair; any later encoder-recipe change
(preset, QP ladder, conversion kernel, codec addition) must re-run the
harness and may not regress a gate. The harness is also the banding referee
for the §2 8-vs-10-bit decision.

---

## Interfaces owed to siblings (summary)

| From | Interface |
|---|---|
| Congestion/FEC sibling | Available-bandwidth estimate + surplus budget + backoff signal (drives §3 cap and ratchet pacing); their LTR/RFI ambitions decide the raw-NVENC-SDK question (§4) |
| Timing/pacing sibling | Frame-interval pacing for damage frames; low-priority scheduling class for ratchet frames (§3) |
| Transport/session sibling | Capability tuples `(codec, profile, chroma, bitDepth, matrix, range, primaries, transfer, width, height, scaleFactor, pixelExact)`; session-parameter renegotiation with clean IDR restart (§1, §5) |
