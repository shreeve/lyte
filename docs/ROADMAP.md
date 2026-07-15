# Roadmap

- **M0 — Scaffold** ✅ repo, GPLv3, design docs, reference summaries (misc/)
- **M1 — Pairing** ✅ LyteKit pairs with a Sunshine host: client cert generation
  (Security/CryptoKit), PIN handshake, serverinfo/applist over HTTPS — guided by
  moonlight-common-c and the misc/ summaries
- **M2 — Session** ✅ RTSP negotiation (encrypted `rtspenc://`); launch/resume/quit;
  ENet control channel with control-v2 encryption — verified live against Sunshine on ice
- **M3 — First pixels** RTP video depacketization + Reed-Solomon FEC → VideoToolbox
  (HEVC first) → CAMetalLayer in a bare window
- **M4 — Hands and ears** ENet control/input channel, CoreHID mouse (free + locked),
  keyboard; Opus → AudioUnit; usable end-to-end session
- **M5 — Policy engine** the 2×2 (intent × detected network), telemetry-derived
  settings, the single quality⇄latency dial
- **M6 — Network doctor** continuous probes, culprit signatures (AWDL, host power
  save, shared channel, uplink retries), in-stream banner + fixes
- **M7 — Expert & polish** JSON profiles, per-host overrides, frame pacing, AV1,
  HDR, reconnect/resume
