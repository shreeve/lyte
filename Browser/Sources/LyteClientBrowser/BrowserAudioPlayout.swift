import LyteWire

/// Sans-IO browser audio organ for B-6: LyteWire `AudioDepacketizer` only.
/// Page JS owns Opus decode (WebCodecs) and AudioWorklet PCM ring; this
/// type never invents samples or clocks.
struct BrowserAudioPlayout {
    struct Packet: Sendable {
        var number: UInt32
        var captureMicroseconds: UInt64
        var recovered: Bool
        var bytes: [UInt8]
    }

    private var depacketizer = AudioDepacketizer()
    private var pending: [Packet] = []
    private var packetsEmitted: UInt64 = 0
    private var packetsDelivered: UInt64 = 0

    var packetsAssembled: UInt64 { packetsEmitted }
    var packetsPopped: UInt64 { packetsDelivered }
    var pendingCount: Int { pending.count }

    mutating func reset() {
        depacketizer = AudioDepacketizer()
        pending.removeAll(keepingCapacity: true)
        packetsEmitted = 0
        packetsDelivered = 0
    }

    /// Ingest one sealed-audio plaintext payload (chan-1). Returns notes.
    mutating func ingestShard(
        envelope: Envelope,
        payload: ArraySlice<UInt8>
    ) -> [String] {
        var notes: [String] = []
        let emitted = depacketizer.ingest(
            envelope: envelope, payload: Array(payload)
        )
        for packet in emitted {
            pending.append(Packet(
                number: packet.number,
                captureMicroseconds: packet.captureMicroseconds,
                recovered: packet.recovered,
                bytes: packet.bytes
            ))
            packetsEmitted += 1
            if packetsEmitted == 1 {
                notes.append(
                    "audio: first Opus packet #\(packet.number) "
                        + "(\(packet.bytes.count) B)"
                )
            }
        }
        return notes
    }

    mutating func popPacket() -> Packet? {
        guard !pending.isEmpty else { return nil }
        packetsDelivered += 1
        return pending.removeFirst()
    }
}
