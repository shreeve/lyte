# sunshine — Host & Platform Analysis

Deep technical analysis of `sunshine-v2026.715.205118/` (master @ `9d2409f`, the newest tree containing Linux YUV 4:4:4 from PR #4965), the GPLv3 C++ host that serves the Moonlight protocol. Goal: understand the host side of the wire — capture, encode, packetize, serve, inject — well enough to design a **better host** (the Lyte host, in Swift).

**Related:** [`moonlight-common-c.md`](moonlight-common-c.md) (client protocol library — the other end of every wire format here), [`moonlight-macos.md`](moonlight-macos.md) (macOS client)

---

## 1. Scope & Role

**What this program is:** the complete host: HTTPS pairing + GameStream API, RTSP session server, display capture, hardware encode, RTP+FEC send, Opus audio send, encrypted input receive/injection, app launching, web config UI, tray icon, mDNS advertisement.

**Version notes:** this tree is newer than any stable release — it includes Linux NVENC/CUDA 4:4:4 (PR #4965), a Vulkan encoder, PipeWire/portal/KWin capture backends, and a Qualcomm MediaFoundation encoder. Stable v2026.516 has none of the 4:4:4 work.

**Checkout notes:** submodules (moonlight-common-c, Simple-Web-Server, inputtino, tray, nanors…) are **not** checked out in our clone — it is reference-only, not buildable. Constants sourced from moonlight-common-c are marked `[MCC]` (cross-checked against `moonlight-common-c.md`).

---

## 2. Architecture Overview

```
main() ── mail::man (global pub/sub mailbox: named events + queues)
  ├── nvhttp thread ×2      TCP 47989 (HTTP) + 47984 (HTTPS): pair, serverinfo, launch
  ├── confighttp thread     TCP 47990: web UI (PIN entry, apps, config, creds)
  ├── rtsp thread           TCP 48010: OPTIONS/DESCRIBE/SETUP/ANNOUNCE/PLAY
  ├── broadcast_ctx (global, refcounted; alive while ≥1 session)
  │     ├── recv_thread     UDP 47998+48000 recv: ping demux → session endpoints
  │     ├── video_thread    mail::video_packets → packetize → FEC → encrypt → send
  │     ├── audio_thread    mail::audio_packets → RTP → CBC → 4+2 FEC → send
  │     └── control_thread  ENet host UDP 47999: input, IDR/RFI, loss stats, rumble
  ├── per-session videoThread   capture → convert → encode → mail::video_packets
  ├── per-session audioThread   capture → Opus → mail::audio_packets
  └── task_pool (1 worker)      input batching, key repeat, delayed tasks
```

The **mailbox** (`globals.cpp`, `mail::*`) is the load-bearing idiom: capture, encode, stream, and input never call each other — they raise named events (`mail::idr`, `mail::switch_display`, `mail::hdr`, `mail::gamepad_feedback`) and push to named queues. Capture/encode is per-session; packetization/FEC/encryption/socket send is centralized on two broadcast threads, demuxed by `packet->channel_data` (a raw `session_t*`).

**Multi-client is real**: ENet host accepts 128 peers, sessions are independent (own keys, sequence numbers, endpoints), and the sync-capture path can feed several encoders from one capture loop. The single-app constraint comes from `proc` (one launched app, ever), not the stream layer.

---

## 3. Port Map & Network Policy

Base port `port` = **47989**; everything is base + fixed offset (`net::map_port`, network.cpp:224):

| Offset | Default | Proto | Role | Defined |
|--------|---------|-------|------|---------|
| −5 | 47984 | TCP | HTTPS GameStream (client-cert) | nvhttp.h:45 |
| 0 | 47989 | TCP | HTTP GameStream (pairing, unpaired serverinfo) | nvhttp.h:40 |
| +1 | 47990 | TCP | Web config UI (HTTPS, Basic auth) | confighttp.h:26 |
| +9 | 47998 | UDP | Video RTP | stream.h:19 |
| +10 | 47999 | UDP | Control (ENet) | stream.h:20 |
| +11 | 48000 | UDP | Audio RTP | stream.h:21 |
| +21 | 48010 | TCP | RTSP | rtsp.h:15 |

- `address_family` default **ipv4**; IPv6 is opt-in (config.cpp:877).
- LAN classification (network.cpp:23–49) includes RFC1918, link-local, ULA, **and CGNAT 100.64/10 — Tailscale counts as LAN**.
- Encryption policy per address: LAN default **NEVER (0)**, WAN default OPPORTUNISTIC (1), MANDATORY (2) available (config.cpp:814). (Lyte's locked decision — encrypt always — is stricter than upstream's default.)
- QoS: DSCP 40 video / 48 audio via IP_TOS + `SO_PRIORITY` 5/6 (linux/misc.cpp:1026); UDP GSO (`UDP_SEGMENT`, 64 KB / ≤64 segs) with `sendmmsg` fallback; source-address pinning via IP_PKTINFO.
- UPnP (optional flag): maps all six externally-relevant ports 1:1, lease 3600 s refreshed every 120 s; web UI mapped only if `origin_web_ui_allowed = wan`.

---

## 4. Identity, TLS & Pairing

### Certificate identity
- One self-signed cert serves nvhttp HTTPS **and** the web UI: RSA-2048, X.509v3, SHA-256, **20-year validity**, random 159-bit serial (Firefox reused-serial workaround), stored `credentials/cakey.pem` + `cacert.pem` (crypto.cpp:472–514).
- Client-cert verification trick: TLS verify callback **always returns 1** so the handshake completes; real pinning happens post-handshake against the stored client-cert chain, and failures get a proper 401 XML instead of a TLS alert (nvhttp.cpp:83–86, 1291–1357).
- Client-cert handling to replicate exactly: **one X509_STORE per client cert** (a single store only verifies one self-signed cert), `X509_V_FLAG_PARTIAL_CHAIN`, and **expired/not-yet-valid client certs accepted** (embedded devices with dead clocks; matches GFE) (crypto.cpp:38–93). Net effect: *pin the exact leaf, ignore validity dates*.

### Pairing state machine (5 phases, keyed by client `uniqueid`)
All parameters arrive as hex query params; **pairing works over plain HTTP 47989** — security derives entirely from the PIN, not TLS:

| Phase | Crypto |
|-------|--------|
| `getservercert` (salt, clientcert) | `key = SHA256(salt ‖ PIN)[0..15]` → AES-128. **HTTP response parked** until the user enters the PIN (web UI `POST /api/pin` or stdin with `-0` flag) — no timeout on the parked response |
| `clientchallenge` | AES-128-**ECB** (no padding) decrypt; reply = ECB(SHA256(challenge ‖ server-cert-sig ‖ serversecret) ‖ serverchallenge) |
| `serverchallengeresp` | ECB-decrypt client hash; reply `pairingsecret` = serversecret ‖ RSA-SHA256 signature |
| `clientpairingsecret` | verify SHA256(serverchallenge ‖ client-cert-sig ‖ secret) == clienthash AND RSA-verify sig. Mismatch → `paired=0` **with HTTP 200**. Success → persist client {name, PEM, uuid, enabled} |
| `pairchallenge` (HTTPS) | unconditional `paired=1` — the TLS client-cert check *is* the verification |

- Out-of-order phase → 400 + session deleted (full re-pair). PIN must be exactly 4 numeric digits.
- Quirk: PIN entry answers `std::begin(map_id_sess)` — two simultaneous pairing attempts race on an unordered_map (nvhttp.cpp:799).
- State file `sunshine_state.json`: host uuid + `named_devices[] {name, cert, uuid, enabled}`.
- Newly-paired certs activate lazily — pushed into a queue drained inside the *next* TLS handshake's verify callback.

### /serverinfo essentials
- `appversion` = `"7.1.431.-1"` — the **negative 4th quad is the "I am Sunshine" marker** clients test for (`IS_SUNSHINE()` in `[MCC]`). Must be preserved by any compatible host.
- `ServerCodecModeSupport` bits (nvhttp.cpp:827–858): `0x0001` H264 (always), `0x0008` H264_HIGH8_444, `0x0100` HEVC, `0x0200` HEVC_MAIN10, `0x1000`/`0x2000` HEVC_REXT 8/10-bit 444, `0x10000`/`0x20000` AV1 Main 8/10, `0x40000`/`0x80000` AV1 High 444 — populated from live encoder probe results, not static config.
- `MaxLumaPixelsHEVC = 1869449984` (GFE magic ≈ 4096×2160×2); `PairStatus` over HTTPS = 1 by definition (TLS-verified ⇒ paired); `LocalIP = 127.0.0.1` when the request arrived over native IPv6 (GS-IPv6-Forwarder emulation).

### /launch & /resume
Required: `rikey` (16-byte AES-128 session key for *everything*), `rikeyid` (→ 16-byte IV: first 4 bytes BE rikeyid, rest zero), `appid`. One app at a time — a second launch gets 400. `corever>=1` upgrades RTSP to `rtspenc://` (AES-128-GCM). Generated server-side: `av_ping_payload` (16 hex chars of 8 random bytes) and `control_connect_data` (random u32) — the two tokens that later match UDP pings and the ENet connect to this session. Encoder probing runs at every first launch (§7).

---

## 5. RTSP Server

- TCP 48010, **one connection per command** (host closes after each response); 2048-byte max message; connections accepted only while a launch session is pending (10 s expiry, `ping_timeout`), else silently closed — port-scan tolerant.
- The pending launch session survives multiple connections and is consumed not at PLAY but when the **ENet control connection arrives** and matches (`X-SS-Connect-Data` value, or peer IP for legacy clients).
- Encrypted RTSP (`rtspenc://`): 24-byte header {BE type|len with bit 31 set, BE seq, 16-byte GCM tag}; 12-byte IV = seq (LE memcpy) at bytes 0–3, `'C','R'`/`'H','R'` at bytes 10–11.
- **DESCRIBE** advertises: `x-ss-general.featureFlags` (pen/touch 0x01, controller-touch 0x02), encryption supported/requested bits (`SS_ENC_CONTROL_V2/VIDEO/AUDIO` = 1/2/4), RFI support, Opus surround `fmtp` lines (5.1/7.1 mappings rotated left from index 3 — GFE-bug compat), and two magic sentinels clients grep for: `sprop-parameter-sets=AAAAAU` (= HEVC supported) and `a=rtpmap:98 AV1/90000`.
- **SETUP** returns fake `Session: DEADBEEFCAFE;timeout = 90`, `Transport: server_port=<port>` (only field read), plus `X-SS-Ping-Payload` (audio/video) or `X-SS-Connect-Data` (control).
- **ANNOUNCE** parses the client SDP into `config_t` — the complete negotiation surface: resolution/fps/bitrate, `packetSize` (host may clamp; bounds 200–65535), FEC minimum shards, `x-nv-vqos[0].bitStreamFormat` (0=H264 1=HEVC 2=AV1, rejected if codec disabled), `x-ss-video[0].chromaSamplingType` (0=4:2:0, 1=**4:4:4**), `encoderCscMode` (colorspace+range), `dynamicRangeMode`, slices, numRefFrames, intraRefresh, audio channels/mask/quality/packetDuration, encryption flags. Bitrate adjustment: client `configuredBitrateKbps` scaled down for FEC%, minus audio bitrate, minus 500 Kbps control overhead (rtsp.cpp:1254–1274).
- Stereo audio-quality trick, host side: HIGH_QUALITY = RTSP `Host:` header does **not** contain `0.0.0.0` (the client-side counterpart is documented in moonlight-common-c.md §6).
- **PLAY** is a pure 200 no-op — streaming was armed at ANNOUNCE; actual start is gated on UDP pings.

---

## 6. Streaming Core (host side of moonlight-common-c.md §7)

### Ping gating
Session start sets video/audio peers to (RTSP client address, **port 0**) and blocks in `recv_ping` (10 s timeout) before capturing anything. The recv thread demuxes incoming UDP: modern clients send `SS_PING` matched by the 16-char `av_ping_payload`; the **source address AND port of that ping become the send destination** (NAT-safe). Only then does capture/encode spin up.

### Video send path (per frame)
1. SPS/PPS byte-substitution `replacements` applied on IDR frames (see cbs, §9).
2. 8-byte short frame header prepended: type 0x01, latency (0.1 ms units), frameType (1 normal / 2 IDR / 5 after-RFI), lastPayloadLen.
3. Sliced every `packetsize − 16` bytes, 32-byte hole before each slice = RTP(12) + 4 reserved + NV_VIDEO_PACKET(16).
4. Multi-FEC-block split: max **4 blocks** per frame; a frame needing more → **FEC silently disabled for that frame**. ≤255 shards per RS block; ≥1024 packets per block = unrecoverable (10-bit shard index).
5. NV_VIDEO_PACKET: `streamPacketIndex = seq << 8` (low byte always 0), `multiFecFlags=0x10`, `fecInfo = (shardIdx<<12) | (dataShards<<22) | (fec%<<4)`, SOF/EOF per block.
6. FEC: nanors Reed-Solomon, data shards in place (zero-copy), parity = ceil(data × fec% / 100), default fec% **20**, raised to client's `minRequiredFecPackets`. RTP seq counts data + parity.
7. RTP: header byte 0x90 (version + extension bit), BE seq, timestamp = 90 kHz since thread epoch; packetType and ssrc left **0**.
8. Encryption (when negotiated): AES-128-GCM over the **entire RTP packet**, 32-byte prefix {iv[12], frameNumber, tag[16]}; IV = per-session u64 counter (LE) + `iv[11]='V'`.
9. Pacing: hard-coded to **80% of 1 Gbps** in 1 ms groups (not bitrate-derived!); batches ≤64 KB / ≤64 packets via GSO/sendmmsg.

### Audio send path
- Opus multistream, `OPUS_APPLICATION_RESTRICTED_LOWDELAY`, **hard CBR** (`OPUS_SET_VBR(0)`) — CBR is what makes fixed-size FEC shards valid. Bitrates: stereo 96k (512k high), 5.1 256k/1536k, 7.1 450k/2048k. Frame = packetDuration (5 ms default) × 48 kHz.
- RTP packetType 97 (data) / 127 (FEC); **timestamp increments in packetDuration ms units, not sample ticks**; FEC packets' RTP timestamp is always 0.
- Encryption: AES-128-CBC + PKCS7 per packet; IV = BE(rikeyid + seq) in bytes 0–3, rest zero.
- FEC 4+2 Reed-Solomon — **with nanors' parity matrix overwritten by the Nvidia/OpenFEC-compatible bytes `77 40 38 0e c7 a7 0d 6c`** (stream.cpp:1810). A from-scratch host must reproduce this byte-exact or every real Moonlight client fails FEC recovery. Parity covers the *encrypted* payloads; equal shard sizes are guaranteed only by Opus CBR.

### Control stream (ENet host, UDP 47999)
- `enet_host_create` with **128 peers**, max channels; host→client always channel 0, reliable. Client→host: 0x0305/0x0307 START (no-ops), 0x0200 ping (no-op beyond timeout refresh), 0x0201 loss stats (**parsed and logged only — zero adaptation**), 0x0302 IDR request, 0x0301 RFI (two i64s), 0x0206 input, 0x0001 encrypted envelope. Host→client: 0x0109 termination (code `0x80030023` BE = graceful), 0x010b rumble (with a `useless = 0xC0FFEE` field), 0x010e HDR mode, 0x5500–0x5503 Sunshine extensions (trigger rumble, motion, LED, adaptive triggers).
- Encrypted envelope AES-128-GCM: `{u16 0x0001, u16 len, u32 seq}` + tag(16) **before** ciphertext; 12-byte IV = seq (LE) + suffix `'H','C'` (host→client) / `'C','C'` (client→host). No replay/monotonicity check on incoming seq.
- Legacy input decryption (unencrypted control): GCM with **rolling IV** = last 16 bytes of the previous payload.
- IDR/RFI requests → per-session mail events → drained by the encode loop before each frame. Encoders without RFI degrade it to IDR (only Windows standalone NVENC has real RFI).
- Any ENet event refreshes `pingTimeout` (10 s); expiry, disconnect, or GCM tag failure → session stop. Teardown watchdog: 10 s then `debug_trap()` kills the process (NVENC driver-hang insurance).

---

## 7. Video Encode Pipeline

### encoder_t abstraction
Static per-encoder flags (`video.cpp:377`): `PARALLEL_ENCODING`, `H264_ONLY`, `LIMITED_GOP_SIZE` (GOP 32767 instead of INT_MAX — VAAPI), `CBR_WITH_VBR` (QSV: `bit_rate--` to force VBR), `RELAXED_COMPLIANCE`, `NO_RC_BUF_LIMIT`, `REF_FRAMES_INVALIDATION` (Windows NVENC only), `ALWAYS_REPROBE` (software = encoder of last resort), `YUV444_SUPPORT`, `ASYNC_TEARDOWN`, `FIXED_GOP_SIZE` (MediaFoundation). Per-codec capabilities discovered at probe time: `PASSED`, `REF_FRAMES_RESTRICT`, `DYNAMIC_RANGE`, `YUV444`, `DYNAMIC_RANGE_YUV444`, `VUI_PARAMETERS`.

Each platform-format struct carries **four pix_fmt slots**: 8-bit, 10-bit, **444-8bit, 444-10bit**. Probe order: nvenc → quicksync → amdvce → MF/vulkan → vaapi/videotoolbox → software.

| Encoder | 4:2:0 fmts | 4:4:4 fmts | 444? | RFI? |
|---------|-----------|------------|------|------|
| nvenc (Win, standalone SDK) | nv12/p010 | ayuv/yuv444p16 | ✔ | ✔ |
| nvenc (Linux, FFmpeg+CUDA) | NV12/P010 | YUV444P/P16 | ✔ | ✘ |
| quicksync (Win) | NV12/P010 | VUYX/XV30 | ✔ | ✘ |
| software x264/x265 | YUV420P(10) | YUV444P(10) | ✔ | ✘ |
| **vaapi (Linux)** | NV12/P010 | **NONE/NONE** | **✘** | ✘ |
| videotoolbox (macOS) | NV12/P010 | NONE/NONE | ✘ | ✘ |
| amdvce, vulkan, MF | — | NONE | ✘ | ✘ |

Profiles: H.264 High → High 4:4:4 Predictive; HEVC Main/Main10 → **Rext** for any 4:4:4; AV1 Main → High (profile 1). 10-bit H.264 asserted impossible.

### Probing (validate_encoder, video.cpp:3000)
Runs at startup **and every stream launch** (unless nothing changed). Each capability = a **real 1080p60 test encode** (1000 kbps): H.264 baseline, then HEVC/AV1, then separate test encodes for YUV444, HDR, and HDR+444 per codec; first packet must be IDR; SPS parsed for VUI presence. Failures cascade to the next encoder. Results feed serverinfo's SCM bits directly — capability advertisement is empirical, never assumed. (The `pop` hybrid-GPU silent-fallback case study is this mechanism working as designed: NVENC failed its probe, vaapi passed, 4:4:4 silently unavailable.)

### Capture→encode loop & idle behavior — **the VNC-bandwidth divergence point**
- Shared capture thread per display (priority critical), per-session encode loops (priority high), 12-image pool.
- Capture backends push `frame_captured=false` ticks on timeout so the loop stays live without raising image events.
- **Idle floor**: the encode loop waits at most `1000 / minimum_fps_target` ms for a new image (default = **framerate/2**), then **re-encodes the last frame** ("avoid image quality issues with static content", video.cpp:2410). Combined with CBR + single-frame VBV, a fully static desktop still costs roughly half the stream bitrate, forever. Sunshine never approaches VNC idle bandwidth — matching VNC requires *departing* from this design (see §12), which the protocol tolerates: IDR is on-demand, no timing SEI, clients don't require continuous frames.
- A dummy black frame is pre-converted so the client always gets a first frame even if capture times out at start.
- Display change → `reinit` dance: drop pool, drain refcounts, re-enumerate (keep same display by name), rebuild device+session, resend touch-port + HDR state.

### Rate control & GOP
- `rc_max_rate = rc_min_rate = bit_rate` (true CBR) unless flagged; VBV = **bitrate/framerate — single-frame VBV** (the core low-latency choice); software gets 1.5 frames (x264/x265 quality cliff).
- **Filler data explicitly off everywhere** — CBR is HRD-capped, not padded.
- GOP: `gop_size = keyint_min = INT_MAX`, closed GOP, low-delay, **zero B-frames** — `max_num_reorder_frames=0` + frameIntervalP=1 is the invariant the whole protocol rests on (frame index == PTS == RTP frame number).
- IDR only on demand. x265 quirks: `info=0` (Info SEI pushes IDR into packet 2, breaking Moonlight parsing) and keyint must go via x265-params. svt-av1's broken on-demand IDR keeps software AV1 disabled by default.
- Presets: nvenc P1 + ULTRA_LOW_LATENCY + zeroReorderDelay, two-pass quarter-res, min-QP 19/23/23 (h264/hevc/av1); x264 superfast/zerolatency; `surfaces=1`/`async_depth=1` everywhere — one frame in flight.
- VideoToolbox: `realtime=1, prio_speed=1, max_ref_frames=1` — but max_ref_frames **omitted for H.264**: Apple Silicon VT emits all-IDR output with ReferenceBufferCount=1 → ~3× bandwidth (issue #5013).

---

## 8. YUV 4:4:4 Status & the VAAPI Gap

What PR #4965 built (all reusable): `chromaSamplingType` plumbed end-to-end; per-codec 444 probe + SCM advertisement; profile switching; EGL YUV444 render targets + per-plane Y/U/V conversion shaders (`graphics.cpp:1103` `make_yuv444`); CUDA `RGBA_to_YUV444` kernels; GL↔CUDA interop path feeding Linux NVENC.

**What VAAPI 4:4:4 needs** (confirmed against source; matches the plan in the `pop` investigation):
1. `video.cpp:1180` — fill the two `AV_PIX_FMT_NONE` slots with `VUYX` (8-bit) / `XV36` (10-bit) and add `YUV444_SUPPORT`. Without this, `make_encode_device` bails before anything else runs.
2. `vaapi.cpp:420 set_frame` assumes NV12 export: exactly 2 layers, UV = w/2 h/2. A VUYX surface exports as **one packed layer** — needs a packed-write shader variant (or 3-plane handling; note `import_target_yuv444` at graphics.cpp:795 already exists but is **dead code** — declared, defined under a different name, never called).
3. Runtime probe: `get_va_profile` **already returns** `VAProfileHEVCMain444(_10)` for Rext; `is_va_profile_supported` machinery exists. The probe matters — AMD/radeonsi has no 444 encode; the flag alone would break AMD.
4. H.264 stays 4:2:0 (no VA profile exists — comment in source); 444 over VAAPI = HEVC Rext (+ AV1 Profile 1 where supported).
5. Colorspace validation in the new shader path (matrices from `video_colorspace.cpp:132`; classic failure mode).

Driver reality: Intel iHD does HEVC Main444/Main444_10 encode with the LP entrypoint (Gen11+/Ice Lake+, includes Meteor Lake); AMD doesn't.

---

## 9. Colorspace & Bitstream Munging (cbs)

- `encoderCscMode`: bit 0 = full range, bits ≥1 = 0 Rec601 / 1 Rec709 / 2 Rec2020-SDR. HDR ⇔ BT.2020 + ST2084, dual-gated on client request AND display actually in HDR. RGB→YUV matrices generated constexpr per ITU-T H.273 (Kr/Kb 601=.299/.114, 709=.2126/.0722, 2020=.2627/.0593) — consumed by all conversion shaders/kernels.
- **cbs.cpp**: some encoders (AMF, VAAPI) emit SPS without the VUI Moonlight needs. Probe detects it (`validate_sps`); if absent, Sunshine builds replacement SPS/VPS with FFmpeg's ff_cbs — forcing `max_num_reorder_frames=0`, `max_dec_frame_buffering=refs`, colour signaling, HEVC `general_profile_compatibility_flag[4]=1` — and byte-substitutes them into every outgoing IDR packet. The reorder/dpb fields are the latency-critical bits for client decoders.
- HDR mastering metadata rides AVFrame side data → encoder SEI; NVENC standalone instead raises a client HDR event with raw metadata.

---

## 10. Linux Platform Layer

### Capture backends (priority: NvFBC → wlr → KMS → X11 → KWin → portal; KMS checked first to drop CAP_SYS_ADMIN early)
- **KMS/DRM** (kmsgrab.cpp, 2145 lines): libdrm plane walk; CAP_SYS_ADMIN raised only around `drmModeGetFB2`; **pure polling** (sleep-to-frame-interval, re-read plane fb — no damage detection); cursor = separate DRM cursor plane, props in Q16.16, mmap with DMA_BUF_SYNC brackets, NVIDIA ENOSYS → dumb-buffer fallback; HDR via `HDR_OUTPUT_METADATA` blob; hybrid rule: **vaapi skips NVIDIA cards, cuda skips non-NVIDIA**. Two traps to replicate: the **DRM master trap** (opening /dev/dri/cardN can implicitly grant DRM master → detect via ioctl-errno oracle and `drmDropMaster()`, else the compositor breaks) and the Wayland connector-name correlation hack for desktop-space offsets.
- **wlroots screencopy** (wlgrab/wayland.cpp): Sunshine allocates its own GBM BO on its render node, wraps via `zwp_linux_buffer_params_v1`, compositor copies into it; blocks until `ready` — compositor-paced. Damage API present but unused.
- **PipeWire base** (pipewire.cpp, new): the modern path. `framerate=0/1` (variable rate), requests `SPA_META_VideoDamage`; **drops redundant frames** (same PTS + no damage) and `CORRUPTED` chunks; waits on a condition variable — **genuinely event-driven**. DMA-BUF only for vaapi/vulkan or pure-NVIDIA; hybrid Intel+NVIDIA forces MemPtr copies (Intel dmabufs can't import into CUDA).
- **Portal** (portalgrab.cpp): GDBus to xdg-desktop-portal; RemoteDesktop+ScreenCast combined session; `persist_mode=UNTIL_REVOKED` + **restore_token persisted to `<appdata>/portal_token`** — the key to unattended restarts. Caller must drop caps and be dumpable or the portal refuses.
- **KWin** (kwingrab.cpp): zkde_screencast, no consent dialog — KWin trusts a self-written `.desktop` file with `X-KDE-Wayland-Interfaces`.
- **X11**: XShm via dlopen'd libs; **all X/avahi/GBM libraries are dlopen'd with function-pointer tables** — Sunshine never links them (pattern worth copying for a single-binary host).
- **NvFBC**: consumer-GPU unlock via magic private data; X11-only in practice.

### EGL conversion layer (graphics.cpp)
Surfaceless desktop-GL context via `eglGetPlatformDisplayEXT` (GBM/Wayland/X11); requires `EGL_EXT_image_dma_buf_import(+modifiers)`; high-priority context needs CAP_SYS_NICE. Fullscreen-triangle shaders (`#version 300 es`): NV12 = Y pass + half-res 2-tap UV pass; **YUV444 = three full-res single-channel passes** (PR #4965); cursor alpha-blended in GL; uniform block = the H.273 color vectors. VAAPI zero-copy: VA surface → `vaExportSurfaceHandle(DRM_PRIME_2, WRITE_ONLY|SEPARATE_LAYERS)` → EGL import → **GL renders directly into the encoder's surface**.

### Audio & input
- Audio = **PulseAudio API only** (works via pipewire-pulse): `module-null-sink` virtual sinks (`sink-sunshine-stereo/...`), capture from monitor source, `pa_simple_read` blocking, float32.
- Input = **inputtino over uinput** (+uhid for DS5): global virtual mouse+keyboard (VID 0xBEEF PID 0xDEAD), per-client touchscreen+pen, gamepads as XboxOne (045E:02EA)/Switch (057E:2009)/DS5 (054C:0CE6 with deterministic MAC). Unicode = typed Ctrl+Shift+U hex sequence. No libei. Permissions: udev rule `KERNEL=="uinput", GROUP="input", MODE="0660", TAG+="uaccess"`.
- mDNS: avahi (dlopen'd), publishes `_nvstream._tcp` on 47989, **no TXT records**.
- systemd **user** service: `After=graphical-session.target xdg-desktop-portal.service`, `ExecStartPre=/bin/sleep 5` — session env (WAYLAND_DISPLAY, XDG_RUNTIME_DIR, D-Bus) comes free with user-service placement. Validates LYTE-PLAN's in-session host-role decision.

---

## 11. macOS Host — Why It's Sunshine's Weakest Platform

Concrete, all verified in source:
1. Capture = **deprecated `AVCaptureScreenInput`** (av_video.m:31), not ScreenCaptureKit: no HDR capture, no damage info, no per-window capture; capture can block forever (literal `// FIXME` at display.mm:108).
2. **Gamepad input entirely unimplemented** (`alloc_gamepad` returns −1); unicode text injection "not yet implemented"; touch/pen no-ops; `get_capabilities()` returns 0.
3. **No 4:4:4** (444 slots = NONE), no RFI; H.264 needs the all-IDR workaround (#5013).
4. Accessibility TCC for CGEventPost is never preflighted — input silently fails until the user finds the checkbox. Screen-recording TCC is at least prompted.
5. Audio: Core Audio **process tap** (macOS 14+; `CATapDescription` + aggregate device + TPCircularBuffer ≈30 ms) — actually the most modern piece of the macOS port; mute-behavior natively replaces the virtual-sink dance. Pre-14 needs BlackHole-style loopback. Sink switching stubbed.
6. Zero-copy exists: captured CVPixelBufferRef lands directly in `AVFrame.data[3]` (AV_PIX_FMT_VIDEOTOOLBOX) via CFRetain — no memcpy capture→encode.
7. No virtual display, no service story (login item at best), no single-instance guard, timer = plain `sleep_for`.

A Swift host using ScreenCaptureKit (damage-driven!) + VideoToolbox HEVC Rext 4:4:4 + a virtual-controller story would exceed Sunshine-on-macOS on every axis, not just match it.

---

## 12. App Core, Config Surface & UX Plumbing

- **Startup** (main.cpp): mailbox → config → logging → display-device crash recovery → task_pool(1) → signal handlers (SIGINT with 10 s force-kill watchdog; shutdown *is* `std::raise(SIGINT)`) → apps.json → fail-soft init (capture/encoder failures keep the process alive so the web UI can fix config; only `http::init` is fatal) → mDNS/UPnP async → three server threads → tray loop on main thread. **No single-instance guard on macOS/Linux** — second instance just fails on port bind.
- **Config**: ~**95 keys**, of which ~37 are per-vendor encoder tuning (nvenc 9, amd 7, qsv 3, vt 3, vaapi 4, vulkan 2…). Format is `name = value` with embedded-JSON warts. **No live reload** — the web UI rewrites the file and re-execs the process. `to_bool` treats any string containing '1' as true.
- **Web UI** (confighttp, 47990): HTTPS with the same self-signed cert (permanent browser warning), HTTP Basic auth (password = salted hash in the state file), CSRF tokens with a headerless-request bypass, `/api/pin` (the actual pairing approval), apps editor, log dump, **server filesystem browser**. Exists because pairing/apps/creds need *some* surface.
- **Tray** (vendored `tray.h`; Qt-backed on Linux!): Open-UI / Donate / Restart / Quit — pairing shows only a clickable notification that opens the browser at `/pin`. The PIN is never entered in the tray.
- **Apps model** (process.cpp): apps.json with `$(ENV)` expansion; app id = CRC32(name+image-hash) truncated positive (stable, content-derived); `cmd`-less apps are `placebo=true` = the "Desktop" concept — stream with nothing launched; prep-cmds run sync with reverse-order undo; processes in a group, graceful-then-kill with 5 s default timeout; launched apps get `SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS/HDR/...` env.
- **Input processing** (input.cpp): decrypted packets → queue → single task_pool thread. **Batching** under the lock: rel-mouse deltas summed (overflow-checked), abs/controller/touch latest-wins, scrolls summed — the load-shedding when OS injection is slower than packet rate. Host-synthesized **key repeat** (500 ms delay, 24.9 Hz). Left-button release delayed 10 ms in absolute mode (right-click ordering bug). Ctrl+Alt+Shift+F1–F13 = switch display; +N = toggle cursor. **No clipboard anything.**

---

## 13. Threading Model (typical single-session Linux stream)

| Thread | Role |
|--------|------|
| main | tray event pump |
| nvhttp ×2, confighttp, rtsp | TCP servers (handlers inline, single-threaded each — all pairing state is thread-confined by construction) |
| recv (broadcast) | UDP ping demux |
| video (broadcast) | packetize/FEC/encrypt/pace/send — all sessions |
| audio (broadcast) | RTP/CBC/FEC/send — all sessions |
| control (broadcast) | ENet service loop, 150 ms slices, priority critical |
| session videoThread | capture-wait → convert → encode (priority high; capture thread critical) |
| session audioThread | pa_simple_read → Opus |
| task_pool (1) | input batching/repeat, delayed tasks |
| upnp, mDNS | housekeeping |

---

## 14. Known Limitations & Quirks (the ones that bite)

1. **Idle ≠ quiet**: fps/2 re-encode floor + CBR — a static desktop costs ~half bitrate forever (§7).
2. **Loss stats are decorative** — no adaptive bitrate/FEC whatsoever; recovery is client-driven IDR/RFI only.
3. Audio FEC parity matrix must be byte-exact `77 40 38 0e c7 a7 0d 6c`; audio RTP timestamps in ms units; FEC packets' timestamp always 0.
4. Video RTP: packetType/ssrc = 0, `streamPacketIndex = seq<<8`; parity shards get their header fields overwritten post-RS (clients reconstruct from data shards).
5. Send pacing assumes 1 Gbps regardless of stream bitrate.
6. Pairing PIN answers a random concurrent session; parked HTTP response never times out; final-phase failure returns 200.
7. RTSP: one TCP connection per command; 2048-byte cap; fake session ID; magic sentinel strings (`AAAAAU`).
8. `/cancel` kills all sessions and the app, from any paired client.
9. RFI exists on exactly one encoder (Windows standalone NVENC); everything else silently degrades to IDR.
10. Probe leak: full re-probe leaks ~20 MB (FFmpeg CBS) — hence probe-once-per-device-path.
11. VAAPI 4:4:4: profile mapper ready, EGL target dead code present, pixel-format slots empty (§8).
12. Windows-only niceties (virtual display management, RFI, HAGS) make Linux/macOS second- and third-class.
13. 95-key config; no live reload (re-exec); web UI mandatory for pairing approval.
14. No single-instance enforcement; no reconnect/resume concept — session death = full relaunch.
15. `while_starting_do_nothing` spins on a state nothing ever sets; packet type 0x0204 dead; `useless = 0xC0FFEE`.

---

## 15. Improvement Opportunities (the Lyte host)

### Protocol-compatible, behavior-better
1. **True idle silence** — event-driven capture (PipeWire damage / ScreenCaptureKit) + skip unchanged frames entirely + VBR floor. Clients tolerate frame gaps (on-demand IDR, no timing dependency). This is the VNC-idle-bandwidth win; Sunshine's fps/2 CBR floor is a choice, not a protocol requirement. Keep a slow keepalive re-encode (~1 fps) only if a decoder proves to need it.
2. **Use the loss stats** — the client already reports loss every ~50 ms; adapt FEC% and bitrate instead of logging.
3. **Pace to the negotiated bitrate**, not to 80% of an assumed gigabit link.
4. **VAAPI 4:4:4** — the §8 recipe; upstream-shaped, also a candidate contribution.
5. **macOS host beyond Sunshine**: ScreenCaptureKit (damage-driven, HDR), VideoToolbox HEVC Rext 4:4:4, virtual game controller, proper TCC preflight for both Screen Recording *and* Accessibility.

### Byte-exact compatibility checklist (things that MUST match)
Negative version quad (`x.y.z.-1`); SCM bit values; pairing crypto exactly (SHA256-salted AES-128-ECB, per-cert stores, dateless leaf pinning); `sprop-parameter-sets=AAAAAU` + `rtpmap:98` sentinels; surround mapping rotation; audio parity matrix; all IV constructions (control 'HC'/'CC', video 'V', audio BE(rikeyid+seq), RTSP 'CR'/'HR', legacy rolling IV); tag-before-ciphertext GCM layout; `max_num_reorder_frames=0` invariant; NV_VIDEO_PACKET field packing; ping-before-send gating.

### Architecture (Swift host)
6. Keep the **mailbox decoupling** (natural fit: AsyncStream/actors), the **dlopen-leaf pattern** (single binary, no linked X/avahi/GBM), the **empirical capability probe** (test encodes → advertised bits → doctor diagnoses), and the **portal restore token** (unattended restarts).
7. Kill the web UI: pairing approval, client management, and status belong in the agent (menu bar/tray) — collapses confighttp, Basic auth, CSRF, and the self-signed browser warning in one move.
8. Config: Sunshine's 95 keys → Lyte's policy grid + a handful of overrides. One encoder path per OS deletes ~40% of the surface immediately.
9. Single-instance guard (flock/Unix socket); live config as messages, not re-exec.
10. Session resilience: resume tokens + control-channel reconnect instead of death-on-timeout (pairs with moonlight-common-c.md §15.11).
11. Replicate the hard-won traps: DRM master oracle, hybrid-GPU card filtering (vaapi↔NVIDIA exclusion), Intel+NVIDIA no-dmabuf-into-CUDA rule, x265 Info-SEI quirk, VT H.264 ref-frames bug, cursor-plane Q16.16, capture-permission preflights.

---

## 16. Critical Constants (Quick Reference)

```
Ports: base 47989; HTTPS −5; webUI +1; video +9; control +10; audio +11; RTSP +21
appversion "7.1.431.-1" (negative quad = Sunshine)   GfeVersion "3.23.0.74"
MaxLumaPixelsHEVC 1869449984
ping_timeout 10 s   teardown watchdog 10 s   force-shutdown watchdog 10 s
FEC video: 20% default (1–255), ≤4 blocks/frame, ≤255 shards/block, <1024 pkts/block
FEC audio: 4+2, parity matrix 77 40 38 0e c7 a7 0d 6c (Nvidia-compatible, byte-exact)
Audio: 48 kHz, CBR Opus, RESTRICTED_LOWDELAY; stereo 96k/512k, 5.1 256k/1536k, 7.1 450k/2048k
RTP: video hdr 0x90, PT 0; audio PT 97 data / 127 FEC; video clock 90 kHz
Idle floor: minimum_fps_target default = framerate/2 (re-encode last frame)
VBV: bitrate/framerate (single frame); hw min-QP nvenc 19/23/23; sw preset superfast/zerolatency
GOP: INT_MAX (32767 if LIMITED), B-frames 0, reorder 0
Pacing: 80% of 1 Gbps, 1 ms groups, batches ≤64 KB/≤64 pkts (GSO)
Capture pool 12 imgs; audio queue 30 frames; ENet peers 128; RTSP msg ≤2048 B
Encryption: AES-128 everywhere from rikey; GCM tag 16 B before ciphertext
Termination code 0x80030023 BE; SCM 444 bits 0x0008/0x1000/0x2000/0x40000/0x80000
Config: ~95 keys; state sunshine_state.json; portal token <appdata>/portal_token
uinput udev: KERNEL=="uinput", GROUP="input", MODE="0660", TAG+="uaccess"
```

---

## 17. Summary

Sunshine is a battle-tested host whose real treasure is **accumulated platform knowledge**: the DRM master trap, hybrid-GPU exclusion rules, the VA-surface-as-GL-target zero-copy trick, portal restore tokens, encoder-specific quirk lists, and an empirical probe architecture that never advertises what it hasn't proven. Its debts are equally clear: a 95-key knob farm, a mandatory web UI for pairing, no idle silence (fps/2 CBR floor), no adaptation (loss stats ignored), RFI on one encoder, a stub-riddled macOS port, and 4:4:4 that stops short of VAAPI. The Lyte host should copy the traps and the probe discipline, match the wire byte-exactly where compatibility demands it (§15 checklist), and diverge deliberately where Sunshine's choices are choices — damage-driven idle silence, loss-driven adaptation, agent-based pairing, and 4:4:4 on every encoder we ship.
