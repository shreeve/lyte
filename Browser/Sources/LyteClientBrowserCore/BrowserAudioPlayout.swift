import LyteCore
import LyteWire

/// Sans-IO browser audio organ: LyteWire `AudioDepacketizer` plus a bounded
/// hand-off queue. Page JS owns Opus decode (WebCodecs) and the AudioWorklet
/// PCM ring; this type never invents samples or clocks.
///
/// When the page stops popping (a background tab, no AudioDecoder) the queue
/// keeps only the newest packets: audio popped later must be fresh, not
/// seconds stale.
public struct BrowserAudioPlayout {
    public struct Packet: Sendable, Equatable {
        public var number: UInt32
        public var captureMicroseconds: UInt64
        public var recovered: Bool
        public var bytes: [UInt8]
    }

    /// 20 packets: 100 ms at the host's 5 ms Opus packet cadence.
    public static let defaultCapacity = 20

    private var depacketizer = AudioDepacketizer()
    private let capacity: Int
    private var queue = Deque<Packet>()

    public private(set) var packetsAssembled: UInt64 = 0
    public private(set) var packetsPopped: UInt64 = 0
    public private(set) var packetsDroppedStale: UInt64 = 0

    public init(capacity: Int = BrowserAudioPlayout.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var pendingCount: Int { queue.count }

    /// Ingests one unsealed audio payload. Returns notes.
    public mutating func ingestShard(
        envelope: Envelope,
        payload: ArraySlice<UInt8>
    ) -> [String] {
        var notes: [String] = []
        for packet in depacketizer.ingest(envelope: envelope, payload: Array(payload)) {
            push(Packet(
                number: packet.number,
                captureMicroseconds: packet.captureMicroseconds,
                recovered: packet.recovered,
                bytes: packet.bytes
            ))
            packetsAssembled += 1
            if packetsAssembled == 1 {
                notes.append(
                    "audio: first Opus packet #\(packet.number) (\(packet.bytes.count) B)"
                )
            }
        }
        return notes
    }

    public mutating func popPacket() -> Packet? {
        guard let packet = queue.popFirst() else { return nil }
        packetsPopped += 1
        return packet
    }

    private mutating func push(_ packet: Packet) {
        if queue.count == capacity {
            // Full: the oldest packet is the stalest; drop it.
            queue.removeFirst()
            packetsDroppedStale += 1
        }
        queue.append(packet)
    }
}
