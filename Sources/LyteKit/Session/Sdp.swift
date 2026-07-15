import Foundation

/// What DESCRIBE told us about the host's stream capabilities.
public struct HostSdpInfo: Sendable {
    public let supportsHevc: Bool
    public let supportsAv1: Bool
    public let sunshineFeatureFlags: UInt32
    public let encryptionSupported: UInt32
    public let encryptionRequested: UInt32
    public let rfiSupported: Bool

    public init(describePayload sdp: String) {
        supportsHevc = sdp.contains("sprop-parameter-sets=AAAAAU")
        supportsAv1 = sdp.contains("AV1/90000")
        sunshineFeatureFlags = Self.attribute(sdp, "x-ss-general.featureFlags") ?? 0
        encryptionSupported = Self.attribute(sdp, "x-ss-general.encryptionSupported") ?? 0
        encryptionRequested = Self.attribute(sdp, "x-ss-general.encryptionRequested") ?? 0
        rfiSupported = sdp.contains("x-nv-video[0].refPicInvalidation")
    }

    /// Parse `a=name:value` (value may be 0x-prefixed hex or decimal).
    static func attribute(_ sdp: String, _ name: String) -> UInt32? {
        guard let range = sdp.range(of: name) else { return nil }
        let rest = sdp[range.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let value = rest[rest.index(after: colon)...].prefix { !$0.isWhitespace && $0 != "\r" }
        if value.hasPrefix("0x") { return UInt32(value.dropFirst(2), radix: 16) }
        return UInt32(value)
    }
}

/// Encryption flag bits shared with Sunshine (x-ss-general.*).
public enum SSEnc {
    public static let controlV2: UInt32 = 0x01
    public static let video: UInt32 = 0x02
    public static let audio: UInt32 = 0x04
}

public enum VideoCodec: String, Sendable {
    case h264, hevc, av1
}

/// Builds the client SDP for ANNOUNCE — Sunshine / Gen 7.1.431+ paths only.
/// Attribute set and exact formatting ported from SdpGenerator.c
/// (note the trailing space before CRLF and the double space in the tail).
public struct ClientSdp {
    public let context: StreamContext
    public let codec: VideoCodec
    public let encryptionEnabled: UInt32
    public let audioChannels: Int
    public let audioChannelMask: Int
    public let refreshRateX100: Int

    public func payload(videoPort: Int) -> Data {
        var a: [(String, String)] = []

        // Sunshine client feature flags: FEC status + session-id v1
        a.append(("x-ml-general.featureFlags", "3"))
        a.append(("x-ss-general.encryptionEnabled", "\(encryptionEnabled)"))
        a.append(("x-ss-video[0].chromaSamplingType", "0"))

        a.append(("x-nv-video[0].clientViewportWd", "\(context.width)"))
        a.append(("x-nv-video[0].clientViewportHt", "\(context.height)"))
        a.append(("x-nv-video[0].maxFPS", "\(context.fps)"))

        // 4-byte ENC_VIDEO_HEADER... is larger; reference subtracts sizeof(ENC_VIDEO_HEADER)
        // from packetSize when video encryption is on. (ENC_VIDEO_HEADER = 32 bytes.)
        var packetSize = context.packetSize
        if encryptionEnabled & SSEnc.video != 0 { packetSize -= 32 }
        a.append(("x-nv-video[0].packetSize", "\(packetSize)"))

        a.append(("x-nv-video[0].rateControlMode", "4"))
        a.append(("x-nv-video[0].timeoutLengthMs", "7000"))
        a.append(("x-nv-video[0].framesWithInvalidRefThreshold", "0"))

        // Encoder gets 80% of the user bitrate; 20% is reserved for FEC overhead.
        let adjusted = min(Int(Double(context.bitrateKbps) * 0.80), 100_000)
        a.append(("x-nv-video[0].initialBitrateKbps", "\(adjusted)"))
        a.append(("x-nv-video[0].initialPeakBitrateKbps", "\(adjusted)"))
        a.append(("x-nv-vqos[0].bw.minimumBitrateKbps", "\(adjusted)"))
        a.append(("x-nv-vqos[0].bw.maximumBitrateKbps", "\(adjusted)"))
        a.append(("x-ml-video.configuredBitrateKbps", "\(context.bitrateKbps)"))

        a.append(("x-nv-vqos[0].fec.enable", "1"))
        a.append(("x-nv-vqos[0].videoQualityScoreUpdateTime", "5000"))

        // LAN: enable QoS tagging
        a.append(("x-nv-vqos[0].qosTrafficType", "5"))
        a.append(("x-nv-aqos.qosTrafficType", "4"))

        // Gen 7.1.431+ options
        var nvff: UInt32 = 0x07 | 0x80                    // NVFF_BASE | NVFF_RI_ENCRYPTION
        if encryptionEnabled & SSEnc.audio != 0 { nvff |= 0x20 }
        a.append(("x-nv-general.featureFlags", "\(nvff)"))
        a.append(("x-nv-general.useReliableUdp", "13"))
        a.append(("x-nv-vqos[0].fec.minRequiredFecPackets", "2"))
        a.append(("x-nv-vqos[0].bllFec.enable", "0"))
        a.append(("x-nv-vqos[0].drc.enable", "0"))
        a.append(("x-nv-general.enableRecoveryMode", "0"))

        a.append(("x-nv-video[0].videoEncoderSlicesPerFrame", "1"))

        switch codec {
        case .av1:
            a.append(("x-nv-vqos[0].bitStreamFormat", "2"))
        case .hevc:
            a.append(("x-nv-clientSupportHevc", "1"))
            a.append(("x-nv-vqos[0].bitStreamFormat", "1"))
        case .h264:
            a.append(("x-nv-clientSupportHevc", "0"))
            a.append(("x-nv-vqos[0].bitStreamFormat", "0"))
        }

        a.append(("x-nv-video[0].dynamicRangeMode", "0"))          // SDR for M2
        a.append(("x-nv-video[0].maxNumReferenceFrames", "1"))     // no RFI yet
        a.append(("x-nv-video[0].clientRefreshRateX100", "\(refreshRateX100)"))

        a.append(("x-nv-audio.surround.numChannels", "\(audioChannels)"))
        a.append(("x-nv-audio.surround.channelMask", "\(audioChannelMask)"))
        a.append(("x-nv-audio.surround.enable", audioChannels > 2 ? "1" : "0"))
        a.append(("x-nv-audio.surround.AudioQuality", "0"))
        a.append(("x-nv-aqos.packetDuration", "5"))

        a.append(("x-nv-video[0].encoderCscMode", "0"))            // Rec.601 limited

        var sdp = "v=0\r\n"
        sdp += "o=android 0 14 IN IPv4 \(context.localAddress)\r\n"
        sdp += "s=NVIDIA Streaming Client\r\n"
        for (name, value) in a {
            sdp += "a=\(name):\(value) \r\n"                       // trailing space is load-bearing
        }
        sdp += "t=0 0\r\n"
        sdp += "m=video \(videoPort)  \r\n"                        // double space is load-bearing
        return Data(sdp.utf8)
    }
}
