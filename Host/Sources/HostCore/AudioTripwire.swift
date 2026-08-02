// AudioTripwire — the postures design's auto-quiet gate
// (docs/20260802-013946-postures-design.md): capture NEVER stops, only
// transmission gates. Sans-IO by construction: time is counted in
// packets (the wire's fixed 5 ms cadence), levels arrive as RMS the
// caller computes from the PCM it already holds, and the encoded
// bytes pass through untouched — the tripwire decides, the caller
// sends.
//
// The asymmetry law (owner-specified): tripwire UP, leak DOWN. Waking
// takes ~100 ms of sound (tripPackets) — and loses NOTHING, because
// the pre-roll ring holds the onset and its leading context; gating
// takes ~5 s of unbroken silence (quietHoldPackets), so sentence gaps
// and breaths never flap the gate. While gated, a check-in fires
// every ~5 s (checkInPackets) so the client's contract is bounded-
// stale, never ambiguous; detection stays continuous — the check-in
// cadence bounds staleness, not wake latency.

/// One gated packet held for the wake burst: the encoded bytes and
/// the capture stamp they were born with.
public struct AudioTripwirePacket: Equatable, Sendable {
    public var bytes: [UInt8]
    public var captureMicroseconds: UInt64

    public init(bytes: [UInt8], captureMicroseconds: UInt64) {
        self.bytes = bytes
        self.captureMicroseconds = captureMicroseconds
    }
}

public struct AudioTripwireConfig: Sendable {
    /// RMS at or above this is "sound" (float PCM in [-1, 1]).
    /// 1e-3 ≈ -60 dBFS: comfortably above dither and virtual-sink
    /// digital silence, comfortably below any audible content.
    public var soundRmsFloor: Float
    /// Consecutive sound packets that fire the tripwire while gated —
    /// 20 × 5 ms = 100 ms. The ring preserves what these packets
    /// heard, so detection latency costs no audio.
    public var tripPackets: Int
    /// Consecutive silent packets before the gate closes —
    /// 1000 × 5 ms = 5 s. The flap hysteresis.
    public var quietHoldPackets: Int
    /// Ring capacity: 40 × 5 ms = 200 ms shipped on wake.
    public var preRollPackets: Int
    /// Still-quiet check-in cadence while gated — 1000 × 5 ms = 5 s.
    public var checkInPackets: Int

    public init(
        soundRmsFloor: Float = 1e-3,
        tripPackets: Int = 20,
        quietHoldPackets: Int = 1_000,
        preRollPackets: Int = 40,
        checkInPackets: Int = 1_000
    ) {
        self.soundRmsFloor = max(soundRmsFloor, 0)
        self.tripPackets = max(tripPackets, 1)
        self.quietHoldPackets = max(quietHoldPackets, 1)
        self.preRollPackets = max(preRollPackets, 1)
        self.checkInPackets = max(checkInPackets, 1)
    }
}

/// What the caller does with the packet it just offered.
public enum AudioTripwireAction: Equatable, Sendable {
    /// Transmitting normally: send this packet.
    case transmit
    /// The gate just closed on this packet (announce quiet once).
    /// The packet itself joins the ring, unsent.
    case beginQuiet(checkIn: Bool)
    /// Gated: the packet joined the ring; checkIn is true every
    /// checkInPackets while the silence holds.
    case stayQuiet(checkIn: Bool)
    /// The tripwire fired: announce active, then send the pre-roll
    /// burst IN ORDER — it already ends with the packet just offered,
    /// so the onset and its leading context arrive intact and nothing
    /// is sent twice.
    case wake(preRoll: [AudioTripwirePacket])
}

public struct AudioTripwireCounters: Equatable, Sendable {
    /// Packets the gate held back (they entered the ring instead).
    public var packetsGated = 0
    /// Times the gate closed.
    public var quietEntries = 0
    /// Times the tripwire fired.
    public var wakes = 0
    /// Pre-roll packets shipped across all wakes.
    public var preRollShipped = 0

    public init() {}
}

public struct AudioTripwire: Sendable {
    public let config: AudioTripwireConfig
    public private(set) var counters = AudioTripwireCounters()

    private enum State: Equatable {
        /// Counting consecutive silence toward the gate.
        case transmitting(silentRun: Int)
        /// Counting consecutive sound toward the trip; the ring holds
        /// the last preRollPackets.
        case gated(soundRun: Int, sinceCheckIn: Int)
    }

    private var state: State = .transmitting(silentRun: 0)
    private var ring: [AudioTripwirePacket] = []

    public init(config: AudioTripwireConfig = AudioTripwireConfig()) {
        self.config = config
        ring.reserveCapacity(config.preRollPackets)
    }

    /// True while transmission is gated (the books' posture line).
    public var isGated: Bool {
        if case .gated = state { return true }
        return false
    }

    /// Offers one encoded packet with the RMS of the PCM it came
    /// from; returns what to do with it.
    public mutating func ingest(
        rms: Float, packet: [UInt8], captureMicroseconds: UInt64
    ) -> AudioTripwireAction {
        let sound = rms >= config.soundRmsFloor
        switch state {
        case .transmitting(let silentRun):
            let run = sound ? 0 : silentRun + 1
            if run >= config.quietHoldPackets {
                state = .gated(soundRun: 0, sinceCheckIn: 0)
                counters.quietEntries += 1
                push(AudioTripwirePacket(
                    bytes: packet, captureMicroseconds: captureMicroseconds))
                return .beginQuiet(checkIn: true)
            }
            state = .transmitting(silentRun: run)
            return .transmit

        case .gated(let soundRun, let sinceCheckIn):
            let run = sound ? soundRun + 1 : 0
            push(AudioTripwirePacket(
                bytes: packet, captureMicroseconds: captureMicroseconds))
            if run >= config.tripPackets {
                let preRoll = ring
                ring.removeAll(keepingCapacity: true)
                state = .transmitting(silentRun: 0)
                counters.wakes += 1
                counters.preRollShipped += preRoll.count
                return .wake(preRoll: preRoll)
            }
            let ticks = sinceCheckIn + 1
            if ticks >= config.checkInPackets {
                state = .gated(soundRun: run, sinceCheckIn: 0)
                return .stayQuiet(checkIn: true)
            }
            state = .gated(soundRun: run, sinceCheckIn: ticks)
            return .stayQuiet(checkIn: false)
        }
    }

    private mutating func push(_ packet: AudioTripwirePacket) {
        counters.packetsGated += 1
        ring.append(packet)
        if ring.count > config.preRollPackets {
            ring.removeFirst(ring.count - config.preRollPackets)
        }
    }
}
