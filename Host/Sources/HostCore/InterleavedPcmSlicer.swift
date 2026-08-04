// Exact interleaved-PCM packet slicing against an injected graph clock.
// Pure mechanism: no PipeWire, Opus, wire delivery, threads, or OS clock.

/// Retains expiring capture buffers and synchronously yields exact-size PCM
/// packets stamped by the graph-clock buffer containing each packet's first
/// frame.
///
/// `ingest` makes the one required copy from the caller's expiring buffer into
/// its retained tail. Each packet callback then borrows that tail directly;
/// the pointer is valid only until the callback returns and must not escape.
/// The owner must confine this class to one thread and must not re-enter it from
/// the callback. A throwing callback retains the current packet and stops the
/// drain, while a normal return consumes it.
public final class InterleavedPcmSlicer {
    private struct Mark {
        let startFrame: Int
        let microseconds: UInt64
    }

    private let sampleRate: Int
    private let channels: Int
    private let packetFrames: Int
    private let packetSamples: Int
    private var pending: [Float] = []
    private var pendingStartFrame = 0
    private var marks: [Mark] = []

    public init(
        sampleRate: Int,
        channels: Int,
        packetFrames: Int,
        reserveSampleCapacity: Int = 8_192
    ) {
        precondition(sampleRate > 0)
        precondition(channels > 0)
        precondition(packetFrames > 0)
        precondition(packetFrames <= Int.max / channels)
        precondition(reserveSampleCapacity >= 0)
        self.sampleRate = sampleRate
        self.channels = channels
        self.packetFrames = packetFrames
        packetSamples = packetFrames * channels
        pending.reserveCapacity(reserveSampleCapacity)
    }

    public func ingest(
        _ samples: UnsafeBufferPointer<Float>,
        graphStartMicroseconds: UInt64,
        onPacket: (UnsafeBufferPointer<Float>, UInt64) throws -> Void
    ) rethrows {
        precondition(samples.count.isMultiple(of: channels))

        if !samples.isEmpty {
            let startFrame = pendingStartFrame + pending.count / channels
            precondition(startFrame <= Int.max - samples.count / channels)
            marks.append(Mark(
                startFrame: startFrame,
                microseconds: graphStartMicroseconds
            ))
            pending.append(contentsOf: samples)
        }

        while pending.count >= packetSamples {
            let timestamp = timestampForPendingHead()
            try pending.withUnsafeBufferPointer { pcm in
                try onPacket(
                    UnsafeBufferPointer(
                        start: pcm.baseAddress,
                        count: packetSamples
                    ),
                    timestamp
                )
            }
            pending.removeFirst(packetSamples)
            pendingStartFrame += packetFrames
        }
    }

    private func timestampForPendingHead() -> UInt64 {
        while marks.count > 1,
              marks[1].startFrame <= pendingStartFrame {
            marks.removeFirst()
        }
        guard let mark = marks.first else { return 0 }
        return mark.microseconds
            + UInt64(pendingStartFrame - mark.startFrame)
                * 1_000_000 / UInt64(sampleRate)
    }
}
