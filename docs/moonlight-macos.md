# moonlight-macos — App & Platform Analysis

> **GameStream-era reference (annotated 2026-07-30).** The client
> lineage this study served was deleted at the H2 exit (2026-07-22);
> Lyte speaks only Lyte-UDP. Kept for the macOS platform knowledge
> (VideoToolbox, AppKit shell, display/input tricks) that informed the
> Lyte client; the protocol-integration halves are archaeology.

Deep technical analysis of `moonlight-macos/`, a native AppKit Moonlight client (fork of moonlight-ios, **not** Mac Catalyst). Goal: understand architecture, moonlight-common integration, and **macOS-specific tricks** well enough to design a **better macOS client**.

**Related:** [`moonlight-common-c.md`](moonlight-common-c.md) (client protocol library)

---

## 1. Scope & Role

**What this app is:** a sandboxed macOS GameStream/Sunshine client that discovers hosts, pairs over HTTPS, launches apps, and streams video/audio/input using `libmoonlight-common.a`.

**What it owns (vs common-c):**
- Bonjour discovery (`_nvstream._tcp`)
- Pairing crypto + cert pinning
- HTTP(S) `/serverinfo`, `/applist`, `/launch`, `/resume`, quit, WoL
- VideoToolbox display (`AVSampleBufferDisplayLayer`) + CVDisplayLink pacing
- Opus → AudioQueue
- Keyboard/mouse capture and custom IOKit HID controllers
- AppKit UI (hosts → apps → stream) + SwiftUI settings

**Checkout notes:** `moonlight-common` submodule and `xcframeworks/` binaries may be absent until recursive clone + dependency zip install. README claims macOS 10.14+; Xcode project sets `MACOSX_DEPLOYMENT_TARGET = 11.0`.

---

## 2. Directory Structure

```
moonlight-macos/
├── Moonlight.xcodeproj/
├── Moonlight.entitlements
├── README.md
├── xcframeworks/                 # FFmpeg, Opus, SDL2 (gitignored; download zip)
├── moonlight-common/
│   └── moonlight-common.xcodeproj/   # builds libmoonlight-common.a
└── Limelight/
    ├── Stream/                   # Connection, StreamManager, VideoDecoderRenderer
    ├── Network/                  # HTTP, mDNS, pairing, discovery, WoL
    ├── Input/                    # ControllerSupport, HIDSupport (macOS), StreamView (iOS)
    ├── Crypto/                   # OpenSSL pairing / mkcert
    ├── Database/                 # Core Data hosts/apps/legacy settings
    ├── Utility/
    ├── OSPortabilityDefs.h       # UIKit→AppKit aliases
    ├── Moonlight-Bridging-Header.h
    ├── Limelight.xcdatamodeld/
    └── macOS/
        ├── AppDelegateForAppKit.*
        ├── Base.lproj/Main.storyboard
        ├── ViewControllers/      # Hosts, Apps, Stream, Settings (Swift), About
        ├── Views/                # Collection views, StreamViewMac
        ├── Helpers/              # NSWindow+, ControllerNavigation, MASPreferences
        ├── Assets.xcassets/
        └── Supporting Files/     # Info.plist, main.m
```

App box art is fetched at runtime (`AppAssetManager`), not shipped in Artwork.

---

## 3. App Architecture & Navigation

```
main.m → NSApplication → AppDelegateForAppKit
  └── MainWindowController
        └── ContainerViewController
              └── HostsViewController          (default)
                    ──slide──► AppsViewController
                                 ──streamSegue──► StreamViewController (own window)
```

| Layer | Class | Role |
|-------|-------|------|
| App | `AppDelegateForAppKit` | Main window, theme, prefs, about |
| Shell | `ContainerViewController` | Toolbar, search, hosts root |
| Hosts | `HostsViewController` | mDNS + discovery, pair, WoL, host grid |
| Apps | `AppsViewController` | App list, box art, launch/quit/resume |
| Stream | `StreamViewController` | Capture, stream window, connection callbacks |
| View | `StreamViewMac` | Black layer, spinner, key-equivalent routing |

