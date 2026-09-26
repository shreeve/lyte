import LyteCore
import LyteWire

/// Sans-IO browser audio organ: LyteWire `AudioDepacketizer` plus a bounded
/// hand-off queue. Page JS owns Opus decode (WebCodecs) and the AudioWorklet
/// PCM ring; this type never invents samples or clocks, and it owns both
/// latency bounds the page executes.
///
/// When the page stops popping (a background tab, no AudioDecoder) the queue
/// keeps only the newest packets: audio popped later must be fresh, not
/// seconds stale. The ring drops its oldest audio past
/// `ringCeilingFrames`, so output clock drift cannot grow latency without
/// limit.
public struct BrowserAudioPlayout {
    /// 20 packets: 100 ms at the host's 5 ms Opus packet cadence.
    public static let capacity = 20
    /// The AudioWorklet ring's ceiling: 200 ms of 48 kHz frames.
    public static let ringCeilingFrames = 9_600

    private var depacketizer = AudioDepacketizer()
    private var queue = Deque<AudioPacket>()

    public private(set) var packetsAssembled: UInt64 = 0
    public private(set) var packetsDroppedStale: UInt64 = 0

    public init() {}

    public var pendingCount: Int { queue.count }

    /// Ingests one unsealed audio payload. Returns notes.
    public mutating func ingestShard(
        envelope: Envelope,
        payload: [UInt8]
    ) -> [String] {
        var notes: [String] = []
        for packet in depacketizer.ingest(envelope: envelope, payload: payload) {
            push(packet)
            packetsAssembled += 1
            if packetsAssembled == 1 {
                notes.append(
                    "audio: first Opus packet #\(packet.number) (\(packet.bytes.count) B)"
                )
            }
        }
        return notes
    }

    public mutating func popPacket() -> AudioPacket? {
        queue.popFirst()
    }

    private mutating func push(_ packet: AudioPacket) {
        if queue.count == Self.capacity {
            // Full: the oldest packet is the stalest; drop it.
            queue.removeFirst()
            packetsDroppedStale += 1
        }
        queue.append(packet)
    }
}
