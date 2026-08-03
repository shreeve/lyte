import LyteCore

// Host-only policy adapter: the shared vocabulary owns every byte, while the
// host scheduler owns the exhaustive mapping from its PacerClass role type.
//
// videoTail is the NACK-repair class. A repair is deadline traffic: it must
// arrive inside the freeze budget or sending it was pointless. Putting it on
// video's CS5 lane let a DSCP-aware bottleneck starve exactly the datagrams
// meant to heal that squeezed lane, so repairs join control/audio on CS6. The
// pacer's strict priority still holds videoTail below fresh video at our own
// NIC; this mark protects the bounded repair trickle only at queues we do not
// own. Bulk takes CS1 so patient files yield to all session deadlines.
public extension WireTos {
    static func byte(for pacerClass: PacerClass) -> UInt8 {
        switch pacerClass {
        case .control, .audio, .videoTail:
            return WireTos.protected
        case .freshVideo, .refinement:
            return WireTos.video
        case .telemetry:
            return WireTos.unmarked
        case .bulk:
            return WireTos.bulk
        }
    }
}
