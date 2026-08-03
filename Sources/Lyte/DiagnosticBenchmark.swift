import AppKit
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import LyteCorpus
import LyteTransport

struct DiagnosticBenchmarkSample: Codable {
    struct MotionSource: Codable {
        var samples: Int
        var width: Int
        var height: Int
        var logicalScale: Double
        var allocationWidthPoints: Int
        var allocationHeightPoints: Int
        var dimensionsExact: Bool
        var gapP50Milliseconds: Double
        var gapP95Milliseconds: Double
        var gapP99Milliseconds: Double
        var phaseDriftP99Milliseconds: Double
        var skippedSourceFrames: Int
        var pass: Bool
    }

    struct Quality: Codable {
        var elapsedSeconds: Double
        var decodedFrames: UInt64
        var referenceName: String
        var sourceWidth: Int
        var sourceHeight: Int
        var decodedWidth: Int?
        var decodedHeight: Int?
        var readbackPixelFormat: String?
        var readbackBytesPerRow: Int?
        var readbackYCbCrMatrix: String?
        var readbackColorPrimaries: String?
        var readbackTransferFunction: String?
        var psnrRDB: Double?
        var psnrGDB: Double?
        var psnrBDB: Double?
        var psnrMinDB: Double?
        var lumaSSIM: Double?
        var syntheticFrameID: UInt32?
        var phaseMatched: Bool?
        var viewportWidthPoints: Double
        var viewportHeightPoints: Double
        var viewportWidthPixels: Double
        var viewportHeightPixels: Double
        var backingScaleFactor: Double
        var fittedVideoWidthPoints: Double
        var fittedVideoHeightPoints: Double
        var displayScaleX: Double
        var displayScaleY: Double
        var error: String?
    }

    struct Video: Codable {
        var framesDecoded: UInt64
        var framesSkipped: UInt64
        var samplesDelivered: UInt64
        var samplesWithheld: UInt64
        var sampleFailures: UInt64
        var idrVerdicts: UInt64
        var idrRequests: UInt64
        var idrRetries: UInt64
    }

    struct Audio: Codable {
        var datagramsReceived: UInt64
        var packetsEmitted: UInt64
        var packetsRebuilt: UInt64
        var packetsUnrecoverable: UInt64
        var packetsPlayed: UInt64
        var plcInvocations: UInt64
        var latePacketsDropped: UInt64
        var recenterEvents: UInt64
        var packetsDroppedInRecenter: UInt64
        var starvedVerdicts: UInt64
        var targetPackets: Int
        var interArrivalStdDevMicroseconds: Double
        var playerAvailable: Bool
        var packetsFed: UInt64
        var plcPacketsFed: UInt64
        var ringDepthFrames: Int
        var underrunFrames: UInt64
        /// Every active-flow underrun frame passes AudioPcmRing's decay /
        /// silence / crossfade path; no alternate zero-fill seam exists.
        var declickProtectedUnderrunFrames: UInt64
        var decodeFailures: UInt64
        var routeChangeFailures: UInt64
        /// True while the host's 0x25 quiet announcement stands: the
        /// stillness on the wire is intentional, not a blackout.
        var hostAnnouncedQuiet: Bool
    }

    var type = "sample"
    var runID: String
    var workload: String
    var elapsedSeconds: Double
    var phase: String
    var flight: VideoFlightRecorder.Snapshot
    var frames: [VideoFlightRecorder.FrameObservation]
    var video: Video
    var audio: Audio
    var quality: Quality? = nil
    var motionSource: MotionSource? = nil
    var motionLeg: String? = nil
}

private struct DiagnosticBenchmarkEnd: Codable {
    var type = "end"
    var runID: String
    var workload: String
    var elapsedSeconds: Double
    var phase: String
    var everStreaming: Bool
    var frames: UInt64
    var failure: String?
}

