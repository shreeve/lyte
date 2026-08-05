# Lyte — design decisions

This living document owns product behavior and interaction decisions. Each
section says whether the decision ships today or remains direction; frozen
protocol and architecture records own the mechanics beneath it.

## D1. Two axes, one question

*Status: directional. The Work/Play choice is not exposed by the current app.*

The intended product model resolves streaming policy from **intent × network**:

- **Intent — Work or Play.** The user states what matters.
- **Network — Local or Remote.** Lyte derives this from address and measured
  path behavior; location is evidence, not a user mode.

An earlier Work/Play/Away sketch was rejected because Away confused network
location with intent. The current client connects directly to a host and keeps
its explicit controls narrow: feature consent, audio routing, and a
hardware-backed Chroma posture. A future Work/Play surface must earn its place
by driving real policy rather than exposing placeholder presets.

## D2. Policies, not presets

*Status: shipping law; the complete four-cell product surface is directional.*

A policy cell stores goals, never a bag of encoder numbers:

| Cell | Optimizes for | Target behavior |
|---|---|---|
| Local·Work | static-image fidelity | native geometry, text fidelity, free mouse, best proven chroma |
| Local·Play | motion latency | fullscreen, locked mouse, latency-first pacing |
| Remote·Work | resilient legibility | bounded geometry, adaptive rate, reconnect |
| Remote·Play | playable latency | conservative start and latency-first adaptation |

The shipping system already follows the underlying rule: congestion control,
repair, pacing, and reserve come from live evidence rather than user-entered
numbers. The Conductor derives playout reserve from holes and clean beats;
cushion is not a setting and is never stored as milliseconds or frames.
Encryption is always on and therefore never varies by policy cell.

## D3. Declarations are not tuning knobs

*Status: shipping.*

- Users may declare intent or a real hardware posture; Lyte derives bitrate,
  pacing, repair, and reserve from declarations plus evidence.
- Diagnostic surfaces expose derived values and their evidence, but the
  primary product does not offer an encoder-knob farm.
- Chroma is a connect-time session posture. Changing it reconnects cleanly;
  it is not a mid-stream encoder control.
- Corrected network and playout disturbances remain diagnostic. User-facing
  warnings are reserved for terminal playback misses or failures.

## D4. Network diagnosis is a product responsibility

*Status: partially shipping.*

The app ships path/session telemetry, failure-only health reporting, reconnect
policy, and a narrowly authenticated macOS helper for AWDL posture. A complete
Network Doctor—continuous gateway attribution, host-side inspection, and
guided remediation—is not yet a finished subsystem.

Known signatures worth preserving for that future work:

| Symptom | Likely cause | Possible response |
|---|---|---|
| client gateway spikes while AWDL is active | shared Apple radio airtime | helper-managed AWDL posture |
| host gateway spikes with power save enabled | host Wi-Fi power saving | disable power saving or recommend Ethernet |
| both endpoints share one wireless channel | double airtime | reduce rate or recommend wiring one endpoint |
| host transmit rate trails receive rate | uplink retries or placement | reduce rate and surface placement guidance |

Diagnosis must be evidence-backed. Lyte must not present a generic network
warning when its own repair and Conductor successfully absorbed the event.

## D5. Swift throughout, MIT, independently owned

*Status: shipping architecture.*

- All Lyte-authored code is MIT-licensed. Third-party leaves retain their
  upstream licenses and notices.
- `LyteWire` owns sans-IO protocol contracts; `LyteCore` owns shared sans-IO
  policy; `LyteIO` owns shared OS adapters.
- `LyteClientCore` and `LyteClientSession` own pure client policy.
  `HostCore`, `HostSession`, and `HostAudio` own pure host policy.
  `LyteTransport` and `HostWire` execute those decisions at role boundaries.
- The product speaks only Lyte-UDP. No GameStream, Sunshine, or Moonlight
  source remains in the shipping system.
- The macOS shell uses SwiftUI/AppKit, VideoToolbox through
  `AVSampleBufferDisplayLayer`, AVAudioEngine plus pinned Opus,
  Network.framework, and a narrowly authenticated ServiceManagement helper.
- The Linux host uses KMS/DRM capture, GPU color conversion, native VAAPI HEVC,
  PipeWire audio, uinput, and a narrow UDP syscall leaf.
- Swift Crypto is the only external Swift dependency of `LyteWire` and remains
  confined to its crypto leaf.

## D6. The window is the app

*Status: the core interaction ships; automatic resume-on-launch remains
directional.*

There is no separate launcher or hosts application. One window owns one
connection and moves through connect, pair, stream, failure, and reconnect
states.

- **Launch → connection window.** A new window discovers Lyte hosts. An
  unpaired host opens the PIN sheet; a paired host connects directly to its
  desktop. There is no intervening host-app catalog.
- **The empty state is the gate.** Discovery, pairing, Local Network recovery,
  and retry all live inside the same window that becomes the stream.
- **The control strip is a whisper.** It auto-hides around the stream and owns
  only live actions and state. Derived transport and Conductor books stay in
  the optional diagnostic surface.
- **Menus are a complete fallback.** The Actions menu exposes the same model
  verbs as the strip, including audio, consent, Chroma, transfer, reconnect,
  and display actions.
- **Window close means disconnect.** Closing the window performs typed session
  teardown and releases its platform resources.
- **Future relaunch behavior.** Remembering and automatically resuming prior
  windows is product direction, not current shipping behavior.

## Origin

Lyte began with a poorly behaving Sunshine/Moonlight session on a hybrid-GPU
Linux laptop and a Mac client. The investigation exposed four durable product
inputs: preserve native geometry, make hardware selection truthful, treat
network jitter as measured evidence, and keep cursor ownership explicit. Lyte
now owns both endpoints and its protocol; the origin explains these decisions
but is not an architectural dependency.
