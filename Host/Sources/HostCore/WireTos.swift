// WireTos: the product's per-packet IP marking policy — PacerClass →
// IPv4 TOS byte, applied at the CNetIO seam (the Lyte-UDP decision
// restored the audio doc's commitment: per-packet DSCP, 48 on the
// protected classes, 40 on video). The pure Pacer stays marking-free by
// design (it schedules bytes; the caller owns syscalls and policy) —
// this is that policy in one testable place instead of two verbatim
// copies (SessionWire and the lyte-pace-check harness).
//
// HS-20 moved `videoTail` into the protected CS6 lane. videoTail is the
// NACK-repair class (HS-17), and a repair is deadline traffic: it must
// land inside the same freeze budget the retransmit gate promised, or
// sending it was pointless. Riding video's 0xA0 meant a DSCP-aware
// bottleneck squeezing the video class (Wi-Fi EDCA, any classful qdisc
// — and the CL-12 live leg, where 17 of 54 repairs survived the
// squeezed lane) starved exactly the datagrams sent to heal that
// squeeze's damage. The pacer's strict priority still holds videoTail
// BELOW fresh video at our own NIC (a repair burst can never bend the
// 5 ms audio cadence — that discipline is the Pacer's, not the
// marking's); the CS6 mark protects repairs at the bottleneck queue we
// do NOT own, where the honored repair volume (budget-gated, one
// attempt per shard, store-capped) is a trickle against the classes it
// joins.
public enum WireTos {
    /// The class's IPv4 TOS byte (DSCP in the top six bits).
    public static func byte(for pacerClass: PacerClass) -> UInt8 {
        switch pacerClass {
        case .control, .audio: return 0xC0 // CS6 / DSCP 48
        case .videoTail: return 0xC0 // CS6 — the repair lane (HS-20)
        case .freshVideo, .refinement: return 0xA0 // CS5 / DSCP 40
        case .telemetry: return 0x00
        }
    }
}
