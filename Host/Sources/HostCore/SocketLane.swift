public enum SocketLane: Equatable, Sendable {
    case latency
    case video

    public static func forClass(_ priorityClass: PacerClass) -> SocketLane {
        priorityClass <= .audio ? .latency : .video
    }
}
