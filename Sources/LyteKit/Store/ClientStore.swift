import Foundation

/// Minimal persistent client state for M1 (JSON on disk).
/// The app (M5) replaces this with SwiftData; the file format is a stopgap.
public struct ClientStore: Codable, Sendable {
    public struct Host: Codable, Sendable {
        public var name: String
        public var address: String
        public var serverCertPEM: String?
        public var mac: String?

        public init(name: String, address: String, serverCertPEM: String? = nil, mac: String? = nil) {
            self.name = name
            self.address = address
            self.serverCertPEM = serverCertPEM
            self.mac = mac
        }

        public var serverCertDER: Data? {
            serverCertPEM.flatMap { try? PEM.der(fromPEM: $0) }
        }
    }

    public var uniqueID: String
    public var clientCertPEM: String?   // public half of the identity (key stays in Keychain)
    public var hosts: [String: Host]    // keyed by lowercase name or address

    /// Load the pairing identity referenced by this store, if present.
    public func identity() -> ClientIdentity? {
        clientCertPEM.flatMap { try? ClientIdentity.load(certificatePEM: $0) }
    }

    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyte/client.json")
    }

    public static func load() -> ClientStore {
        if let data = try? Data(contentsOf: url),
           let store = try? JSONDecoder().decode(ClientStore.self, from: data) {
            return store
        }
        // Fresh install: random per-install uniqueId (16 hex chars).
        return ClientStore(uniqueID: Data.random(count: 8).hexString, clientCertPEM: nil, hosts: [:])
    }

    public func save() throws {
        let dir = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    public func host(_ key: String) -> Host? {
        hosts[key.lowercased()]
    }

    public mutating func upsert(_ host: Host, key: String) {
        hosts[key.lowercased()] = host
    }
}
