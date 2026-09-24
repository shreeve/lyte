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
    private var ring: [Packet?]
    private var head = 0
    private var count = 0

    public private(set) var packetsAssembled: UInt64 = 0
    public private(set) var packetsPopped: UInt64 = 0
    public private(set) var packetsDroppedStale: UInt64 = 0

    public init(capacity: Int = BrowserAudioPlayout.defaultCapacity) {
        ring = Array(repeating: nil, count: max(1, capacity))
    }

    public var pendingCount: Int { count }

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
        guard count > 0 else { return nil }
        let packet = ring[head]
        ring[head] = nil
        head = (head + 1) % ring.count
        count -= 1
        packetsPopped += 1
        return packet
    }

    private mutating func push(_ packet: Packet) {
        if count == ring.count {
            // Full: the oldest packet is the stalest; drop it.
            ring[head] = nil
            head = (head + 1) % ring.count
            count -= 1
            packetsDroppedStale += 1
        }
        ring[(head + count) % ring.count] = packet
        count += 1
    }
}
