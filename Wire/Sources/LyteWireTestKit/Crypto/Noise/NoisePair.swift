import LyteWire

/// A Noise IK initiator (the client) and responder (the host) between
/// fresh static keys.
public enum NoisePair {
    /// Both sessions, before either handshake message is written.
    public static func sessions() throws -> (client: NoiseSession, host: NoiseSession) {
        let hostStatic = NoiseKeyPair.generate()
        return (
            try NoiseSession(
                role: .initiator, staticKeys: .generate(),
                remoteStaticPublicKey: hostStatic.publicKey
            ),
            try NoiseSession(role: .responder, staticKeys: hostStatic)
        )
    }

    /// Runs messages 1 and 2, with empty application payloads.
    public static func complete(
        _ client: inout NoiseSession, _ host: inout NoiseSession
    ) throws {
        _ = try host.readMessage1(try client.writeMessage1()[...])
        _ = try client.readMessage2(try host.writeMessage2()[...])
    }

    /// Both transports of a completed handshake.
    public static func transports() throws -> (client: NoiseTransport, host: NoiseTransport) {
        var (client, host) = try sessions()
        try complete(&client, &host)
        return (try client.makeTransport(), try host.makeTransport())
    }
}