@MainActor
enum DiagnosticBenchmark {
    static func run(model: ConnectionModel) async {
        let environment = ProcessInfo.processInfo.environment
        let workload = environment["LYTE_BENCHMARK_WORKLOAD"] ?? "unknown"
        guard let outputPath = environment["LYTE_BENCHMARK_JSONL"],
              let durationText = environment["LYTE_BENCHMARK_SECONDS"],
              let duration = Double(durationText),
              duration >= (workload == "handshake-only" ? 1 : 5),
              duration <= 3_600
        else { return }

        let runID = environment["LYTE_BENCHMARK_RUN_ID"] ?? UUID().uuidString
        let pidPath = environment["LYTE_BENCHMARK_PIDFILE"]
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            NSLog("lyte benchmark: cannot open %@", outputPath)
            NSApp.terminate(nil)
            return
        }
        if let pidPath {
            try? "\(ProcessInfo.processInfo.processIdentifier) \(runID)\n"
                .write(toFile: pidPath, atomically: true, encoding: .utf8)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let started = ContinuousClock.now
        var lastOrdinal: UInt64 = 0
        var everStreaming = false
        let qualityProbeAllowed =
            environment["LYTE_BENCHMARK_QUALITY_PROBE"] != "0"
        let qualityProbe = DiagnosticQualityProbe(
            environment: environment,
            enabled: qualityProbeAllowed
                && (workload == "motion" || workload == "quality-static"))
        let motionSource: DiagnosticBenchmarkSample.MotionSource? = {
            guard let path = environment["LYTE_BENCHMARK_MOTION_SOURCE_SUMMARY"],
                  let data = FileManager.default.contents(atPath: path)
            else { return nil }
            return try? JSONDecoder().decode(
                DiagnosticBenchmarkSample.MotionSource.self, from: data)
        }()

        while true {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                try? handle.close()
                return
            }
            let elapsed = started.duration(to: .now).seconds
            var sample = model.diagnosticBenchmarkSample(
                runID: runID,
                workload: workload,
                elapsedSeconds: elapsed,
                afterOrdinal: lastOrdinal)
            sample.quality = await qualityProbe.capture(
                renderer: model.displayLayer.sampleBufferRenderer,
                elapsedSeconds: elapsed,
                decodedFrames: sample.video.framesDecoded)
            sample.motionSource = motionSource
            sample.motionLeg = environment["LYTE_BENCHMARK_MOTION_LEG"]
            if let newest = sample.frames.last?.ordinal {
                lastOrdinal = newest
            }
            everStreaming = everStreaming || sample.phase == "streaming"
            if let data = try? encoder.encode(sample) {
                handle.write(data)
                handle.write(Data([0x0a]))
                try? handle.synchronize()
            }
            if elapsed >= duration { break }
        }

        let final = model.diagnosticBenchmarkSample(
            runID: runID,
            workload: workload,
            elapsedSeconds: started.duration(to: .now).seconds,
            afterOrdinal: lastOrdinal)
        let failure: String?
        if case .failed(let reason) = model.phase {
            failure = reason
        } else {
            failure = nil
        }
        let end = DiagnosticBenchmarkEnd(
            runID: runID,
            workload: workload,
            elapsedSeconds: final.elapsedSeconds,
            phase: final.phase,
            everStreaming: everStreaming,
            frames: final.flight.frames,
            failure: failure)
        if let data = try? encoder.encode(end) {
            handle.write(data)
            handle.write(Data([0x0a]))
        }
        try? handle.synchronize()
        try? handle.close()
        model.disconnect()
        NSApp.terminate(nil)
    }
}

@MainActor
private final class DiagnosticQualityProbe {
    private struct ProcessedFrame: Sendable {
        var frame: VideoQualityReadback.Frame? = nil
        var score: VideoQualityReadback.Score? = nil
        var syntheticFrameID: UInt32? = nil
        var phaseMatched: Bool? = nil
        var error: String? = nil
    }

    private let enabled: Bool
    private let referenceName: String
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let reference: [UInt8]?
    private let setupError: String?
    private let readbackPath: String?
    private let syntheticMotion: Bool
    private let syntheticReference: SyntheticMotionReference?
    private var wroteReadback = false

