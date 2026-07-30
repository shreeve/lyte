# moonlight-common-c — Protocol & Library Analysis

> **GameStream-era reference (annotated 2026-07-30).** The client
> lineage this study served was deleted at the H2 exit (2026-07-22);
> Lyte speaks only Lyte-UDP. The protocol halves here are archaeology —
> kept for the engineering knowledge (jitter buffering, RTP/FEC
> handling, control-stream patterns) that informed the Lyte designs.

Deep technical analysis of `moonlight-common-c/`, the shared C streaming core used by Moonlight clients (Qt, Android, iOS/macOS, Chrome). Goal: understand the wire protocol, API surface, and operational quirks well enough to design **better versions**.

**Related:** [`moonlight-macos.md`](moonlight-macos.md) (macOS client)

---

## 1. Scope & Role

**What this library is:** the post-launch GameStream / Sunshine **session client**. It owns RTSP negotiation, UDP video/audio receive + FEC, ENet/TCP control, encrypted input, and decoder/audio callback plumbing.

**What this library is not:** host discovery (mDNS), HTTPS pairing, `/serverinfo`, `/applist`, `/launch`, `/resume`, certificate management, or UI. Those live in each client app (see `moonlight-macos.md` for the macOS client's half).

**Checkout notes:** `enet/` and `nanors/` are git submodules and may be empty until `git submodule update --init`. Builds require the **forked** ENet (ABI-incompatible with stock libenet).

---

## 2. Directory Structure & Build

```
moonlight-common-c/
├── CMakeLists.txt              # C11 shared lib; OpenSSL or MbedTLS
├── cmake/FindMbedTLS.cmake
├── README.md
├── .gitmodules                 # enet + nanors
├── enet/                       # cgutman/enet fork (IPv6 + reliability)
├── nanors/                     # Reed-Solomon FEC (sleepybishop/nanors)
└── src/
    ├── Limelight.h             # PUBLIC API (only intended export)
    ├── Limelight-internal.h    # Globals, Sunshine detection, enc flags
    ├── Connection.c            # LiStartConnection orchestration
    ├── RtspConnection.c        # RTSP OPTIONS→PLAY
    ├── RtspParser.c / Rtsp.h
    ├── SdpGenerator.c          # Client SDP for ANNOUNCE
    ├── ControlStream.c         # ENet/TCP control + host→client events
    ├── VideoStream.c           # UDP video receive + ping
    ├── VideoDepacketizer.c     # NV packets → DECODE_UNIT
    ├── RtpVideoQueue.c/.h      # Video FEC (nanors)
    ├── AudioStream.c           # UDP audio receive + ping
    ├── RtpAudioQueue.c/.h      # Audio FEC (nanors)
    ├── InputStream.c / Input.h # Client→host input
    ├── Platform*.c/h           # Threads, sockets, crypto, time
    ├── Misc.c                  # ENet host service wrapper
    ├── FakeCallbacks.c         # No-op defaults for NULL callbacks
    ├── ConnectionTester.c      # Port connectivity probes
    ├── SimpleStun.c            # WAN IPv4 STUN helper
    ├── ByteBuffer.*            # LE parsing
    ├── LinkedBlockingQueue.*
    └── RecorderCallbacks.c     # Optional recording hooks
```

**CMake highlights:**
- C11; `BUILD_SHARED_LIBS` on by default
- Crypto: OpenSSL ≥1.0.2 (`libcrypto`) or `USE_MBEDTLS=ON`
- nanors compiled in-tree (`rs.c` + obl linear algebra)
- Public include path: `src/` → `#include "Limelight.h"`
- Windows links `ws2_32` / `winmm`

---

## 3. Protocol Overview (End-to-End)

NVIDIA GameStream (GFE) and open-source **Sunshine** implement a proprietary stack. The full client session looks like:

```
┌──────────────────────────────────────────────────────────────────┐
│ CLIENT APP (outside this library)                                │
│  mDNS _nvstream._tcp → HTTP(S) pair → /serverinfo → /applist     │
│  /launch or /resume → sessionUrl0, rikey, rikeyid, codec flags   │
└────────────────────────────┬─────────────────────────────────────┘
                             │ LiStartConnection(serverInfo, streamConfig, …)
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│ moonlight-common-c                                               │
│  1. Resolve host, probe ports                                    │
│  2. Bind audio UDP + start audio ping (pre-PLAY requirement)     │
│  3. RTSP: OPTIONS → DESCRIBE → SETUP×3 → ANNOUNCE → PLAY         │
│  4. Control (ENet UDP 47999 or TCP 47995)                        │
│  5. Video UDP + Audio UDP (RTP-like + FEC)                       │
│  6. Input on control channels (encrypted)                        │
│  7. Callbacks: DECODE_UNIT / Opus samples / rumble / terminate   │
└──────────────────────────────────────────────────────────────────┘
```

**Sunshine detection:** `IS_SUNSHINE()` = `AppVersionQuad[3] < 0` (clients must pass a negative build component from `/serverinfo` for Sunshine hosts).

**No reconnect:** failure → `connectionTerminated(errorCode)`. Client must `LiStopConnection` and re-run `/resume` or `/launch` before another `LiStartConnection`.

---

## 4. Port Map

| Port | Proto | Role |
|------|-------|------|
| **47984** | TCP | HTTPS GameStream (app-side) / connectivity probe |
| **47989** | TCP | HTTP GameStream (app-side) / connectivity probe |
| **47995** | TCP | Gen 3–4 control stream |
| **47996** | TCP | Gen 3 “first frame” trigger (connect then close) |
| **47998** | UDP | Video RTP (default; actual from RTSP SETUP) |
| **47999** | UDP | Control ENet (Gen 5+) |
| **48000** | UDP | Audio RTP |
| **48010** | TCP/UDP | RTSP (default) |

Flags/indexes in `Limelight.h`: `ML_PORT_FLAG_UDP_47998` (0x0100), `ML_PORT_FLAG_UDP_47999` (0x0200), `ML_PORT_FLAG_UDP_48000` (0x0400), etc. Used by `LiTestClientConnectivity()`.

---

## 5. Connection Lifecycle (`Connection.c`)

`LiStartConnection` is **blocking** and **not thread-safe**. Stages from `Limelight.h`:

| Stage | ID | Action |
|-------|-----|--------|
| `STAGE_PLATFORM_INIT` | 1 | Sockets, timers |
| `STAGE_NAME_RESOLUTION` | 2 | Resolve; probe TCP 47984/47989/48010; local addr |
| `STAGE_AUDIO_STREAM_INIT` | 3 | Bind UDP; start audio ping **before** RTSP finishes |
| `STAGE_RTSP_HANDSHAKE` | 4 | Negotiate ports, codec, Opus, encryption, RFI |
| `STAGE_CONTROL_STREAM_INIT` | 5 | Queues, crypto, packet-type tables |
| `STAGE_VIDEO_STREAM_INIT` | 6 | Depacketizer + RTP FEC queue |
| `STAGE_INPUT_STREAM_INIT` | 7 | Input queues + crypto |
| `STAGE_CONTROL_STREAM_START` | 8 | ENet/TCP connect, START A/B |
| `STAGE_VIDEO_STREAM_START` | 9 | Video ping + receive threads |
| `STAGE_AUDIO_STREAM_START` | 10 | Opus path + receive/decode threads |
| `STAGE_INPUT_STREAM_START` | 11 | Input send thread |

On failure, `LiStopConnection()` unwinds stages in reverse. `LiInterruptConnection()` is async; do not start another connection until `LiStartConnection` returns.

Termination callbacks run on a **detached thread** so clients can safely call `LiStopConnection` from `connectionTerminated` without deadlock.

---

## 6. RTSP Handshake (`RtspConnection.c` + `SdpGenerator.c`)

### Transport selection
- **TCP RTSP** — modern GFE 3.22+, all Sunshine; retries on `ECONNREFUSED` (GFE race after `/launch`)
- **ENet RTSP** (`rtspru://`) — GFE Gen 5.x–early 7.x (`AppVersionQuad[0]` 5–7 and patch `< 404`)
- **Encrypted RTSP** (`rtspenc://`) — AES-128-GCM wrapper; incompatible with ENet RTSP

### Sequence
1. **OPTIONS**
2. **DESCRIBE** — parse SDP for H.264 / HEVC / AV1, Opus surround-params, RFI, Sunshine flags
3. **SETUP** `streamid=audio` → `AudioPortNumber`, session ID, `X-SS-Ping-Payload`
4. **SETUP** `streamid=video` → `VideoPortNumber`, video ping payload
5. **SETUP** `streamid=control/13/0` (GFE 7.1.431+) → `ControlPortNumber`, `X-SS-Connect-Data`
6. **ANNOUNCE** — client SDP from `getSdpPayloadForStreamConfig()`
7. **PLAY** — single `/` on newer GFE; else per-stream

Client advertises `X-GS-ClientVersion` mapped from host gen (3→10 … 7→14).

### Client SDP knobs (selected)
- Encoder bitrate ≈ **80%** of user bitrate (FEC adds ~20%)
- Video FEC repair: **20%** default; **5%** at 4K on older GFE (`x-nv-vqos[0].fec.repairPercent`)
- Max FPS, slices, colorspace/range, HDR, encryption feature bits
- Sunshine: `x-ss-*` / `x-ml-*` attributes; `LiGetLaunchUrlQueryParameters()` → `"&corever=1"`

### Quirks
- **CSeq starts at 0** intentionally (host bug workaround)
- **Audio quality trick:** for “remote” / low-bitrate streams, RTSP URL may use `0.0.0.0` so GFE selects low-quality stereo; local/high-bitrate uses real address for high-quality Opus
- Opus surround channel order remapped for GFE LFE placement

---

## 7. Network Layers in Detail

### 7.1 Video UDP (`VideoStream.c` → `RtpVideoQueue.c` → `VideoDepacketizer.c`)

```
UDP recv → [optional AES-128-GCM] → RtpvAddPacket (FEC/reorder)
  → processRtpPayload → DECODE_UNIT queue
  → submitDecodeUnit OR LiWaitForNextVideoFrame / LiPollNextVideoFrame
```

- Large recv buffer: `2048 * (packetSize + 16)`
- **Ping thread** every 500 ms: legacy `"PING"` or Sunshine `SS_PING` (16-byte payload + BE32 seq)
- Gen 3: TCP connect to **47996**, close to start video flow
- Timeouts (10 s): `ML_ERROR_NO_VIDEO_TRAFFIC` (−100), `ML_ERROR_NO_VIDEO_FRAME` (−101)

**`NV_VIDEO_PACKET`** (after RTP extension header):

```c
uint32_t streamPacketIndex;  // 24-bit SPI in lower bits
uint32_t frameIndex;
uint8_t  flags;              // SOF=0x4, EOF=0x2, PIC=0x1
uint8_t  extraFlags;         // LTR_FRAME=0x1
uint8_t  multiFecFlags;
uint8_t  multiFecBlocks;
uint32_t fecInfo;            // FEC %, shard counts, index
```

**Depacketizer:** Annex-B for H.264/HEVC (split SPS/PPS/VPS on IDR); AV1 as `BUFFER_TYPE_PICDATA`. Frame header size varies by GFE version (0–44 bytes). After ~120 consecutive drops → `LiRequestIdrFrame`. Decoder returns `DR_NEED_IDR` (−1) to force refresh.

### 7.2 Audio UDP (`AudioStream.c` + `RtpAudioQueue.c`)

- Ping starts during RTSP (`notifyAudioPortNegotiationComplete`) — GFE 3.22 requires audio ping before PLAY
- Drop first **~500 ms** of audio (host buffer flush)
- RTP payload type **97** = audio, **127** = FEC
- FEC: **4 data + 2 repair** shards (`RTPA_DATA_SHARDS` / `RTPA_FEC_SHARDS`); custom Nvidia parity matrix (not stock nanors)
- Encryption (GFE 7.1.431+ / Sunshine): AES-128-CBC; IV = `BE32(avRiKeyId + rtpSeq)`
- Opus at 48 kHz; `samplesPerFrame = 48 * AudioPacketDuration` (5 or 10 ms)

### 7.3 Control stream (`ControlStream.c`)

**Gen 5+ — ENet on UDP ControlPort (47999), 48 channels (`CTRL_CHANNEL_COUNT 0x30`):**

| Channel | Use |
|---------|-----|
| 0x00 | Generic |
| 0x01 | Urgent (IDR, LTR ACK, RFI) |
| 0x02 | Keyboard |
| 0x03 | Mouse |
| 0x04 | Pen |
| 0x05 | Touch |
| 0x06 | UTF-8 text |
| 0x10+ | Gamepad base + index |
| 0x20+ | Sensor base + index |

**Gen 3–4:** TCP **47995**.

Host→client packet types include IDR request, loss stats, rumble, termination, HDR mode, and Sunshine extensions (trigger rumble, motion, LED, adaptive triggers — `0x5500`–`0x5503` range).

Client→host: loss reports (~50 ms), ping (~100 ms on newer GFE), IDR, RFI tuples, FEC status (Sunshine).

Connection quality overlay: sample every 3 s; **POOR** if ≥30% loss once or ≥15% twice; **OKAY** if ≤5%.

### 7.4 Encryption summary

Session keys come from `/launch` `rikey` / `rikeyid` → `remoteInputAesKey` / `remoteInputAesIv`.

| Stream | Algorithm | Notes |
|--------|-----------|-------|
| Video (Sunshine opt-in) | AES-128-GCM | `ENC_VIDEO_HEADER`: IV, frame#, tag |
| Audio | AES-128-CBC | Seq-based IV |
| Input Gen 7+ | AES-128-GCM | Per ENet packet |
| Input Gen 5–6 | AES-128-CBC + PKCS7 | |
| Control Gen 7+ | AES-128-GCM | Encrypted NVCTL header |
| RTSP `rtspenc://` | AES-128-GCM | Seq IV; CR/HR markers |

Sunshine feature bits (`Limelight-internal.h`):

```c
SS_ENC_CONTROL_V2  0x01
SS_ENC_VIDEO       0x02
SS_ENC_AUDIO       0x04
```

Client `encryptionFlags`: `ENCFLG_AUDIO`, `ENCFLG_VIDEO`, `ENCFLG_ALL`. **Input encryption is always on** for Gen 7+.

### 7.5 FEC (nanors)

- **Video:** Reed-Solomon; multi-FEC blocks per frame (up to 4 on GFE 7.1.431+); speculative RFI when loss is predictable; OOS cooldown ~5 minutes
- **Audio:** 4+2 shards; disabled on GFE < 7.1.415; variable shard sizes on Sunshine

---

## 8. Public API (`Limelight.h`)

### Lifecycle
```c
int LiStartConnection(PSERVER_INFORMATION, PSTREAM_CONFIGURATION,
    PCONNECTION_LISTENER_CALLBACKS, PDECODER_RENDERER_CALLBACKS,
    PAUDIO_RENDERER_CALLBACKS, void* renderContext, int drFlags,
    void* audioContext, int arFlags);
void LiStopConnection(void);
void LiInterruptConnection(void);
const char* LiGetStageName(int stage);
```

### Configuration
`STREAM_CONFIGURATION`: width, height, fps, bitrate, packetSize, streamingRemotely (`LOCAL`/`REMOTE`/`AUTO`), audioConfiguration, supportedVideoFormats, clientRefreshRateX100, colorSpace, colorRange, encryptionFlags, AES key/IV.

`SERVER_INFORMATION`: address, appVersion, gfeVersion, `rtspSessionUrl`, `serverCodecModeSupport` (must be non-zero).

### Video formats
`VIDEO_FORMAT_H264`, `H265`, `H265_MAIN10`, AV1 Main/High 8/10-bit, YUV444 variants. Masks: `VIDEO_FORMAT_MASK_H264/H265/AV1`, `_10BIT`, `_YUV444`.

### Decoder capabilities
| Flag | Meaning |
|------|---------|
| `CAPABILITY_DIRECT_SUBMIT` | Callback from receive thread |
| `CAPABILITY_REFERENCE_FRAME_INVALIDATION_*` | H.264 / HEVC / AV1 RFI |
| `CAPABILITY_SLOW_OPUS_DECODER` | Skip high-quality audio |
| `CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION` | Variable Opus frames |
| `CAPABILITY_PULL_RENDERER` | Use `LiWait`/`LiPoll`/`LiComplete` |
| `CAPABILITY_SLICES_PER_FRAME(x)` | Encoder slice hint |

### Pull renderer
```c
bool LiWaitForNextVideoFrame(VIDEO_FRAME_HANDLE*, PDECODE_UNIT*);
bool LiPollNextVideoFrame(...);
bool LiPeekNextVideoFrame(PDECODE_UNIT*);
void LiCompleteVideoFrame(VIDEO_FRAME_HANDLE, int drStatus);
```

### Input (queued; non-blocking)
Mouse move/position, touch, pen, keyboard (+ Sunshine non-normalized flag), UTF-8 text, single/multi controller, controller arrival/touch/motion/battery, scroll / high-res / horizontal scroll.

### Diagnostics
`LiGetEstimatedRttInfo`, `LiRequestIdrFrame`, `LiGetHostFeatureFlags`, `LiGetRTPVideoStats` / `LiGetRTPAudioStats`, `LiTestClientConnectivity`, `LiGetLaunchUrlQueryParameters`.

### Termination codes
| Code | Meaning |
|------|---------|
| `0` | Graceful host end |
| `−100` | No video UDP traffic |
| `−101` | Packets but no complete frame |
| `−102` | Unexpected early termination |
| `−103` | Protected content (DRM) |
| `−104` | Frame conversion (HDR/res mismatch) |

---

## 9. DECODE_UNIT & Wire Formats

```c
typedef struct _DECODE_UNIT {
    int frameNumber;
    int frameType;           // PFRAME=0, IDR=1
    uint16_t frameHostProcessingLatency;  // 1/10 ms
    uint64_t receiveTimeUs, enqueueTimeUs, presentationTimeUs;
    uint32_t rtpTimestamp;   // 90 kHz — CMTimeMake(ts, 90000)
    int fullLength;
    PLENTRY bufferList;      // SPS/PPS/VPS/PICDATA chain
    bool hdrActive;          // NOT from bitstream — side channel
    uint8_t colorspace;      // same caveat
} DECODE_UNIT;
```

RTP header: V/P/X/CC, packet type, BE sequence, 90 kHz timestamp, SSRC; extension bit required for video path.

Input header: `NV_INPUT_HEADER { size BE; magic LE event type }`.

Sequence math uses wrap-safe `isBefore16/24/32` macros.

---

## 10. Threading Model

Typical Gen 7+ session threads:

| Thread | Module | Role |
|--------|--------|------|
| VideoPing / VideoRecv [/ VideoDec] | VideoStream | Keepalive; recv→FEC→depacketize; optional submit |
| AudioPing / AudioRecv [/ AudioDec] | AudioStream | Pre-RTSP ping; recv→FEC; Opus callback |
| ControlRecv | ControlStream | Host events |
| LossStats | ControlStream | Loss + FEC status |
| ReqIdrFrame / InvRefFrames | ControlStream | IDR + RFI queues |
| AsyncCallback | ControlStream | Rumble/HDR off control thread |
| InputSend | InputStream | Encrypt + ENet send |
| AsyncTerm | Connection | One-shot termination callback |

**Blocking:** entire handshake on caller thread; queue waits in decoder/audio paths; ENet service in 100 ms slices (`serviceEnetHost` in `Misc.c`).

**Globals:** single session only — `RemoteAddr`, `StreamConfig`, ports, negotiated format are process-global. Not safe for multi-session.

---

## 11. Configuration Behavior

| Field | Effect |
|-------|--------|
| width/height | SDP viewport; height forced even |
| fps | `x-nv-video[0].maxFPS` |
| bitrate | User-facing; encoder gets ~80%; FEC overhead separate |
| packetSize | Multiple of 16; remote AUTO caps 1024 (IPv4) / 1184 (IPv6); shrinks if video encrypted |
| streamingRemotely | AUTO = RFC1918 heuristic |
| audioConfiguration | `MAKE_AUDIO_CONFIGURATION(ch, mask)` magic `0xCA` |
| supportedVideoFormats | Negotiation priority: AV1 → HEVC → H.264 |
| clientRefreshRateX100 | Host frame-pacing hint (e.g. 5994) |
| encryptionFlags | Opt-in A/V encryption |

High-quality surround: bitrate ≥ 15 Mbps, not slow decoder, local (or stereo-only if remote). Packet duration 5 ms default; 10 ms if slow decoder / low bitrate with arbitrary-duration support.

H.264 RFI at 4K is **disabled on GFE** in `Connection.c`.

---

## 12. Resilience Path

1. Reed-Solomon FEC (video + audio)
2. Gap detection → RFI (if decoder + host support) else IDR
3. Speculative RFI before shard timeout when loss is predictable
4. `DR_NEED_IDR` / `LiRequestIdrFrame` / `requestDecoderRefresh` (flush queues)
5. Connection status overlay (POOR/OKAY)
6. Hard timeouts → terminate with typed error codes

**No** automatic reconnect, **no** dynamic bitrate adaptation (SDP latches a fixed bitrate; comments warn against bouncing min/max).

---

## 13. Dependencies

| Dep | Role | Constraint |
|-----|------|------------|
| **cgutman/enet** | RTSP (old), control, input | Required fork; stock crashes |
| **nanors** | RS FEC | Custom audio parity matrix |
| **OpenSSL / MbedTLS** | AES-CBC/GCM | MbedTLS has GCM tag-layout workarounds |
| **Opus** | Client-side only | Not linked here — decode in audio callback |

---

## 14. Known Limitations & Quirks

1. Not a full protocol stack — pairing/discovery are client-owned
2. Version matrix explosion (Gen 3–7 + Sunshine) — dozens of branching paths
3. Global mutable state — one session
4. GFE audio URL `0.0.0.0` trick is fragile
5. Opus channel remapping must stay host-compatible
6. Audio FEC parity matrix is hardcoded Nvidia-specific
7. HDR/colorspace on `DECODE_UNIT` are side-channel guesses, not bitstream-parsed
8. ENet RTSP × encrypted RTSP incompatibility
9. Sunshine identified by negative version quad component — convention must be preserved by clients
10. MbedTLS random noted as not thread-safe
11. Submodules must be initialized or the tree will not build

---

## 15. Improvement Opportunities (Better Protocol / Library)

### Protocol redesign
1. **Unify transport** — Replace RTSP + ENet + 3 UDP ports + legacy TCP with one modern stack (QUIC or WebRTC-style data + media).
2. **Binary capability handshake** — Versioned bitmap instead of stringly SDP `x-nv-*` folklore.
3. **Standard FEC** — RFC 5109 / FlexFEC instead of custom RS + host-specific matrices.
4. **Unified AEAD** — One scheme (e.g. ChaCha20-Poly1305) with proper KDF from pairing; stop reusing `rikey` for everything.
5. **Length-prefixed NALUs / AV1 OBUs** — Drop Annex-B reassembly burden from every client.

### Library architecture
6. **Session objects** — No globals; multi-session and thread-safe.
7. **Async-first API** — Non-blocking start, cancellable tokens, event-loop friendly.
8. **Structured errors** — Stage + port hint + recoverability.
9. **Built-in jitter buffer** — Timestamp sync instead of fixed queue depths (~15 video / 30 audio).
10. **First-class stats** — RTT, loss, FEC efficiency, decode latency histograms as a stream.

### Resilience
11. **Resume tokens** — Control-channel reconnect + IDR resync without full `/launch`.
12. **Real adaptive bitrate** — Feedback that hosts can honor.
13. **Simpler loss recovery** — Prefer reference refresh over speculative RFI queues when redesigning.

### Media
14. **Hardware-ready CSD** — Emit VideoToolbox / MediaCodec config blobs directly.
15. **Accurate HDR** — Parse SEI / AV1 metadata OBUs.
16. **Capability struct once** — Populate at handshake; eliminate version `#ifdef` spaghetti.

### Quality bar for a rewrite
- Fuzz depacketizer + FEC paths (`LC_FUZZING` exists as a starting point)
- Mock-host unit tests (today: integration against real GFE/Sunshine)
- Keep Sunshine compatibility as a first-class profile, not a negative-version hack forever

---

## 16. Critical Constants (Quick Reference)

```
Video UDP: 47998    Audio UDP: 48000    Control ENet: 47999
RTSP: 48010         Gen3 control: 47995   Gen3 first-frame: 47996

Video FEC repair: 20% (5% @ 4K older GFE)
Audio FEC: 4 data + 2 repair
First-frame / no-traffic timeout: 10 s
Audio packet duration: 5 or 10 ms @ 48 kHz
High-quality audio bitrate threshold: 15 Mbps
Launch URL Sunshine hint: "&corever=1"
```

---

## 17. Summary

`moonlight-common-c` is a mature, battle-tested implementation of NVIDIA GameStream with Sunshine extensions. It is also historically layered: multiple transports, generation-gated branches, global state, and SDP-as-protocol. For a better core, prioritize **(1)** collapsing transports, **(2)** session-scoped async API, **(3)** standard FEC/encryption, and **(4)** making loss recovery and bitrate adaptation explicit protocol features rather than host-version folklore.
