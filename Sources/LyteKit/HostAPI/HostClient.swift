import Foundation

public struct ServerInfo: Sendable {
    public let hostname: String
    public let appVersion: String
    public let gfeVersion: String
    public let uniqueID: String
    public let mac: String
    public let localIP: String?
    public let httpsPort: Int
    public let externalPort: Int?
    public let codecModeSupport: Int
    public let pairStatus: Bool
    public let state: String
    public let currentGame: String?

    /// Sunshine convention: negative 4th component of the version quad.
    public var isSunshine: Bool {
        appVersion.split(separator: ".").last.map { $0.hasPrefix("-") || (Int($0) ?? 0) < 0 } ?? false
    }
}

public struct NvApp: Sendable {
    public let id: String
    public let title: String
}

/// High-level host API on top of NvHTTP.
public struct HostClient: Sendable {
    public let http: NvHTTP
    public let uniqueID: String

    public init(address: String, uniqueID: String,
                identity: ClientIdentity? = nil, pinnedServerCertDER: Data? = nil) {
        self.http = NvHTTP(address: address, identity: identity,
                           pinnedServerCertDER: pinnedServerCertDER)
        self.uniqueID = uniqueID
    }

    var baseQuery: [(String, String)] {
        [("uniqueid", uniqueID), ("uuid", UUID().uuidString.replacingOccurrences(of: "-", with: ""))]
    }

    public func serverInfo(https: Bool) async throws -> ServerInfo {
        let xml = try await http.get("serverinfo", query: baseQuery, https: https)
        return ServerInfo(
            hostname: xml["hostname"] ?? http.address,
            appVersion: xml["appversion"] ?? "",
            gfeVersion: xml["GfeVersion"] ?? "",
            uniqueID: xml["uniqueid"] ?? "",
            mac: xml["mac"] ?? "",
            localIP: xml["LocalIP"],
            httpsPort: Int(xml["HttpsPort"] ?? "") ?? 47984,
            externalPort: Int(xml["ExternalPort"] ?? ""),
            codecModeSupport: Int(xml["ServerCodecModeSupport"] ?? "") ?? 0,
            pairStatus: xml["PairStatus"] == "1",
            state: xml["state"] ?? "",
            currentGame: xml["currentgame"]
        )
    }

    public func appList() async throws -> [NvApp] {
        let xml = try await http.get("applist", query: baseQuery, https: true)
        return xml.apps.map { NvApp(id: $0.id, title: $0.title) }
    }
}
