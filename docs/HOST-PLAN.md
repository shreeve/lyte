# Lyte Host: Strategic Recommendation (host strategist, 2026-07-20)

> **Supersession notice (2026-07-20, evening).** This document's
> wire-protocol mandate — the byte-exact Sunshine dialect, the golden-packet
> acceptance gates, and the handshake-shaped H0b/H1 ladder — is
> **superseded** by
> [20260720-215100-lyte-udp-decision.md](20260720-215100-lyte-udp-decision.md):
> lyte-host speaks only Lyte-UDP and never implements the GameStream
> dialect. What remains authoritative here: the capture fork (§1–§2), the
> encode path and facade (§3), the codebase-lifting guide (§5, minus the
> dialect-specific items), and the platform risks (§7). §4 and the ladder
> amendments in §6 are kept as historical record — the protocol knowledge in
> them still documents the payload interiors Lyte-UDP reuses (HEVC
> depacketization layout, RS-FEC math, Opus framing) and what the frozen
> client scaffolding speaks until it is deleted.

## TL;DR

**Build the Sunshine-shaped host with Moonshine's internal architecture.** Desktop capture via PipeWire portal, NVENC encode for H0 (not VAAPI — LYTE-PLAN's H0 wording is wrong for the reference host), Vulkan Video as the deliberate end state, and a byte-exact Sunshine-dialect wire from day one because our own client is the first customer and Moonshine proves how easy it is to build a host that *feels* complete but silently never sends a frame to a Sunshine-era client. The H-ladder survives; four amendments below.

---

## 1. The architectural fork: capture the desktop, don't become the desktop

**Recommendation: desktop capture (Sunshine's model), unambiguously — with the compositor model shelved as a labeled future Play option, not a hybrid.**

The reasoning is product-first, then engineering:

- **Product.** Lyte's mission is remote workstation: "stream the real desktop, text fidelity" (DESIGN.md D2, Local·Work cell; LYTE-PLAN §1). Moonshine's own documentation states its model plainly: it is *not* a desktop capture host — it runs each stream in an isolated headless Smithay compositor and launches the app *into* it (moonshine.md §1 "What this program is not", §7.1). That architecture cannot show the user their existing GNOME session, their open terminals, their real clipboard context. moonshine.md §15 already reaches the right verdict: "isolated-compositor mode is a future product option, not H0–H2… orthogonal to 'use my Linux box as a remote workstation.'" I concur and would go further: don't hybridize in v1 at all. A hybrid means maintaining two capture architectures, two input-injection paths (seat events vs uinput/libei — moonshine.md §8 is explicit that seat injection only works because the app lives inside Moonshine's compositor), and two focus models, for a secondary use case.