**Stream lifecycle:** `prepareForStreaming` builds `StreamConfiguration` → `StreamManager` on `NSOperationQueue` → on success optionally auto-fullscreen + `captureMouse`.

**macOS extras:**
- **`ControllerNavigation`** — `GCController` d-pad/A/B drives UI via `NSResponder (Moonlight) controllerEvent:` (navigate grids with a pad outside streaming)
- Toolbar: back / add-host enablement + `NSSearchToolbarItem`

---

## 4. moonlight-common Integration

### Build
Static library from limelight-common-c submodule + bundled ENet + nanors. Public C API: `Limelight.h` (see `moonlight-common-c.md`).

### Call path
UI never calls common directly. Pattern:

1. **`StreamManager`** — HTTP launch/resume via `HttpManager`; then creates `VideoDecoderRenderer` + `Connection`
2. **`Connection` (`NSOperation`)** — fills C structs, installs callbacks, blocks on `LiStartConnection`
3. Callbacks fan out to renderer / audio / `StreamViewController` / HID rumble

```c
// Connection.m (conceptual)
LiInitializeVideoCallbacks(&_drCallbacks);
_drCallbacks.capabilities = CAPABILITY_PULL_RENDERER;  // macOS pulls frames

LiInitializeAudioCallbacks(&_arCallbacks);
_arCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT |
                            CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

LiStartConnection(&_serverInfo, &_streamConfig, &_clCallbacks,
                  &_drCallbacks, &_arCallbacks, NULL, 0, NULL, 0);
```

### Stream config highlights
- Random 16-byte `riKey` + `riKeyId` → AES IV for remote input (must match `/launch`)
- HEVC gated by `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`; HDR forces HEVC
- HEVC bitrate multiplier ≈ 75% of configured bitrate
- VPN → `STREAM_CFG_REMOTE`, smaller `packetSize` (1024 vs ~1392)
- **`CAPABILITY_PULL_RENDERER`** — used because push+RFI with HEVC was problematic on this port

### Teardown
`LiInterruptConnection()` then async `LiStopConnection()` under `initLock` to avoid deadlocks with common’s internal threads.

### `ConnectionHelper`
Thin wrapper: `getAppListForHost…` with 5× retry.

---

## 5. Video Pipeline (macOS)

### Design: AVSampleBufferDisplayLayer (not Metal, not app-owned VTDecompressionSession)

Hardware decode is delegated to **`AVSampleBufferDisplayLayer`** (VideoToolbox under the hood).

```
moonlight-common DECODE_UNIT
  → DrSubmitDecodeUnit concatenates PICDATA
  → VideoDecoderRenderer:
       VPS/SPS/PPS → CMVideoFormatDescription (H.264 / HEVC)
       Annex-B → length-prefixed AVCC → CMSampleBuffer
       attachments: DisplayImmediately, sync flags
  → [displayLayer enqueueSampleBuffer:]
```

Layer host: `RendererLayerContainer` — `AVSampleBufferDisplayLayer` + `wantsLayer = YES`.

### Frame pacing — CVDisplayLink + pull renderer

```c
// VideoDecoderRenderer.m — displayLinkCallback
while (LiPollNextVideoFrame(&handle, &du)) {
    LiCompleteVideoFrame(handle, DrSubmitDecodeUnit(du));
    // If display refresh ≈ stream FPS, leave 1 frame queued for jitter
    if (displayRefreshRate >= frameRate * 0.9f && LiGetPendingVideoFrames() == 1)
        break;
}
```

**Tricks:**
- Display link created for the **stream window’s screen** (`NSScreenNumber` → `CGDirectDisplayID`)
- If refresh drops below 90% of stream FPS (thermal/battery), pacing effectively disabled
- Settings UI has “Lowest Latency” vs “Smoothest Video” but it is **not wired** (TODO in `Settings.swift`)

### HDR
- Launch URL adds HDR capability query params when enabled
- `_streamConfig.enableHdr` passed through
- **P3 color space attachment is commented out** — incomplete

