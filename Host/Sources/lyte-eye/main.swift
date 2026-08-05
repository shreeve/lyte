// lyte-eye — the direct eye (docs/20260801-105800-direct-eye-plan.md, E0).
//
// Two modes:
//   lyte-eye [device] [seconds] [poll_us]           — the doorbell
//     (milestone 1): FB_ID change detection, unprivileged, output
//     line-comparable with the retired fbid-poll.c probe.
//   lyte-eye capture [--device D] [--render R] [--seconds N]
//            [--out PATH] [--qp N]                   — the full loop
//     (milestone 2): screen beat → GPU change detection → GL blit
//     RGB→NV12 into exported VAAPI surfaces → hevc_vaapi (vendored
//     libavcodec) → Annex-B file. Needs privileges (GETFB2).
//
// Swift-first is the point: libdrm/GBM/EGL/GL/libva/libavcodec all
// arrive through module maps — no .c files anywhere in the eye.

import Foundation

#if os(Linux)

let args = CommandLine.arguments
if args.count > 1 && args[1] == "capture" {
    runCapture(Array(args.dropFirst(2)))
} else {
    let device = args.count > 1 ? args[1] : "/dev/dri/card1"
    let seconds = args.count > 2 ? (Double(args[2]) ?? 15.0) : 15.0
    let intervalUs = args.count > 3 ? (UInt32(args[3]) ?? 1000) : 1000
    runDoorbell(device: device, seconds: seconds, intervalUs: intervalUs)
}

#else
FileHandle.standardError.write(
    Data("lyte-eye is Linux-only (KMS/DRM).\n".utf8))
exit(1)
#endif
