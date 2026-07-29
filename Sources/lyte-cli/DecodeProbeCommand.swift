// decode-probe (H4 V-2): an Annex-B HEVC file through the EXACT
// production render construction — AnnexBAccessUnits → DecodeUnit →
// VideoRenderFactory (the same CMSampleBuffer assembly every wire frame
// rides) — then two kinds of eyes:
//
//   1. the VideoReadbackTap (VTDecompressionSession): which decoder
//      engaged (hardware asserted, not assumed), what pixel format
//      comes out, and — with --dump — the decoded planes on disk for
//      offline gate math (chroma integrity, color truth);
//   2. with --snapshot, the real glass: an AVSampleBufferDisplayLayer
//      in a real window (the wire-view construction), screenshotted
//      after the last frame — what Core Animation actually composites.
//
// Offline by construction: no socket, no session, no host. This is the
// §7 corpus harness's client half growing in place (V-3 inherits it).

import AppKit
import ArgumentParser
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import LyteTransport
import LyteUI
import LyteWire
import UniformTypeIdentifiers
import VideoToolbox

struct DecodeProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-probe",
        abstract: "Decode an Annex-B HEVC file through the production render path (VideoRenderFactory) with a VTDecompressionSession readback — offline, no host contact.")

    @Argument(help: "Annex-B HEVC elementary stream (e.g. a V-1 probe bitstream)")
    var file: String

    @Option(name: .long, help: "Decode at most N access units (0 = all)")
    var maxFrames: Int = 0

    @Option(name: .long, help: "Readback pixel format: native (decoder's choice) | bgra (VideoToolbox converts — its own color interpretation under test)")
    var pixelFormat: String = "native"

    @Flag(name: .long, help: "Demand the hardware decoder — session creation fails loudly on a software-only path")
    var requireHardware = false

    @Option(name: .long, help: "Append every decoded frame's planes (row padding stripped) to this raw file for offline comparison")
    var dump: String?

    @Option(name: .long, help: "Render through a real AVSampleBufferDisplayLayer window and write a PNG screenshot here (the glass evidence)")
    var snapshot: String?

    @Option(name: .long, help: "Seconds to let the window settle before the screenshot")
    var snapshotDelay: Double = 1.0

    @Option(name: .long, help: "Window size as a fraction of the video's pixel size (0.5 on a 2x Retina display puts video texels 1:1 with device pixels — the resample-free glass measurement)")
    var windowScale: Double = 1.0

    func validate() throws {
        guard ["native", "bgra"].contains(pixelFormat) else {
            throw ValidationError("--pixel-format wants native|bgra, got '\(pixelFormat)'")
        }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
        var ranges = AnnexBAccessUnits.ranges(in: bytes)
        guard !ranges.isEmpty else {
            throw ValidationError("\(file): no access units (not an Annex-B HEVC stream?)")
        }
        if maxFrames > 0 { ranges = Array(ranges.prefix(maxFrames)) }
        print("probe: \(file) — \(ranges.count) access units, \(bytes.count) B")

        // The production construction, exactly: DecodeUnit → factory.
        let factory = VideoRenderFactory()
        let tap = VideoReadbackTap(
            outputPixelFormat: pixelFormat == "bgra" ? kCVPixelFormatType_32BGRA : nil,
            requireHardware: requireHardware)

        var samples: [CMSampleBuffer] = []
        var decoded = 0
        var failures = 0
        var withheld = 0
        var reportedFormat = false
        var dumpHandle: FileHandle?
        if let dump {
            FileManager.default.createFile(atPath: dump, contents: nil)
            dumpHandle = FileHandle(forWritingAtPath: dump)
        }
        defer { try? dumpHandle?.close() }

        for (i, range) in ranges.enumerated() {
            let annexB = Array(bytes[range])
            let unit = DecodeUnit(
                frameNumber: FrameNumber(rawValue: UInt32(i)),
                timestamp: HostTimestamp(microseconds: UInt64(i) * 16_667),
                isIDR: AnnexBCheck.containsIrap(annexB),
                annexB: annexB)
            guard let sample = try factory.makeSampleBuffer(from: unit) else {
                withheld += 1
                continue
            }
            samples.append(sample)

            if !reportedFormat, let format = CMSampleBufferGetFormatDescription(sample) {
                printFormatDescription(format)
                reportedFormat = true
            }
            do {
                let (buffer, _) = try tap.decode(sample)
                decoded += 1
                if decoded == 1 {
                    printDecoderEngagement(tap)
                    printPixelBuffer(buffer)
                }
                if let dumpHandle {
                    try dumpPlanes(of: buffer, to: dumpHandle)
                }
            } catch {
                failures += 1
                if failures <= 3 {
                    print("probe: frame \(i) decode FAILED — \(error)")
                }
            }
        }

        let hw: String
        switch tap.isHardwareAccelerated {
        case .some(true): hw = "hardware"
        case .some(false): hw = "SOFTWARE"
        case .none: hw = "unknown"
        }
        print("RESULT decode file=\(file) units=\(ranges.count) decoded=\(decoded) "
            + "failed=\(failures) withheld=\(withheld) decoder=\(hw)")

        if let snapshot {
            try await renderAndSnapshot(samples: samples, to: snapshot)
        }
        Foundation.exit(failures == 0 && decoded > 0 ? 0 : 1)
    }

    // MARK: - Evidence lines

    private func printFormatDescription(_ format: CMFormatDescription) {
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        func ext(_ key: CFString) -> String {
            guard let value = CMFormatDescriptionGetExtension(format, extensionKey: key) else {
                return "-"
            }
            return "\(value)"
        }
        print("probe: format '\(fourCC(CMFormatDescriptionGetMediaSubType(format)))' "
            + "\(dims.width)x\(dims.height), primaries \(ext(kCMFormatDescriptionExtension_ColorPrimaries)), "
            + "transfer \(ext(kCMFormatDescriptionExtension_TransferFunction)), "
            + "matrix \(ext(kCMFormatDescriptionExtension_YCbCrMatrix)), "
            + "fullRange \(ext(kCMFormatDescriptionExtension_FullRangeVideo))")
    }

    private func printDecoderEngagement(_ tap: VideoReadbackTap) {
        switch tap.isHardwareAccelerated {
        case .some(true): print("probe: decoder HARDWARE (session property asserted)")
        case .some(false): print("probe: decoder SOFTWARE (session property asserted)")
        case .none: print("probe: decoder engagement UNKNOWN (property unavailable)")
        }
    }

    private func printPixelBuffer(_ buffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var line = "probe: output '\(fourCC(format))' "
            + "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
        if CVPixelBufferIsPlanar(buffer) {
            let planes = CVPixelBufferGetPlaneCount(buffer)
            line += ", \(planes) planes:"
            for p in 0..<planes {
                line += " [\(p)] \(CVPixelBufferGetWidthOfPlane(buffer, p))x"
                    + "\(CVPixelBufferGetHeightOfPlane(buffer, p))"
                    + " bpr \(CVPixelBufferGetBytesPerRowOfPlane(buffer, p))"
            }
        } else {
            line += ", packed, bpr \(CVPixelBufferGetBytesPerRow(buffer))"
        }
        print(line)
        var attach = "probe: buffer attachments:"
        for (label, key) in [
            ("matrix", kCVImageBufferYCbCrMatrixKey),
            ("primaries", kCVImageBufferColorPrimariesKey),
            ("transfer", kCVImageBufferTransferFunctionKey),
        ] {
            let value = CVBufferCopyAttachment(buffer, key, nil)
            attach += " \(label) \(value.map { "\($0)" } ?? "-")"
        }
        print(attach)
    }

    // MARK: - Plane dump (row padding stripped, planes in order)

    private func dumpPlanes(of buffer: CVPixelBuffer, to handle: FileHandle) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planes = CVPixelBufferIsPlanar(buffer)
            ? (0..<CVPixelBufferGetPlaneCount(buffer)).map { p in
                (CVPixelBufferGetBaseAddressOfPlane(buffer, p),
                 CVPixelBufferGetBytesPerRowOfPlane(buffer, p),
                 CVPixelBufferGetWidthOfPlane(buffer, p),
                 CVPixelBufferGetHeightOfPlane(buffer, p),
                 planeBytesPerPixel(of: buffer, plane: p))
            }
            : [(CVPixelBufferGetBaseAddress(buffer),
                CVPixelBufferGetBytesPerRow(buffer),
                CVPixelBufferGetWidth(buffer),
                CVPixelBufferGetHeight(buffer),
                planeBytesPerPixel(of: buffer, plane: nil))]
        for (base, bytesPerRow, width, height, bytesPerPixel) in planes {
            guard let base else { continue }
            let rowBytes = min(width * bytesPerPixel, bytesPerRow)
            var out = Data(capacity: rowBytes * height)
            for row in 0..<height {
                out.append(Data(bytes: base + row * bytesPerRow, count: rowBytes))
            }
            try handle.write(contentsOf: out)
        }
    }

    /// Bytes per pixel of one plane, from the CoreVideo pixel-format
    /// description (BitsPerBlock ÷ BlockWidth). Falls back to the
    /// packing the row stride implies when the description is silent.
    private func planeBytesPerPixel(of buffer: CVPixelBuffer, plane: Int?) -> Int {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let desc = CVPixelFormatDescriptionCreateWithPixelFormatType(
            kCFAllocatorDefault, format) as? [CFString: Any] else {
            return fallbackBytesPerPixel(of: buffer, plane: plane)
        }
        var info = desc
        if let plane,
           let planeInfos = desc[kCVPixelFormatPlanes] as? [[CFString: Any]],
           plane < planeInfos.count {
            info = planeInfos[plane]
        }
        guard let bitsPerBlock = info[kCVPixelFormatBitsPerBlock] as? Int else {
            return fallbackBytesPerPixel(of: buffer, plane: plane)
        }
        let blockWidth = info[kCVPixelFormatBlockWidth] as? Int ?? 1
        return max(bitsPerBlock / 8 / blockWidth, 1)
    }

    private func fallbackBytesPerPixel(of buffer: CVPixelBuffer, plane: Int?) -> Int {
        let (bytesPerRow, width) = plane.map {
            (CVPixelBufferGetBytesPerRowOfPlane(buffer, $0),
             CVPixelBufferGetWidthOfPlane(buffer, $0))
        } ?? (CVPixelBufferGetBytesPerRow(buffer), CVPixelBufferGetWidth(buffer))
        guard width > 0 else { return 1 }
        return max(bytesPerRow / width, 1)
    }

    // MARK: - The glass leg

    @MainActor
    private func renderAndSnapshot(samples: [CMSampleBuffer], to path: String) async throws {
        guard let first = samples.first,
              let format = CMSampleBufferGetFormatDescription(first) else {
            throw ValidationError("nothing decodable to render")
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)

        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.regular)

        // The wire-view construction, verbatim: display layer inside
        // the shared layer-hosting view, samples through the renderer.
        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resize
        let renderer = displayLayer.sampleBufferRenderer
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Double(dims.width) * windowScale,
                height: Double(dims.height) * windowScale),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Lyte — decode-probe"
        window.contentView = VideoLayerView(layer: displayLayer)
        window.center()
        window.orderFrontRegardless()

        // DisplayImmediately is already attached (production posture) —
        // frames paint as fast as they enqueue; the LAST frame stays.
        for sample in samples {
            renderer.enqueue(sample)
        }
        try await Task.sleep(nanoseconds: UInt64(snapshotDelay * 1e9))
        if case .failed = renderer.status {
            print("probe: display layer FAILED — \(String(describing: renderer.error))")
        } else {
            print("probe: display layer status rendering — \(samples.count) samples enqueued")
        }

        // Window capture via screencapture(1) — CGWindowListCreateImage
        // is obsoleted at this deployment target and ScreenCaptureKit
        // wants a consent flow; the CLI tool inherits the terminal's
        // screen-recording grant, and a missing grant fails LOUDLY
        // (wallpaper-only or empty image), never silently.
        let windowID = CGWindowID(window.windowNumber)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-o", "-l", "\(windowID)", path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let source = CGImageSourceCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("probe: snapshot FAILED — screencapture exit "
                + "\(proc.terminationStatus), no readable image at \(path)")
            return
        }
        print("probe: snapshot \(image.width)x\(image.height) → \(path) "
            + "(colorspace \((image.colorSpace?.name).map { $0 as String } ?? "?"))")
        window.orderOut(nil)
    }

    private func fourCC(_ code: OSType) -> String {
        let chars = [24, 16, 8, 0].map { shift -> Character in
            let byte = UInt8((code >> shift) & 0xFF)
            return (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(chars)
    }
}