### Recovery
If `displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed`, recreate layer on main thread and return `DR_NEED_IDR`.

### Gaps vs a better pipeline
- Main-thread `dispatch_sync` on layer recreate
- Per-frame memcpy / CMBlockBuffer allocation (no IOSurface zero-copy path)
- No AV1 UI path yet (common supports formats; app codec picker is H.264/HEVC)
- No Metal present path / custom compositor

---

## 6. Audio Pipeline

Implemented as static functions in **`Connection.m`** (shared iOS DNA).

| Step | Tech |
|------|------|
| Decode | `opus_multistream_decoder_create` (Opus.xcframework) |
| Output | Core Audio **AudioQueue**, 4 buffers, 16-bit PCM |
| Layout | Stereo / quad / 5.1 / 7.1 mapping; 7.1 swaps SL/SR for AudioUnit order |
| Buffering | **~80 ms circular buffer** between decode and play (`CIRCULAR_BUFFER_DURATION`) — iPod-touch heritage; still on macOS |
| Volume | Per-host multiplier via `SettingsClass` + notification |

`AVAudioSession` path is `#if TARGET_OS_IPHONE` only.

**Quirk:** stream prep hardcodes **`AUDIO_CONFIGURATION_STEREO`** even though decode supports surround — UI does not expose 5.1/7.1.

---

## 7. Input Handling — macOS Tricks

### Dual drivers (per-host setting)

| Driver | Class | When |
|--------|-------|------|
| **HID** (default) | `HIDSupport` | Custom IOHIDManager — signature macOS contribution |
| **MFi** | `ControllerSupport` | GameController.framework |

### Mouse capture (`StreamViewController`)

```objc
- (void)captureMouse {
    CGAssociateMouseAndMouseCursorPosition(NO);  // decouple cursor from movement
    [NSCursor hide];
    CGWarpMouseCursorPosition(cursorPoint);      // warp to stream center
    self.hidSupport.shouldSendInputEvents = YES;
    self.view.window.acceptsMouseMovedEvents = YES;
    [self disallowDisplaySleep];                 // IOPMAssertion
}
```