    init(environment: [String: String], enabled: Bool) {
        self.enabled = enabled
        referenceName = environment["LYTE_BENCHMARK_REFERENCE_NAME"] ?? "unknown"
        readbackPath = environment["LYTE_BENCHMARK_READBACK_RAW"]
        syntheticMotion =
            environment["LYTE_BENCHMARK_SYNTHETIC_MOTION"] == "1"
        sourceWidth = Int(environment["LYTE_BENCHMARK_REFERENCE_WIDTH"] ?? "") ?? 0
        sourceHeight = Int(environment["LYTE_BENCHMARK_REFERENCE_HEIGHT"] ?? "") ?? 0
        syntheticReference = syntheticMotion && sourceWidth > 0 && sourceHeight > 0
            ? SyntheticMotionReference(
                width: sourceWidth, height: sourceHeight)
            : nil
        if !enabled {
            reference = nil
            setupError = nil
        } else if syntheticMotion, sourceWidth > 0, sourceHeight > 0 {
            reference = nil
            setupError = nil
        } else if let path = environment["LYTE_BENCHMARK_REFERENCE_RAW"],
                  sourceWidth > 0, sourceHeight > 0 {
            do {
                let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
                let expected = sourceWidth * sourceHeight * 4
                if bytes.count == expected {
                    reference = bytes
                    setupError = nil
                } else {
                    reference = nil
                    setupError = "reference_size_\(bytes.count)_expected_\(expected)"
                }
            } catch {
                reference = nil
                setupError = "reference_read_failed_\(error)"
            }
        } else {
            reference = nil
            setupError = "missing_reference_configuration"
        }
    }

    func capture(
        renderer: AVSampleBufferVideoRenderer,
        elapsedSeconds: Double,
        decodedFrames: UInt64
    ) async -> DiagnosticBenchmarkSample.Quality? {
        guard enabled else { return nil }
        let geometry = Self.geometry(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight)
        guard setupError == nil else {
            return observation(
                elapsedSeconds: elapsedSeconds,
                decodedFrames: decodedFrames,
                geometry: geometry,
                error: setupError ?? "reference_unavailable")
        }
        guard let pixelBuffer = renderer.displayedPixelBuffer() else {
            return observation(
                elapsedSeconds: elapsedSeconds,
                decodedFrames: decodedFrames,
                geometry: geometry,
                error: "no_displayed_pixel_buffer")
        }
        let frame: VideoQualityReadback.Frame
        do {
            frame = try VideoQualityReadback.read(pixelBuffer)
        } catch {
            return observation(
                elapsedSeconds: elapsedSeconds,
                decodedFrames: decodedFrames,
                geometry: geometry,
                decodedWidth: CVPixelBufferGetWidth(pixelBuffer),
                decodedHeight: CVPixelBufferGetHeight(pixelBuffer),
                error: String(describing: error))
        }
        let pendingReadbackPath = wroteReadback ? nil : readbackPath
        if pendingReadbackPath != nil { wroteReadback = true }
        let syntheticMotion = self.syntheticMotion
        let syntheticReference = self.syntheticReference
        let reference = self.reference
        let sourceWidth = self.sourceWidth
        let sourceHeight = self.sourceHeight
        let processed = await Task.detached(priority: .utility) {
            do {
                if let pendingReadbackPath {
                    try Data(frame.bgra).write(
                        to: URL(fileURLWithPath: pendingReadbackPath),
                        options: .atomic)
                }
                let dynamicReference: [UInt8]
                let syntheticFrameID: UInt32?
                if syntheticMotion {
                    guard let source = syntheticReference else {
                        return ProcessedFrame(
                            error: "synthetic_reference_unavailable")
                    }
                    guard let marker = source.marker(in: frame.bgra) else {
                        return ProcessedFrame(
                            frame: frame,
                            error: "synthetic_frame_marker_invalid")
                    }
                    syntheticFrameID = marker
                    dynamicReference = source.frame(marker)
                } else {
                    guard let reference else {
                        return ProcessedFrame(
                            error: "reference_unavailable")
                    }
                    syntheticFrameID = nil
                    dynamicReference = reference
                }
                let score = try VideoQualityReadback.score(
                    referenceBGRX: dynamicReference,
                    referenceWidth: sourceWidth,
                    referenceHeight: sourceHeight,
                    decoded: frame)
                return ProcessedFrame(
                    frame: frame,
                    score: score,
                    syntheticFrameID: syntheticFrameID,
                    phaseMatched: syntheticMotion ? true : nil)
            } catch {
                return ProcessedFrame(
                    frame: frame, error: String(describing: error))
            }
        }.value
        return observation(
            elapsedSeconds: elapsedSeconds,
            decodedFrames: decodedFrames,
            geometry: geometry,
            decodedWidth: processed.frame?.width,
            decodedHeight: processed.frame?.height,
            frame: processed.frame,
            score: processed.score,
            syntheticFrameID: processed.syntheticFrameID,
            phaseMatched: processed.phaseMatched,
            error: processed.error)
    }

