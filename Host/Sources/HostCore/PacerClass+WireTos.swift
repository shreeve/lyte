import LyteCore

// The host's exhaustive PacerClass → WireTos mapping.
//
// videoTail (NACK repair) is deadline traffic, so it joins control/audio
// on CS6: on video's CS5 lane a DSCP-aware bottleneck would starve the
// repairs meant to heal that lane. The pacer still holds videoTail below
// fresh video at our own NIC. Bulk takes CS1 so files yield to all
// session deadlines.
public extension WireTos {
    static func byte(for pacerClass: PacerClass) -> UInt8 {
        switch pacerClass {
        case .control, .audio, .videoTail:
            return WireTos.protected
        case .freshVideo:
            return WireTos.video
        case .bulk:
            return WireTos.bulk
        }
    }
}