| Trick | Detail |
|-------|--------|
| **Release combo** | Control+Option together (`modifierFlags == 786721`) |
| **Uncapture** | Re-associate cursor, show cursor, allow display sleep |
| **Menu passthrough** | `StreamViewMac performKeyEquivalent:` intercepts Cmd+1, Cmd+`, Cmd+H, Cmd+F, Ctrl+Cmd+F, Ctrl+Opt+W, Ctrl+Shift+W, Cmd+W — releases modifiers, does **not** send to host |
| **Quit shortcuts** | Ctrl+Shift+W quit+disconnect; Ctrl+Opt+W disconnect only (README) |
| **Menu disable** | Quit menu item disabled while captured |
| **Fullscreen re-capture** | Observers re-run capture after space/fullscreen changes |
| **Space awareness** | `CGWindowListCopyWindowInfo` to detect if stream window is on current Space |

Relative mouse: `NSEvent` deltas → `LiSendMouseMoveEvent`; optional GCMouse path (macOS 11+) with delta accumulation. Precise scroll → `LiSendHighResScrollEvent` / `LiSendHighResHScrollEvent`.

**Known gap:** side mouse buttons broken on NSEvent path; GCMouse `auxiliaryButtons` incomplete.

### Keyboard (`HIDSupport`)
- Carbon `kVK_*` → Windows VK table (~80 keys)
- `flagsChanged:` sends left/right modifier VKs (0xA0–0xA5, Win 0x5B/0x5C)
- Events: `LiSendKeyboardEvent(0x8000 | vk, action, modifiers)`
- `releaseAllModifierKeys` on uncapture / menu shortcuts

### Custom HID controller stack (`HIDSupport.m`, ~1850 lines)

Direct IOKit for devices MFi handled poorly on older macOS:

| Device | Detection | Notes |
|--------|-----------|-------|
| Xbox BT | VID 0x045E, PID 0x02FD / 0x0B13 | Value + report callbacks |
| Xbox “King Kong” | PID 0x02e0 | Different axis map |
| PS4 | VID 0x054C | USB + BT report IDs |
| PS5 DualSense | PID 0x0CE6 | BT CRC (SDL_crc32 reimplemented locally) |
| Switch Pro | VID 0x057E PID 0x2009 | Subcommands, rumble encoding, EnableVibration |

**Rumble:** dedicated `rumbleQueue` + semaphores; vendor output reports; Switch needs periodic rumble refresh.

**Limitation:** `getFirstDevice` → **one controller only** (README confirms). Xbox wired unsupported; Switch Pro wireless-only; DualSense rumble differs wired vs BT.

### MFi path
`GCController` extendedGamepad; Start+Select → Guide chord debounce; CoreHaptics rumble when MFi selected. Workaround for PS camera overshoot: switch driver to MFi.

---

## 8. Host Discovery & Pairing

### mDNS
`MDNSManager` → `NSNetServiceBrowser` for **`_nvstream._tcp`**.
- Re-query every **5 s** while hosts screen visible
- Prefer IPv4; IPv6 link-local with scope ID
- STUN: `LiFindExternalAddressIP4("stun.moonlight-stream.org", 3478, …)` when not on VPN
- Filter 6to4 / Teredo globals

### HTTP(S) GameStream

| Port | Use |
|------|-----|
| 47989 HTTP | Pairing, unpaired serverinfo |
| 47984 HTTPS | Applist, launch, resume, pinned-cert serverinfo |

`HttpManager`: ephemeral `NSURLSession` + TLS delegate for **cert pinning**. Trust failure → HTTP fallback to re-pair.

**Fixed `uniqueId`:** `"0123456789ABCDEF"` — intentional so any Moonlight client can quit games started elsewhere (security/UX tradeoff).

### Pairing (`PairManager`) — 5 stages
1. Generate 4-digit PIN; salt (16 random + PIN bytes)
2. `/pair?phrase=getservercert` → server cert
3. AES-128-ECB challenge (SHA1 key gen ≤6, SHA256 gen ≥7)
4. Verify server signature + PIN hash
5. Client pairing secret + `/pair?phrase=pairchallenge` over HTTPS

Client cert/key: `CryptoManager` + OpenSSL `mkcert`.

### Discovery orchestration
`DiscoveryManager` + per-host `DiscoveryWorker` polling serverinfo; manual IP add; `WakeOnLanManager` from stored MAC.

---

## 9. Settings Model

### Dual persistence (rewrite pain point)

**A. Per-host Swift settings (primary UI)**  
`UserDefaults` key `{hostUUID}-moonlightSettings` — encoded `Settings` plist.  
`SettingsModel` (@Published): resolution (720–4K + custom), FPS (30–144 + custom), bitrate 0.5–150 Mbps, H.264/H.265 + HDR, frame pacing (**stored, unused**), audio-on-PC, volume, multi-controller Single/Auto, auto fullscreen, rumble, controller/mouse driver HID vs MFi, artwork size / dim-on-hover.

**B. Legacy Core Data `Settings`**  
Bridge at stream time: `SettingsClass loadMoonlightSettingsFor:` → `DataManager saveSettings…` → `TemporarySettings` consumed by `StreamViewController`.

**C. Legacy MASPreferences**  
`GeneralPrefsPaneVC` + XIB still present; overlaps SwiftUI prefs.

SwiftUI hosted via `SettingsHostingController` / `SettingsWindowObjCBridge`.

---

## 10. macOS UI/UX Tricks

| Feature | Implementation |
|---------|----------------|
| Native AppKit shell | Storyboard + XIBs + `NSCollectionView` grids |
| SwiftUI settings overlay | Hosting controller bridge |
| Frame autosave | Main, prefs, about, stream windows |
| First-run centering | `NSWindow moonlight_centerWindowOnFirstRunWithSize:` |
| Dark stream chrome | `NSAppearanceNameVibrantDark` on stream window |
| Theme | System / Light / Dark via AppDelegate |
| Fullscreen | `toggleFullScreen:` + mouse re-capture |
| Display sleep block | `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep)` |
| App grid scale | Cmd+/Cmd− → `itemScale` in UserDefaults (`1.125^n`) |
| Gamepad UI nav | `ControllerNavigation` outside stream |
| Tabbing | `NSWindowTabbingModeDisallowed` on stream window |
| Search | `NSSearchToolbarItem` from container VC |

**Not present (opportunities):** Game Mode / `NSProcessInfo` QoS APIs, menu-bar status item, Stage Manager–aware capture, ScreenCaptureKit (N/A — receive-only client).

---

## 11. Entitlements & Sandbox

`Moonlight.entitlements`:
```xml
com.apple.security.app-sandbox = true
com.apple.security.device.usb = true      <!-- HID controllers -->
com.apple.security.network.client = true
com.apple.security.network.server = true  <!-- UDP bind / common sockets -->
```

`Info.plist`:
- Category: games
- **`NSAllowsArbitraryLoads = true`** — LAN HTTP without per-domain ATS exceptions
- Deployment: project 11.0 vs README 10.14 mismatch

---

## 12. Third-Party Dependencies

| Dep | Role | Notes |
|-----|------|-------|
| moonlight-common-c | Session protocol | Static lib |
| Opus.xcframework | Audio decode | Required |
| OpenSSL (SPM) | Pairing / certs | Required |
| FFmpeg.xcframework | Linked | **No direct Limelight references** — likely legacy/dead |
| SDL2.xcframework | Embedded | Effectively only CRC32 for PS BT — **bundle bloat** |
| GameController | MFi + GCMouse + UI nav | System |
| VideoToolbox / AVFoundation | Decode/display | System |
| IOKit HID | Custom controllers | System |
| libxml2 | HTTP XML | System |
| MASPreferences / Functional.m | Vendored prefs helpers | Legacy |

---

## 13. Threading & Performance

| Context | Work |
|---------|------|
| Main | UI, renderer start, ASBDL enqueue, mouse capture |
| StreamManager op | Sync HTTP launch; dispatch Connection setup |
| Connection op | **Blocks in `LiStartConnection`** |
| Global queues | Applist, pair, discovery, WoL, terminate |
| HID rumbleQueue | Controller output loop |
| AudioQueue callback | Circular-buffer drain |
| CVDisplayLink | `LiPollNextVideoFrame` + submit |

Sync: `initLock` around start/stop; audio `__sync_synchronize()` barriers; `@synchronized` on controller state.

**Perf character:** vsync-aligned pull with 1-frame queue; not zero-copy; SPS/PPS reparse on parameter-set change.

---

## 14. Known Limitations & Quirks

From README + code:

1. HID: single gamepad only
2. Xbox: BT only (no wired)
3. Switch Pro: wireless only
4. Side mouse buttons broken
5. Some PS pads: FPS camera overshoot → switch to MFi
6. NVIDIA-side rumble sometimes dies until host reboot
7. Frame pacing setting non-functional
8. HDR P3 incomplete
9. Surround decodeable but forced stereo in UI
10. Deployment target docs vs project mismatch
11. iOS DNA in shared files (`StreamView` touch, AudioQueue comments)
12. Fixed Moonlight uniqueId for all installs
13. GCMouse display-link batching mostly commented out
14. SDL2/FFmpeg likely unnecessary in app bundle

---

## 15. Improvement Opportunities (Better macOS Client)

### Video
1. Wire frame-pacing setting to pending-frame threshold / display-link behavior
2. VTDecompressionSession → IOSurface → Metal/`CAMetalLayer` (or keep ASBDL but off main-thread recreate)
3. Finish HDR (P3/HLG attachments, EDID-aware path)
4. AV1 when host+VT support is solid
5. Match host FPS to ProMotion / 120–165 Hz displays explicitly

### Audio
1. Expose 5.1/7.1 in UI; consider spatial audio
2. Shrink 80 ms buffer on macOS; adapt from underrun stats
3. Evaluate HAL output for lower latency vs AudioQueue

### Input
1. Unified input protocol behind HID + MFi backends
2. Multi-controller HID with player-index UI
3. Robust raw mouse (CGEvent tap / IOHID) including side buttons
4. Keyboard layout awareness beyond US kVK table
5. Split the 1850-line `HIDSupport` monolith into per-vendor modules
6. Optional relative mode without cursor warp

### Networking / session
1. Async `URLSession` + structured concurrency instead of sync semaphore HTTP
2. Optional per-host uniqueId
3. Sunshine-first feature detection (not only GFE XML assumptions)
4. Richer reconnect UX using common improvements from `moonlight-common-c.md`

### Architecture
1. **One settings source of truth** — kill Core Data ↔ UserDefaults dual bridge
2. Swift-first stream session with injectable settings
3. `async/await` replacing nested `NSOperation` / `dispatch_async`
4. Clean `#if TARGET_OS_MAC` separation from iOS touch paths