- **Engineering cost in Swift.** Smithay has no Swift analogue. Moonshine's compositor module is ~8k+ lines of Rust (moonshine.md §4) *on top of* a personal fork of Smithay (branch `master-moonshine`), plus a 2-crate Vulkan WSI layer with raw C-ABI interception, `wl_proxy_set_queue` games, and Gamescope-protocol emulation (§7.4). The Swift equivalents would be: bind wlroots or libweston (large C surfaces, and you're still writing a compositor on top), or drive `libwayland-server` directly (you're writing Smithay yourself). Any of these is a multi-quarter project *before the first pixel reaches the wire* — and it delivers the wrong product. By contrast, the desktop-capture path is "gluing proven components" exactly as LYTE-PLAN §2.4 predicted: PipeWire client API + one encoder + the protocol stack we already understand from the client side.

- **The staged answer.** If a "Play sandbox" mode (stream a game while the desktop stays usable — Moonshine's genuine headline feature) ever earns priority, it arrives as a *new capture backend behind the same facade*, and by then wlroots-in-Swift or even shelling out to a headless Gamescope are evaluable options. Nothing in the desktop-capture architecture forecloses it. Do not spend a line of code on it before H6.

What we *do* take from Moonshine's architecture is everything below the capture layer: the typed session state machine, structured shutdown, StartB gating, resume semantics (§12). Moonshine's existence is itself the most valuable data point: an independent, non-C++, ~26k-line reimplementation of the full GameStream host stack by one person (§1) — direct evidence that LYTE-PLAN's "55–65% of total lift" estimate (§2.4) is realistic for a Swift host.

## 2. Capture path for H0: PipeWire portal, with the KMS traps documented but deferred

**Recommendation: xdg-desktop-portal ScreenCast → PipeWire stream, with restore-token persistence, DMA-BUF negotiation, and damage metadata requested from day one.**

Why portal over the alternatives, specifically on the reference host:

- **It's Sunshine's own newest path and the only genuinely event-driven one.** sunshine-v2026.715.205118.md §10 describes the PipeWire backend as "the modern path": variable-rate, requests `SPA_META_VideoDamage`, drops redundant frames, waits on a condition variable — "genuinely event-driven." That property is the foundation of Lyte's biggest planned divergence from Sunshine: true idle silence (sunshine-v2026.715.205118.md §15.1), which the fps/2 CBR re-encode floor (§7 "idle floor") makes impossible upstream. KMS, by contrast, is **pure polling** — "sleep-to-frame-interval, re-read plane fb — no damage detection" (§10). Choosing KMS for H0 would architecturally lock out the Work-mode differentiator.
- **KMS on NVIDIA is a trap field.** sunshine-v2026.715.205118.md §10 catalogs them: CAP_SYS_ADMIN raised around `drmModeGetFB2`, NVIDIA ENOSYS forcing a dumb-buffer fallback, the DRM-master trap that can break the running compositor, Q16.16 cursor-plane properties, and the Wayland connector-correlation hack. Also the double-cursor problem from the case study (DESIGN.md, case study item 4) is a KMS-capture artifact. All of this is knowledge worth *having* (the doctor should know the traps), none of it is worth *paying for* in a spike.
- **Portal solves the unattended-restart problem Sunshine already solved for us**: `persist_mode=UNTIL_REVOKED` + restore token persisted to disk (sunshine-v2026.715.205118.md §10) — copy that verbatim. Caveat worth carrying: the caller must drop caps and be dumpable or the portal refuses (same section).
- **Reference-host specifics.** NVIDIA + Pop!_OS: sunshine-v2026.715.205118.md §10 notes PipeWire DMA-BUF is used "for vaapi/vulkan or pure-NVIDIA"; a pure-NVIDIA desktop qualifies, so zero-copy DMA-BUF frames into a CUDA/Vulkan encode context are available. (The hybrid Intel+NVIDIA no-dmabuf-into-CUDA rule is the doctor-signature to keep for laptops like "ice", not a concern for the reference host.)
- **4:4:4 is orthogonal to capture.** Every capture path delivers full-resolution RGB (BGRx/RGBA DMA-BUFs). Chroma fidelity is won or lost at the RGB→YUV conversion and encode stage, not at capture. Portal costs nothing on the 4:4:4 ambition.

One honest risk flag: Pop!_OS is migrating to COSMIC, whose portal/ScreenCast implementation is younger than GNOME's Mutter. Mitigation in §7 below. KMS remains the documented fallback backend for a later milestone (Sunshine's priority order in sunshine-v2026.715.205118.md §10 exists for a reason), but it is not H0.

## 3. Encode path: NVENC for H0, one Swift facade forever, Vulkan Video as the earned end state

**First, the conflict that must be called out: LYTE-PLAN §6 H0 says "PipeWire capture → VAAPI HEVC," and §6's intro says owning the host pays off via "4:4:4 via VAAPI." Both are wrong for the reference host, per sunshine-v2026.715.205118.md.**

- The reference host is NVIDIA, and sunshine-v2026.715.205118.md §10 documents Sunshine's hybrid rule: "**vaapi skips NVIDIA cards, cuda skips non-NVIDIA**." There is no usable VAAPI *encode* on an NVIDIA GPU. H0 as written cannot produce pixels on the target machine.
- Even where VAAPI exists, sunshine-v2026.715.205118.md §7's encoder table shows VAAPI's 4:4:4 slots are **NONE/NONE** upstream, and §8 shows the hardware reality is Intel-only (AMD/radeonsi has no 444 encode). Linux 4:4:4 that actually shipped in Sunshine's master (PR #4965) is the **NVENC/CUDA** path (sunshine-v2026.715.205118.md §1, §8). For the reference host, NVENC is both the only encoder and the 4:4:4-capable one. The VAAPI-444 recipe in sunshine-v2026.715.205118.md §8 stays valuable — for future Intel hosts and as a possible upstream contribution — but it is not on Lyte's critical path.

**H0 recommendation: FFmpeg's libavcodec as the single C encode leaf, driving `hevc_nvenc` with CUDA frames.** Rationale:

- It is exactly one C boundary, consistent with LYTE-PLAN §4's "C only at hardware/OS leaves (VAAPI/NVENC/PipeWire bindings)" commitment — and it makes VAAPI, QSV, and software x264/x265 fallbacks available later behind the same leaf for free.
- Sunshine's entire hard-won encoder configuration translates line-for-line, because Sunshine drives Linux NVENC through FFmpeg too (sunshine-v2026.715.205118.md §7): true CBR with `rc_max_rate = rc_min_rate`, **single-frame VBV** (`bitrate/framerate`), filler off, `gop_size = INT_MAX`, zero B-frames, `max_num_reorder_frames = 0` (the invariant the whole protocol rests on — §7), preset P1 + ultra-low-latency + zeroReorderDelay, one frame in flight. These are the settings our client is already tuned against.
- The direct NVENC SDK is cleaner in isolation but NVIDIA-only and still leaves RGB→YUV conversion to us; raw Vulkan Video from Swift is the most work of the three.

**End state: Vulkan Video behind the same facade — an evaluation gate after H2, not a bet placed at H0.** Moonshine proves the important part: Vulkan Video encode works today on Linux for H.264/HEVC/AV1 including 4:4:4 and 10-bit, CBR with one-frame VBV, IDR on demand, DMA-BUF import with an fd cache for NVIDIA's per-frame fd churn (moonshine.md §7.5). It is the only route that collapses Sunshine's per-vendor encoder wrangling — ~37 of the 95 config keys are per-vendor tuning (sunshine-v2026.715.205118.md §12) — into one API. But it's raw Vulkan C API from Swift (Moonshine leans on `pixelforge` + `ash`, neither of which we can use), and moonshine.md §7.5 notes AV1 is still driver-fragile on NVIDIA. So: build the Swift `Encode/` facade in H0 with FFmpeg behind it, keep the facade's contract encoder-agnostic (frames in as DMA-BUF or CUDA surfaces, Annex-B out, IDR/bitrate/chroma as messages), and swap in a Vulkan Video backend when it earns its way — Moonshine's DMA-BUF import cache (TTL 2 s, fd+params key, dup-before-import — §7.5) ports directly when that day comes.

Carry Sunshine's **empirical probe discipline** regardless of backend: real test encodes at startup, results populate the advertised SCM bits, failures become named doctor diagnoses (sunshine-v2026.715.205118.md §7 "Probing", §15.6). The hybrid-GPU silent-fallback case study (DESIGN.md) is the argument: capability advertisement must be proven, never assumed.

## 4. Protocol serving order: build to the byte-exact checklist, in client-unblocking order

*(Superseded by
[20260720-215100-lyte-udp-decision.md](20260720-215100-lyte-udp-decision.md) —
lyte-host never implements this dialect. Retained as historical record and
as the reference for the payload interiors that carry into Lyte-UDP: the
video packetization layout in item 6 and the audio framing/FEC constants in
item 7 describe the interior formats the new envelope wraps. Items 1–5 —
serverinfo, pairing, RTSP, ping demux, control-v2 — are dead for the host.)*

Moonshine is the cautionary tale here, and it's worth stating why: it is protocol-complete for stock Moonlight yet **our shipping client cannot stream from it at all** (moonshine.md §11, "Verdict: No"). The failure is silent — no error, just no media — because Moonshine omits `X-SS-Ping-Payload` and only learns the client address from a literal ASCII `"PING"`, which our client never sends. Media gating on the ping handshake is the single most dangerous silent-failure mode in the whole stack: **everything else can be perfect and zero packets flow.** That reframes H0/H1 sequencing: the wire features our client *requires* are not H1 polish, they're prerequisites for H0's acceptance test.

Implementation order, each step unblocking the next client behavior:

1. **`/serverinfo` identity**: `appversion = "7.1.431.-1"` (the negative fourth quad is the "I am Sunshine" marker — sunshine-v2026.715.205118.md §4), `GfeVersion`, `MaxLumaPixelsHEVC = 1869449984`, and **SCM bits taken from sunshine-v2026.715.205118.md §4, never from Moonshine** — Moonshine's 4:4:4 SCM bit values are wrong (`0x00040000`… instead of `0x0008`/`0x1000`/`0x2000` — moonshine.md §11, §13.4). Get this wrong and the client silently never offers 4:4:4: no error, just a capability that never appears. XML errors ride HTTP 200 (moonshine.md §12.13).
2. **Pairing, byte-exact**: SHA256(salt‖PIN)→AES-128-ECB five-phase dance, per-cert X509 stores, dateless leaf pinning (sunshine-v2026.715.205118.md §4). Golden transcripts captured from client↔Sunshine sessions are the test rig (PLAN.md §7 already prescribes this pattern).
3. **RTSP with the Sunshine extensions our client keys on**: honor `corever≥1` → `rtspenc://` with the 24-byte GCM framing and `'CR'`/`'HR'` IV suffixes (sunshine-v2026.715.205118.md §5) — our client *tolerates* plaintext but Lyte's encrypt-always policy (LYTE-PLAN §4, §8) means we ship encrypted RTSP from the start, not later. SETUP must return **`X-SS-Ping-Payload`** (audio/video) and `X-SS-Connect-Data` (control). DESCRIBE needs the sentinels (`sprop-parameter-sets=AAAAAU`, `a=rtpmap:98 AV1/90000`) and the GFE LFE-rotation quirk in surround params (sunshine-v2026.715.205118.md §5; independently confirmed by Moonshine — moonshine.md §12.8). One TCP connection per command; ≤2048 bytes.
4. **Ping demux**: accept `SS_PING` matched by the 16-char payload, learn address *and port* from it (NAT-safe), gate all sending on it (sunshine-v2026.715.205118.md §6). Also accept legacy ASCII `"PING"` — it's a few lines and makes stock Moonlight a free second test client.
5. **Control-v2 GCM**: envelope `0x0001` with tag-before-ciphertext, seq-LE IV + `'HC'`/`'CC'` suffixes, termination `0x80030023` BE; StartB (`0x0307`) gates media start (Moonshine's gating design is the one to copy — moonshine.md §6.2, §12.3).
6. **Video packetization, field-exact**: 8-byte frame header; `streamPacketIndex = seq<<8`; `multiFecFlags = 0x10`; `fecInfo = (shardIdx<<12)|(dataShards<<22)|(fec%<<4)`; ≤4 FEC blocks per frame with the silent-FEC-disable overflow rule; RTP header byte `0x90`, PT/SSRC 0, 90 kHz clock (sunshine-v2026.715.205118.md §6; Moonshine's `packetizer.rs` is a clean-room confirmation of the same layout — moonshine.md §6.3). Video GCM prefix `{iv[12], frameNumber, tag}` with `iv[11]='V'`.
7. **Audio**: Opus CBR (`RESTRICTED_LOWDELAY`), 4+2 RS-FEC with the parity matrix **byte-exact `77 40 38 0e c7 a7 0d 6c`** (sunshine-v2026.715.205118.md §6 — both hosts independently confirm this is non-negotiable; moonshine.md §6.4, §12.7), CBC IV = BE(rikeyid+seq), PT 97/127, FEC timestamp 0. **Follow Sunshine's timestamp semantics (packetDuration-ms units), not Moonshine's wall-clock `/11` hack** — moonshine.md §6.4 flags this divergence as historically breaking picky clients; our client is tuned against Sunshine's units.

This is sunshine-v2026.715.205118.md §15's "byte-exact compatibility checklist" reordered into a build sequence. Every item above should be a named H0/H1 acceptance check with a golden-packet test, because Moonshine demonstrates that each can be individually wrong while the host still "works" against some client.

## 5. What to lift from each codebase

**From Moonshine (BSD-2-Clause — code can be ported directly into GPLv3 Lyte, per moonshine.md §1; practically: translate Rust→Swift line-by-line where useful):**

- The **typed session state machine** (`Initialized → Launched → Active`) as a Swift enum-driven actor (§10, §12.1) and **structured shutdown reasons** — every subsystem holds a typed trigger; any death tears the session down with a named cause (§12.2). Maps directly onto Swift structured concurrency.
- **StartB gating** (build pipelines early, block encode/send on a notify — §12.3) and **resume semantics**: key rotation via a watch-channel equivalent, reset frame/sequence counters + force IDR on resume to avoid false "100% frame loss" (§12.4, §12.12).
- **DMA-BUF import cache** design: keyed fd+params, 2 s TTL, dup-before-import, ObjectId-keyed indices for NVIDIA fd churn (§7.5, §7.10) — for the eventual Vulkan backend.
- **HDR SEI construction** (`hdr_sei.rs`): MDCV/CLLI payload types 137/144, RGB vs GBR ordering per codec, key-frame-only injection (§7.5) — for M7/H4 HDR.
- The **audio FEC parity-matrix override** implementation and comment trail (§9.3), the **LFE-rotation** SDP quirk (§6.1), **lenient TLS verifier + fingerprint pinning** in a modern TLS stack (§5), **embedded mDNS** with no avahi dependency (§12.10 — directly serves H6's copy-one-binary goal), and **empirical HDR gating** (§12.11).
- The packetizer and Opus/CBC/FEC packetization paths as a *second reference* — safe-language confirmation of sunshine-v2026.715.205118.md's C++ readings (§6.3–6.4).

**From Sunshine (GPLv3 — same license as us, so porting is unrestricted; realistically C++→Swift means patterns + constants):**

- The **§15 byte-exact checklist** and every constant in §16 — this is the compatibility contract.
- The **empirical encoder probe** architecture: real test encodes → advertised SCM bits → doctor diagnoses (§7, §15.6).
- **Platform trap knowledge** (§10, §15.11): portal restore token + caps-dropped-and-dumpable requirement; DRM-master ioctl oracle; hybrid-GPU exclusion rules (vaapi↔NVIDIA, Intel-dmabuf↛CUDA); cursor-plane Q16.16; the udev uinput rule; x265 Info-SEI quirk; VideoToolbox H.264 ref-frames bug (#5013) for H6.
- **cbs/VUI discipline** (§9): validate SPS for the VUI Moonlight needs; `max_num_reorder_frames=0` as the invariant; H.273 colorspace matrices.
- The **dlopen-leaf pattern** (X/avahi/GBM never linked — §10, §15.6) for single-binary distribution, and the **VAAPI-444 recipe** (§8) banked for future Intel hosts.
- Encoder settings wholesale (§7): CBR + single-frame VBV, infinite GOP, zero B-frames, per-codec min-QP, one-frame-in-flight.

**Deliberately not lifted:** Moonshine's compositor/WSI layer and seat-based input (§7, §8 — wrong architecture for desktop capture); its SCM 444 bits, missing ping-payload, plaintext-only RTSP, wall-clock audio timestamps (§13); Sunshine's fps/2 idle floor (§7 — a choice, not a protocol requirement), 1-Gbps-assumed pacing (§14.5), decorative loss stats (§14.2), web-UI-mandatory pairing (§12), and the 95-key config surface.

## 6. H-ladder revisions

*(Superseded: the H-ladder was reshaped again by the Lyte-UDP decision —
the current ladder of record is LYTE-PLAN §6 as amended per
[20260720-215100-lyte-udp-decision.md](20260720-215100-lyte-udp-decision.md).
The capture/encode/input substance of these amendments survives in it; the
dialect-shaped acceptance criteria do not.)*

The ladder's shape survives contact with the evidence — strictly serial, verified live against the shipping client, capture-the-desktop-first. Four concrete amendments:

- **H0 (amended stack + amended scope).** Replace "PipeWire capture → VAAPI HEVC" with "**PipeWire portal capture → NVENC HEVC (FFmpeg/CUDA leaf) → RTP+FEC**" — the written stack cannot run on the reference host (sunshine-v2026.715.205118.md §7/§10; see §3 above). Expand "hardcoded everything" to *include* a minimal SETUP/ping path: serverinfo identity, one canned RTSP exchange with `X-SS-Ping-Payload`, and SS_PING-gated sending. Without it the shipping client won't start audio and may never reveal its media address (moonshine.md §11) — a "spike" that bypasses ping gating validates nothing about the real client path. Acceptance stays: the client window shows the host's live desktop.
- **H1 (new acceptance criteria).** Adopt moonshine.md §15's proposal verbatim as gating checks: (a) `rtspenc://` end-to-end, (b) SS_PING with payload matching, (c) SCM bits byte-identical to sunshine-v2026.715.205118.md §4, (d) golden-transcript pairing tests, (e) audio timestamps in Sunshine's units. Moonshine is the existence proof that a host passes stock-Moonlight testing while failing all five.
- **H2 (two substitutions + one addition).** Input: uinput/inputtino pattern (with the udev rule from sunshine-v2026.715.205118.md §16), *not* Moonshine's seat injection (moonshine.md §8 "Implications"); evaluate the portal RemoteDesktop input path Sunshine already combines with ScreenCast (sunshine-v2026.715.205118.md §10) — it may give Wayland-native injection with zero extra permissions since we're already in that portal session. Audio: PipeWire monitor capture of the real desktop, *not* an embedded PulseAudio server (moonshine.md §9.4 reaches the same conclusion); the audio *send* design — priority scheduling with a measurable inter-send-jitter acceptance criterion, negotiated-bitrate video pacing, DSCP/SO_PRIORITY parity, capture-clock timestamps, and the recorded FEC-class rejections — is specified in docs/20260720-145840-audio-continuity.md §4. **Addition — pull idle silence into H2's acceptance**: "static desktop ≤ ~1 fps keepalive, measured" — the capture path was chosen for damage events (§2 above), Moonshine proves clients tolerate ≤1 fps gaps (moonshine.md §7.2, §12.5), and this is the Work-mode differentiator; don't defer it to H4 where it competes with 4:4:4.
- **H4 (re-scoped).** 4:4:4 lands on **NVENC first** (the path Sunshine's PR #4965 proved; sunshine-v2026.715.205118.md §8), with the RGB→YUV444 conversion as the real work item; VAAPI-444 moves to a backlog item for Intel hosts (and a possible upstream contribution). Add loss-driven adaptation here explicitly: the client already reports loss every ~50 ms and both incumbents ignore it (sunshine-v2026.715.205118.md §14.2, moonshine.md §13.9) — using it is a zero-wire-change differentiator. Pace to the negotiated bitrate, not 80% of an assumed gigabit (sunshine-v2026.715.205118.md §14.5).

H3, H5, H6 stand as written. Moonshine offers nothing for H3/H5 (no clipboard, no feature channel — moonshine.md §15) which reconfirms those milestones as Lyte's moat; its embedded-mDNS/rustls/one-binary posture validates H6's distribution story, with systemd kept optional (moonshine.md §13.11).

## 7. Risks specific to this path

| Risk | Mitigation |
|---|---|
| **COSMIC portal immaturity** — Pop!_OS is migrating from GNOME to COSMIC; the portal ScreenCast/RemoteDesktop implementation there is young, and damage metadata (`SPA_META_VideoDamage`) may be absent or unreliable | Pin H0 to the current GNOME session on the reference host; state supported environments explicitly (LYTE-PLAN §11 already commits to this). If damage metadata is missing, degrade to a Sunshine-style re-encode floor — idle silence becomes environment-dependent, not broken. Keep KMS as the documented fallback backend with sunshine-v2026.715.205118.md §10's traps as the implementation guide. |
| **Portal consent + restore-token fragility** (dialog on first run; token invalidation across compositor updates) | Persist the restore token (sunshine-v2026.715.205118.md §10 pattern); make token-expiry a named doctor diagnosis with a one-click re-consent flow in the host UI, not a silent capture failure. |
| **NVENC-through-FFmpeg from Swift** — C interop volume, and the RGB→YUV conversion (especially YUV444 for H4) needs CUDA or Vulkan compute we must write | The client already proved the Swift+C-leaf pattern (LYTE-PLAN §11). Keep libavcodec as the single leaf; for 4:4:4, Sunshine's CUDA `RGBA_to_YUV444` kernels (sunshine-v2026.715.205118.md §8) are portable reference (GPL→GPL). |
| **Ping/gating silent failures** — the class of bug where everything is "correct" and nothing flows (Moonshine's exact failure against our client) | The §4 checklist as automated golden-packet acceptance tests; additionally a host-side telemetry line ("waiting for SS_PING", "peer learned: ip:port") surfaced to the doctor so silence is never mysterious. |
| **Vulkan Video end-state slips** (driver maturity, raw-C-API effort from Swift; AV1 fragile — moonshine.md §7.5) | It's an evaluation gate after H2, not a dependency. The encode facade contract keeps the FFmpeg backend shippable indefinitely; nothing in H0–H6 requires Vulkan Video. |
| **Solo-maintainer scope: the compositor temptation** — Moonshine's architecture is genuinely elegant and the pull to hybridize early will recur | The fork decision in §1 is the answer of record: capture backends behind one facade, isolated-compositor mode is post-H6 product work. LYTE-PLAN §11's "strictly serial H-ladder" rule already covers this. |

**Documented disagreements, resolved:** LYTE-PLAN §6's "VAAPI HEVC" H0 stack and "4:4:4 via VAAPI" framing vs sunshine-v2026.715.205118.md §7/§8/§10 — resolved in sunshine-v2026.715.205118.md's favor (NVENC on the reference host; VAAPI-444 is upstream-empty and Intel-only hardware). Moonshine's SCM 444 bits vs sunshine-v2026.715.205118.md §4 — Sunshine's values are authoritative (moonshine.md §13.4 agrees). Audio RTP timestamp units (Moonshine wall-clock vs Sunshine packetDuration-ms) — follow Sunshine; our client is its test oracle. Moonshine's 1 s static-skip vs Sunshine's fps/2 floor — both docs agree clients tolerate frame gaps, which jointly validate LYTE-PLAN's idle-silence thesis (sunshine-v2026.715.205118.md §15.1, moonshine.md §12.5).

---

## If you start H0 tomorrow, do exactly this

*(Historical — written for the Sunshine-dialect plan. The capture/encode
half of this recipe was executed as H0a slices 1–2; the handshake/RTP half
is superseded by the Lyte-UDP decision and will never be built.)*

Stand up a Swift executable on the host that: opens an xdg-desktop-portal ScreenCast session (RemoteDesktop+ScreenCast combined, `persist_mode=UNTIL_REVOKED`, restore token persisted) and consumes the PipeWire stream with DMA-BUF negotiation and `SPA_META_VideoDamage` requested; feeds frames through a Swift `Encode` facade whose only backend is libavcodec `hevc_nvenc` configured with Sunshine's exact low-latency recipe (CBR, single-frame VBV, GOP INT_MAX, zero B-frames, reorder 0, P1/ULL, one frame in flight — sunshine-v2026.715.205118.md §7/§16); packetizes per sunshine-v2026.715.205118.md §6 field-for-field (frame header, `seq<<8`, `fecInfo` packing, ≤4 FEC blocks, RTP `0x90`); serves a hardcoded but *real* handshake — serverinfo with `"7.1.431.-1"` and correct SCM bits, one canned RTSP exchange returning `X-SS-Ping-Payload`, and send gating on a matched SS_PING (accepting legacy `"PING"` too) — and declares victory when the unmodified shipping Lyte client, pointed at the host, renders the live desktop. Port Moonshine's session state machine and StartB gating as the process skeleton while you're in there (it's BSD; translate freely), write the golden-packet tests for the ping/FEC/SCM bytes as you implement each, and leave VAAPI, Vulkan Video, KMS, and every compositor thought firmly on the shelf.

---

## Review amendments (adopted 2026-07-20)

*(Partially superseded: the "H0b — honest handshake" milestone below is
void — there is no GameStream handshake to make honest. Everything else
stands: the H0a scope, the honesty corrections, the product fixes (portal
input primary, named environments, login-blackout limitation), the
M5.5–M7 freeze, and the idle-tolerance verification — the last is now a
default Lyte-UDP behavior rather than a compat obligation.)*

Three independent reviews — pragmatism, technical correctness, and product/POLS — all returned **adopt with changes**; none called for a rethink. The changes below are adopted and folded into LYTE-PLAN's H-ladder.

- **H0 splits in two.**
  - **H0a — "first pixels" spike**: portal/PipeWire capture → NVENC HEVC (the FFmpeg leaf) → RTP+FEC to a *debug-mode* client — client-side gating relaxed for the spike so pixels can flow before the handshake is honest.
  - **H0b — "honest handshake"**: serverinfo identity, canned RTSP with the Session header and `X-SS-Ping-Payload`, SS_PING-gated sending, **and a minimal ENet control-v2 host**. The technical review confirmed the shipping client hard-requires control-v2 and fails the session without it — it cannot be deferred to H1 as §6 above implied.
  - Realistic combined estimate: **4–8 weeks**, not a weekend spike.
- **Honesty corrections.**
  - The "one C leaf" framing (§3) is really **3–4 C boundaries**: PipeWire, D-Bus/portal, libavcodec, and possibly CUDA kernels for RGB→YUV. Acceptable — the client proved the pattern — but it must be priced as such.
  - The 4:4:4 urgency argument is weakened: Sunshine master already serves 4:4:4 on the reference host if built from source. The host's true moat is the **feature channel** (clipboard, files, printing) and roadmap ownership, not a chroma race.
  - Two items in the "adopt moonshine.md §15 verbatim" H1 list (§6) were misattributed; soften to "adopt the checklist *as corrected by review*."
- **Product fixes adopted.**
  - Document the **reboot/login-screen blackout**: portal capture requires a logged-in session. This is a stated limitation — and a doctor diagnosis — until a KMS/login-manager story exists.
  - Prefer **portal RemoteDesktop input injection over uinput as primary** (kills the udev-rule-vs-copy-one-file contradiction); uinput becomes the fallback.
  - Name supported host environments explicitly: **GNOME/Mutter on the reference host first**; non-NVIDIA and COSMIC are explicitly unsupported at H0–H2, failing loudly rather than silently.
- **Solo-maintainer guard.** Client track M5.5–M7 is frozen during H0–H2 except critical fixes.
- **Verified (2026-07-20): the shipping client tolerates ≤1 fps idle video** — its only video watchdogs are startup-only (10s to first traffic, 10s to first complete frame); a live 45s full video blackout mid-stream (`LYTE_GAP_SIM` hook) survived with clean IDR recovery. Idle silence stands as an H2 acceptance gate. Host obligations: send an IDR immediately at stream start (first complete frame within 10s), and answer IDR requests (0x0302) promptly.
