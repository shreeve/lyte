import Foundation

/// Everything negotiated by /launch (or /resume) that the streaming session needs.
public struct StreamContext: Sendable {
    public let appID: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrateKbps: Int
    public let packetSize: Int
    public let riKey: Data           // 16-byte AES session key (we generate)
    public let riKeyID: Int32        // IV seed (we generate)
    public let rtspSessionURL: String
    public let isSunshine: Bool
    public let serverCodecModeSupport: Int
    public let localAddress: String  // host address we talk to

    public var encryptedRtsp: Bool { rtspSessionURL.hasPrefix("rtspenc://") }

    /// Port from the RTSP session URL (default 48010).
    public var rtspPort: Int {
        guard let comps = URLComponents(string: rtspSessionURL), let port = comps.port else {
            return 48010
        }
        return port
    }
}

public extension HostClient {
    /// Launch an app on the host. Generates the session AES key (rikey/rikeyid)
    /// that encrypts the control/input streams.
    func launch(appID: String, width: Int, height: Int, fps: Int,
                bitrateKbps: Int, sops: Bool = false) async throws -> StreamContext {
        let riKey = Data.random(count: 16)
        let riKeyID = Int32(bitPattern: UInt32.random(in: 0...UInt32.max))

        var query = baseQuery + [
            ("appid", appID),
            ("mode", "\(width)x\(height)x\(fps)"),
            ("additionalStates", "1"),
            ("sops", sops ? "1" : "0"),
            ("rikey", riKey.hexString),
            ("rikeyid", "\(riKeyID)"),
            ("localAudioPlayMode", "0"),
            ("surroundAudioInfo", "\(surroundAudioInfo(channels: 2, mask: 0x3))"),
            ("remoteControllersBitmap", "0"),
            ("gcmap", "0"),
            ("gcpersist", "0"),
        ]
        query.append(("corever", "1"))    // Sunshine: video + control-v2 encryption capable

        let xml = try await http.get("launch", query: query, https: true)
        guard xml["gamesession"] != nil && xml["gamesession"] != "0" else {
            throw LyteError.host("launch rejected: \(xml.statusMessage ?? "no gamesession")")
        }
        return context(appID: appID, width: width, height: height, fps: fps,
                       bitrateKbps: bitrateKbps, riKey: riKey, riKeyID: riKeyID,
                       sessionURL: xml["sessionUrl0"])
    }

    /// Resume the already-running app.
    func resume(appID: String, width: Int, height: Int, fps: Int,
                bitrateKbps: Int) async throws -> StreamContext {
        let riKey = Data.random(count: 16)
        let riKeyID = Int32(bitPattern: UInt32.random(in: 0...UInt32.max))
        var query = baseQuery + [
            ("rikey", riKey.hexString),
            ("rikeyid", "\(riKeyID)"),
            ("surroundAudioInfo", "\(surroundAudioInfo(channels: 2, mask: 0x3))"),
        ]
        query.append(("corever", "1"))
        let xml = try await http.get("resume", query: query, https: true)
        guard xml["resume"] != nil && xml["resume"] != "0" else {
            throw LyteError.host("resume rejected: \(xml.statusMessage ?? "?")")
        }
        return context(appID: appID, width: width, height: height, fps: fps,
                       bitrateKbps: bitrateKbps, riKey: riKey, riKeyID: riKeyID,
                       sessionURL: xml["sessionUrl0"])
    }

    /// Quit the running app.
    func cancel() async throws {
        _ = try await http.get("cancel", query: baseQuery, https: true)
    }

    private func context(appID: String, width: Int, height: Int, fps: Int,
                         bitrateKbps: Int, riKey: Data, riKeyID: Int32,
                         sessionURL: String?) -> StreamContext {
        StreamContext(
            appID: appID, width: width, height: height, fps: fps,
            bitrateKbps: bitrateKbps,
            packetSize: 1392,                        // LAN default, multiple of 16
            riKey: riKey, riKeyID: riKeyID,
            rtspSessionURL: sessionURL ?? "rtsp://\(http.address):48010",
            isSunshine: true,
            serverCodecModeSupport: 0,
            localAddress: http.address
        )
    }

    private func surroundAudioInfo(channels: Int, mask: Int) -> Int {
        (mask << 16) | channels
    }
}