### macOS polish
1. Game Mode / process QoS during stream
2. Menu bar status item (disconnect / mute / bitrate)
3. Multi-display: pick which screen to fullscreen/capture
4. Drop unused SDL2/FFmpeg from the bundle
5. Latency overlay: decode time, queue depth, RTT from `LiGetRTP*Stats` / `LiGetEstimatedRttInfo`

### Preserve from this port
The **IOKit HID knowledge**, **mouse capture/warp UX**, and **native AppKit shell** are the valuable macOS-specific assets. A rewrite should extract that knowledge into a modern input module rather than rewriting it from scratch against MFi alone.

---

## 16. Limelight.h Surface Used by the App

```
LiStartConnection / LiStopConnection / LiInterruptConnection
LiInitializeServerInformation / StreamConfiguration / *Callbacks
LiPollNextVideoFrame / LiCompleteVideoFrame / LiGetPendingVideoFrames
CAPABILITY_PULL_RENDERER
DR_OK / DR_NEED_IDR
BUFFER_TYPE_VPS|SPS|PPS|PICDATA
LiSendKeyboardEvent / LiSendMouseMoveEvent / LiSendMouseButtonEvent
LiSendScrollEvent / LiSendHighResScrollEvent / LiSendHScrollEvent
LiSendMultiControllerEvent
LiFindExternalAddressIP4
LiGetStageName
```

