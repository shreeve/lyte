import Foundation

/// Result of the full RTSP negotiation — everything the media/control layers need.
public struct SessionParameters: Sendable {
    public let audioPort: UInt16
    public let videoPort: UInt16
    public let controlPort: UInt16
    public let audioPingPayload: Data?    // 16-byte X-SS-Ping-Payload
    public let videoPingPayload: Data?
    public let controlConnectData: UInt32
    public let codec: VideoCodec
    public let hostInfo: HostSdpInfo
    public let encryptionEnabled: UInt32
}

/// The RTSP OPTIONS → DESCRIBE → SETUP×3 → ANNOUNCE → PLAY sequence
/// (Sunshine / Gen 7.1.431+ form, ported from RtspConnection.c).
public struct RtspHandshake {
    public let context: StreamContext
    public let preferredCodecs: [VideoCodec]     // negotiation priority order
    public let clientEncryptionFlags: UInt32     // SSEnc bits the client wants

    public init(context: StreamContext,
                preferredCodecs: [VideoCodec] = [.hevc, .h264],
                clientEncryptionFlags: UInt32 = SSEnc.video | SSEnc.audio) {
        self.context = context
        self.preferredCodecs = preferredCodecs
        self.clientEncryptionFlags = clientEncryptionFlags
    }

    /// `onPortsKnown(audioPort, videoPort, audioPing, videoPing)` fires after the
    /// SETUP phase so callers can start UDP pings before PLAY — GFE requires the
    /// audio ping pre-PLAY, and Sunshine learns our RTP address from these pings.
    public func perform(
        onPortsKnown: (@Sendable (UInt16, UInt16, Data?, Data?) -> Void)? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SessionParameters {
        let rtsp = RtspClient(host: context.localAddress, port: context.rtspPort,
                              sessionURL: context.rtspSessionURL, riKey: context.riKey)

        // OPTIONS
        let options = try await rtsp.request("OPTIONS")
        guard options.statusCode == 200 else { throw LyteError.host("RTSP OPTIONS: \(options.statusCode)") }
        log("OPTIONS ok")

        // DESCRIBE
        let describe = try await rtsp.request("DESCRIBE", headers: [
            ("Accept", "application/sdp"),
            ("If-Modified-Since", "Thu, 01 Jan 1970 00:00:00 GMT"),
        ])
        guard describe.statusCode == 200 else { throw LyteError.host("RTSP DESCRIBE: \(describe.statusCode)") }
        let hostInfo = HostSdpInfo(describePayload: describe.payloadString)
        log("DESCRIBE ok (hevc:\(hostInfo.supportsHevc) av1:\(hostInfo.supportsAv1) " +
            "encSupported:0x\(String(hostInfo.encryptionSupported, radix: 16)))")

        // Codec negotiation
        let codec = preferredCodecs.first { c in
            switch c {
            case .av1: return hostInfo.supportsAv1
            case .hevc: return hostInfo.supportsHevc
            case .h264: return true
            }
        } ?? .h264

        // Encryption negotiation: control-v2 whenever supported; A/V when both sides agree
        var encryptionEnabled: UInt32 = 0
        if hostInfo.encryptionSupported & SSEnc.controlV2 != 0 { encryptionEnabled |= SSEnc.controlV2 }
        for bit in [SSEnc.video, SSEnc.audio] {
            if hostInfo.encryptionSupported & bit != 0,
               (clientEncryptionFlags | hostInfo.encryptionRequested) & bit != 0 {
                encryptionEnabled |= bit
            }
        }

        // SETUP audio (no session yet)
        let setupHeaders: [(String, String)] = [
            ("Transport", "unicast;X-GS-ClientPort=50000-50001"),
            ("If-Modified-Since", "Thu, 01 Jan 1970 00:00:00 GMT"),
        ]
        let audio = try await rtsp.request("SETUP", target: "streamid=audio/0/0", headers: setupHeaders)
        guard audio.statusCode == 200 else { throw LyteError.host("RTSP SETUP audio: \(audio.statusCode)") }
        guard let rawSession = audio.header("Session"),
              let sessionID = rawSession.split(separator: ";").first.map(String.init),
              !sessionID.isEmpty else {
            throw LyteError.host("RTSP SETUP audio: missing Session")
        }
        let audioPort = Self.serverPort(audio) ?? 48000
        let audioPing = Self.pingPayload(audio)
        log("SETUP audio ok (port \(audioPort), session \(sessionID))")

        let sessionHeader = ("Session", sessionID)

        // SETUP video
        let video = try await rtsp.request("SETUP", target: "streamid=video/0/0",
                                           headers: setupHeaders + [sessionHeader])
        guard video.statusCode == 200 else { throw LyteError.host("RTSP SETUP video: \(video.statusCode)") }
        let videoPort = Self.serverPort(video) ?? 47998
        let videoPing = Self.pingPayload(video)
        log("SETUP video ok (port \(videoPort))")

        // SETUP control
        let control = try await rtsp.request("SETUP", target: "streamid=control/13/0",
                                             headers: setupHeaders + [sessionHeader])
        guard control.statusCode == 200 else { throw LyteError.host("RTSP SETUP control: \(control.statusCode)") }
        let controlPort = Self.serverPort(control) ?? 47999
        let connectData = control.header("X-SS-Connect-Data").flatMap { UInt32($0) } ?? 0
        log("SETUP control ok (port \(controlPort), connectData \(connectData))")

        // Ports are final — let the caller start pinging before ANNOUNCE/PLAY.
        onPortsKnown?(audioPort, videoPort, audioPing, videoPing)

        // ANNOUNCE with client SDP
        let sdp = ClientSdp(context: context, codec: codec,
                            encryptionEnabled: encryptionEnabled,
                            audioChannels: 2, audioChannelMask: 0x3,
                            refreshRateX100: context.fps * 100)
            .payload(videoPort: Int(videoPort))
        let announce = try await rtsp.request("ANNOUNCE", target: "streamid=control/13/0", headers: [
            sessionHeader,
            ("Content-type", "application/sdp"),
            ("Content-length", "\(sdp.count)"),
        ], payload: sdp)
        guard announce.statusCode == 200 else { throw LyteError.host("RTSP ANNOUNCE: \(announce.statusCode)") }
        log("ANNOUNCE ok (codec \(codec.rawValue), enc 0x\(String(encryptionEnabled, radix: 16)))")

        // PLAY
        let play = try await rtsp.request("PLAY", target: "/", headers: [sessionHeader])
        guard play.statusCode == 200 else { throw LyteError.host("RTSP PLAY: \(play.statusCode)") }
        log("PLAY ok — session is live")

        return SessionParameters(audioPort: audioPort, videoPort: videoPort,
                                 controlPort: controlPort,
                                 audioPingPayload: audioPing, videoPingPayload: videoPing,
                                 controlConnectData: connectData,
                                 codec: codec, hostInfo: hostInfo,
                                 encryptionEnabled: encryptionEnabled)
    }

    // Transport: unicast;server_port=48000-48001;...
    static func serverPort(_ response: RtspClient.Response) -> UInt16? {
        guard let transport = response.header("Transport"),
              let range = transport.range(of: "server_port=") else { return nil }
        let digits = transport[range.upperBound...].prefix { $0.isNumber }
        return UInt16(digits)
    }

    static func pingPayload(_ response: RtspClient.Response) -> Data? {
        guard let payload = response.header("X-SS-Ping-Payload"), payload.count == 16 else { return nil }
        return Data(payload.utf8)
    }
}
