import AppKit
import Foundation
import LyteTransport

struct DiagnosticBenchmarkSample: Codable {
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
        guard let outputPath = environment["LYTE_BENCHMARK_JSONL"],
              let durationText = environment["LYTE_BENCHMARK_SECONDS"],
              let duration = Double(durationText),
              duration >= 5, duration <= 3_600
        else { return }

        let runID = environment["LYTE_BENCHMARK_RUN_ID"] ?? UUID().uuidString
        let workload = environment["LYTE_BENCHMARK_WORKLOAD"] ?? "unknown"
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

        while true {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                try? handle.close()
                return
            }
            let elapsed = started.duration(to: .now).seconds
            let sample = model.diagnosticBenchmarkSample(
                runID: runID,
                workload: workload,
                elapsedSeconds: elapsed,
                afterOrdinal: lastOrdinal)
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

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