---

## 17. System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  AppKit: Hosts → Apps → StreamViewController                │
│  Settings (SwiftUI/UserDefaults) ⇄ SettingsClass ↔ Core Data│
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTP 47989 / HTTPS 47984
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  StreamManager → Connection (NSOperation)                   │
│    LiStartConnection + callbacks                            │
└──────┬───────────────────────────────┬──────────────────────┘
       │                               │
       ▼                               ▼
┌──────────────────┐          ┌─────────────────────────────┐
│ VideoDecoder     │          │ Opus → AudioQueue           │
│ AVSampleBuffer   │          │ (+ 80 ms circular buffer)   │
│ + CVDisplayLink  │          └─────────────────────────────┘
│ LiPollNextFrame  │
└────────▲─────────┘
         │
┌────────┴─────────┐          ┌─────────────────────────────┐
│ moonlight-common │◄─LiSend─│ HIDSupport / ControllerSupport│
│ (ENet + FEC)     │         │ kVK map, mouse warp, IOHID   │
└──────────────────┘          └─────────────────────────────┘
```

---

## 18. Summary

`moonlight-macos` is a capable native receiver whose strengths are **IOKit HID**, **cursor capture UX**, and an **AppKit host/app browser**. Its debt is **iOS-origin streaming glue**, **dual settings systems**, **unwired frame pacing**, **stereo-only UI**, and a **monolithic HID driver**. A better macOS client should keep the HID/capture learnings, modernize video/audio for low latency, unify config and async networking, and treat Sunshine + high-refresh displays as first-class—not afterthoughts bolted onto a GFE/iOS fork.
