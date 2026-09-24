// Which rate-control posture the next frame's RC and HRD buffers carry.
// A directive (`request`) takes effect on the next frame, whatever its
// type, so a recovery IDR arriving with a tightening directive is already
// sized to the new cap. An IDR re-sends the posture in force regardless
// (its sequence rebuild resets the driver's RC state).

struct EncoderRateLatch {
    struct Posture: Equatable {
        var bitsPerSecond: Int64
        /// Nil keeps the encoder's default window (four frames of cap).
        var hrdBufferBits: Int64?
    }

    /// The posture the driver holds (or will, once this frame is sent).
    private(set) var current: Posture
    private var pending: Posture?

    init(bitsPerSecond: Int64, hrdBufferBits: Int64?) {
        current = Posture(bitsPerSecond: bitsPerSecond, hrdBufferBits: hrdBufferBits)
    }

    mutating func request(bitsPerSecond: Int64, hrdBufferBits: Int64?) {
        pending = Posture(bitsPerSecond: bitsPerSecond, hrdBufferBits: hrdBufferBits)
    }

    /// The posture this frame's RC/HRD buffers carry, or nil when a P
    /// frame needs none. A pending directive lands here, IDR or not.
    mutating func take(forIDR idr: Bool) -> Posture? {
        if let pending {
            current = pending
            self.pending = nil
            return current
        }
        return idr ? current : nil
    }
}
