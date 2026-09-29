import LyteClientCore
import LyteCore
import LyteWire

/// Sans-IO browser audio organ: LyteWire's `AudioDepacketizer` (FEC
/// recovery included) feeding the native client's adaptive
/// `AudioJitterBuffer`, pulled by the shared `AudioRingFill` rule. Page JS
/// owns Opus decode (WebCodecs) and the AudioWorklet PCM ring; it reports
/// how much audio sits between this organ and the speaker, and executes
/// each verdict in the order it was given.
///
/// Before the page first pulls (autoplay has not been unlocked, or no
/// AudioDecoder exists) the buffer keeps only the newest target's worth,
/// so playout starts fresh, never seconds stale. The ring drops its oldest
/// audio past `ringCeilingFrames`, a bound the pull rule never reaches.
public final class BrowserAudioPlayout {
    /// One verdict the page executes.
    public enum Pull: Equatable, Sendable {
        /// Decode and play this packet.
        case packet(AudioPacket)
        /// The packet at this number is gone: fill one packet duration.
        case conceal(number: UInt32)
    }

    /// The AudioWorklet ring's ceiling: 200 ms of 48 kHz frames.
    public static let ringCeilingFrames = 9_600
    /// Frames one packet decodes to.
    public static let packetFrames = AudioWire.samplesPerPacket

    private var depacketizer = AudioDepacketizer()
    private let jitter: AudioJitterBuffer

    public private(set) var packetsAssembled: UInt64 = 0

    public init(config: AudioJitterConfig = AudioJitterConfig()) {
        jitter = AudioJitterBuffer(config: config)
    }

    /// Packets waiting in the jitter buffer.
    public var pendingCount: Int { jitter.pendingCount }
    /// The adaptive delay target, in packets.
    public var targetPackets: Int { jitter.targetPackets }
    /// True from an announced quiet until the packet that wakes it.
    public var isAnnouncedQuiet: Bool { jitter.isAnnouncedQuiet }
    public var stats: AudioJitterStats { jitter.snapshotStats() }

    /// Ingests one unsealed audio payload that arrived at `arrivalMicros`.
    /// Returns notes.
    public func ingestShard(
        envelope: Envelope,
        payload: [UInt8],
        arrivalMicros: UInt64
    ) -> [String] {
        var notes: [String] = []
        for packet in depacketizer.ingest(envelope: envelope, payload: payload) {
            jitter.insert(packet, arrivalMicroseconds: arrivalMicros)
            packetsAssembled += 1
            if packetsAssembled == 1 {
                notes.append(
                    "audio: first Opus packet #\(packet.number) (\(packet.bytes.count) B)"
                )
            }
        }
        return notes
    }

    /// The host announced the track quiet: its silence is contract, so an
    /// empty buffer is not concealed until a packet wakes it.
    public func noteAnnouncedQuiet() {
        jitter.noteAnnouncedQuiet()
    }

    /// The next verdict while `pipelineFrames` (the ring plus whatever the
    /// page is decoding) sits below the target; nil means stop pulling
    /// until the pipeline drains or more audio arrives.
    public func pull(nowMicros: UInt64, pipelineFrames: Int) -> Pull? {
        guard let fill = AudioRingFill.next(
            pipelineFrames: pipelineFrames,
            targetPackets: jitter.targetPackets,
            capacityFrames: Self.ringCeilingFrames)
        else { return nil }
        switch jitter.pull(nowMicroseconds: nowMicros, urgent: fill.urgent) {
        case .packet(let packet):
            return .packet(packet)
        case .conceal(let number):
            return .conceal(number: number)
        case .starved:
            return nil
        }
    }
}
