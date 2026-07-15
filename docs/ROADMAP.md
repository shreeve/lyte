# Roadmap

- **M0 — Scaffold** ✅ repo, GPLv3, design docs, reference summaries (misc/)
- **M1 — Pairing** ✅ LyteKit pairs with a Sunshine host: client cert generation
  (Security/CryptoKit), PIN handshake, serverinfo/applist over HTTPS — guided by
  moonlight-common-c and the misc/ summaries
- **M2 — Session** ✅ RTSP negotiation (encrypted `rtspenc://`); launch/resume/quit;
  ENet control channel with control-v2 encryption — verified live against Sunshine on pop
- **M3 — First pixels** ✅ RTP video depacketization + Reed-Solomon FEC → VideoToolbox
  (HEVC first) → AVSampleBufferDisplayLayer in a bare window — soaked 5 min at
  2048×1280@60 on pop; FEC + IDR recovery verified under 5% induced loss
- **M4 — Hands and ears** ✅ input over the encrypted control channel (keyboard,
  free + locked mouse, hi-res scroll, clipboard paste); Opus audio via RTP 4+2
  FEC → AES-CBC → system decoder → AVAudioEngine; app menu/identity/icon —
  usable end-to-end session, approved on pop
- **M5 — App shell** ✅ Lyte.app (SwiftUI, D6 window-is-the-app): connect
  empty-state with resolved Bonjour hosts + PIN pairing + launch cards,
  relaunch-reconnect, Actions commands, policy engine v1 deriving all stream
  parameters from Work/Play intent — verified live on pop
- **M5.5 — Policy engine full** the 2×2 (intent × detected network),
  telemetry-derived settings, the single quality⇄latency dial
- **M6 — Network doctor** continuous probes, culprit signatures (AWDL, host power
  save, shared channel, uplink retries), in-stream banner + fixes
- **M7 — Expert & polish** JSON profiles, per-host overrides, frame pacing, AV1,
  HDR, reconnect/resume
