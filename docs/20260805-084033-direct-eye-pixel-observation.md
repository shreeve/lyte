# Direct eye pixel observation — framebuffer identity is not damage

**Status:** settled and commissioned 2026-08-05. This record corrects the
damage-detection premise in the frozen direct-eye plan; it does not change the
Lyte-UDP wire protocol or the Conductor's client-side presentation law.

## Finding

Mutter can render new pixels into one KMS framebuffer for minutes. During the
live failure, the primary plane remained on framebuffer `508` while YouTube
continued to advance locally. A notification forced `508 → 555 → 508`; Lyte
immediately received the newer picture and then froze again. The old direct eye
therefore observed buffer replacement, not screen damage.

Framebuffer identity remains useful only as a dmabuf import-cache key. It is
not evidence that the pixels are unchanged.

## Ruling

1. The host observes the primary scanout on a phase-stable 60 Hz beat. A late
   loop skips whole beats and preserves phase; it never catches up in a burst.
2. The GPU reads every output-significant source pixel into two independent
   32-bit hashes per 16×16 tile. At 2048×1280 the CPU reads back 80 KiB per
   beat (about 4.7 MiB/s), never the 10 MiB raw frame.
3. Equal fingerprints mean no blit, no encode, and no video frame. Changed
   fingerprints enter the existing EGL blit, native VAAPI encoder, Lyte-UDP
   packetizer, FEC, and pacing path exactly once.
4. A framebuffer-identity transition invalidates and reimports the cached
   EGLImage, then resets fingerprint history. Same-identity observations reuse
   the import so in-place compositor writes remain visible.
5. Cursor pixels remain outside the primary-screen comparison because the
   hardware cursor already travels as Lyte cursor metadata.
6. Forced IDRs and quiet-desktop keepalives continue to re-encode the retained
   VA surface independently of the observation beat. Recovery semantics and
   original capture timestamps are unchanged.
7. The old `CaptureBeatBook` is retired. Its framebuffer-flip premise made a
   normal 30 fps video look like missing 60 Hz capture beats. The explicit
   sampling cadence now owns skip truth, independent of content frame rate.

## Commissioning proof

The Linux-only shader compiled with warnings as errors and executed on pup's
Intel display GPU. A six-second standalone run made 360 observations with zero
skipped beats and zero missed grabs, while only seven pixel changes entered
VAAPI. The deterministic pup gate then passed all Host tests, warning-enforced
debug and release builds, release-image and installer verification, hermetic
linkage, kernel socket/pacing harnesses, and protected-state verification.

The first live Mac session observed 17,171 beats, encoded only 1,369 changed
images, skipped one observation beat, and missed zero grabs. Its encrypted
video, audio, input, cursor, and beacons remained live over pup's Wi-Fi. The
cleanup also removed the flip-based diagnostics that falsely classified
ordinary 30 fps content as missing 60 Hz capture beats.

Architecture ratchets require both shipping capture consumers to use
`ScreenSamplingCadence` and `EyeGL.scanoutChanged`; direct `screen.poll()`
damage gating cannot return silently.