    private struct Geometry {
        var widthPoints = 0.0
        var heightPoints = 0.0
        var widthPixels = 0.0
        var heightPixels = 0.0
        var backingScale = 0.0
        var fittedWidthPoints = 0.0
        var fittedHeightPoints = 0.0
    }

    private static func geometry(sourceWidth: Int, sourceHeight: Int) -> Geometry {
        guard let window = NSApp.mainWindow
                ?? NSApp.windows.first(where: \.isVisible),
              let view = window.contentView else {
            return Geometry()
        }
        let bounds = view.bounds
        let backing = view.convertToBacking(bounds)
        let scale: Double
        if sourceWidth > 0, sourceHeight > 0 {
            scale = min(
                Double(bounds.width) / Double(sourceWidth),
                Double(bounds.height) / Double(sourceHeight))
        } else {
            scale = 0
        }
        return Geometry(
            widthPoints: Double(bounds.width),
            heightPoints: Double(bounds.height),
            widthPixels: Double(backing.width),
            heightPixels: Double(backing.height),
            backingScale: Double(window.backingScaleFactor),
            fittedWidthPoints: Double(sourceWidth) * scale,
            fittedHeightPoints: Double(sourceHeight) * scale)
    }

    private func observation(
        elapsedSeconds: Double,
        decodedFrames: UInt64,
        geometry: Geometry,
        decodedWidth: Int? = nil,
        decodedHeight: Int? = nil,
        frame: VideoQualityReadback.Frame? = nil,
        score: VideoQualityReadback.Score? = nil,
        syntheticFrameID: UInt32? = nil,
        phaseMatched: Bool? = nil,
        error: String? = nil
    ) -> DiagnosticBenchmarkSample.Quality {
        DiagnosticBenchmarkSample.Quality(
            elapsedSeconds: elapsedSeconds,
            decodedFrames: decodedFrames,
            referenceName: referenceName,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            decodedWidth: decodedWidth,
            decodedHeight: decodedHeight,
            readbackPixelFormat: frame?.sourcePixelFormat,
            readbackBytesPerRow: frame?.sourceBytesPerRow,
            readbackYCbCrMatrix: frame?.yCbCrMatrix,
            readbackColorPrimaries: frame?.colorPrimaries,
            readbackTransferFunction: frame?.transferFunction,
            psnrRDB: score.map { Self.jsonDB($0.rgbPSNR.r) },
            psnrGDB: score.map { Self.jsonDB($0.rgbPSNR.g) },
            psnrBDB: score.map { Self.jsonDB($0.rgbPSNR.b) },
            psnrMinDB: score.map { Self.jsonDB($0.rgbPSNR.minChannel) },
            lumaSSIM: score?.lumaSSIM,
            syntheticFrameID: syntheticFrameID,
            phaseMatched: phaseMatched,
            viewportWidthPoints: geometry.widthPoints,
            viewportHeightPoints: geometry.heightPoints,
            viewportWidthPixels: geometry.widthPixels,
            viewportHeightPixels: geometry.heightPixels,
            backingScaleFactor: geometry.backingScale,
            fittedVideoWidthPoints: geometry.fittedWidthPoints,
            fittedVideoHeightPoints: geometry.fittedHeightPoints,
            displayScaleX: sourceWidth > 0
                ? geometry.fittedWidthPoints / Double(sourceWidth) : 0,
            displayScaleY: sourceHeight > 0
                ? geometry.fittedHeightPoints / Double(sourceHeight) : 0,
            error: error)
    }

    /// JSON has no infinity spelling. 999 dB is an explicit exact-channel
    /// sentinel, far above every pinned pass bar.
    private static func jsonDB(_ value: Double) -> Double {
        value.isFinite ? value : 999
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
