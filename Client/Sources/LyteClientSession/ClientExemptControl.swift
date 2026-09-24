import LyteWire

/// One authenticated ARQ-exempt CTRL payload as a client consumes it. Every
/// client shell classifies here, so a word the protocol adds is answered —
/// or skipped — identically by all of them. ARQ frames (0x07/0x08) belong
/// to the reliable endpoint and never reach this classifier.
public enum ClientExemptControl: Hashable, Sendable {
    /// Answer through `ClientBeaconEchoBook` promptly: t2 is its arrival.
    case clockBeacon(ClockBeacon)
    /// Send `response` at once, bare and sealed on CTRL with the learned
    /// conn-id tag. The host promotes the tuple it probed only on this
    /// echo, so a client that stays silent can never migrate.
    case pathChallenge(response: PathResponse)
    /// The host will not repair this frame: escalate it to an IDR now.
    case repairRefused(RepairRefusal)
    /// A type this client consumes whose body did not decode: count it
    /// and drop it; hostile bytes are never fatal.
    case malformed(type: UInt8)
    /// A type no client consumes: skipped silently (forward compatibility).
    case unclaimed

    public init(payload: [UInt8]) {
        switch CtrlMessageType.peek(payload) {
        case CtrlMessageType.clockBeacon:
            self = (try? ClockBeacon.decode(payload)).map(Self.clockBeacon)
                ?? .malformed(type: CtrlMessageType.clockBeacon)
        case CtrlMessageType.pathChallenge:
            self = (try? PathChallenge.decode(payload)).map {
                .pathChallenge(response: PathResponse(echoing: $0))
            } ?? .malformed(type: CtrlMessageType.pathChallenge)
        case CtrlMessageType.repairRefused:
            self = (try? RepairRefusal.decode(payload)).map(Self.repairRefused)
                ?? .malformed(type: CtrlMessageType.repairRefused)
        default:
            self = .unclaimed
        }
    }
}
