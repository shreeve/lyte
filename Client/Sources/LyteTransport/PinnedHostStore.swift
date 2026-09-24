// The client's pinned-host keystore: Noise static public keys promoted to
// trusted by pairing, keyed by the identity hash the _lyte._udp TXT `pkh`
// advertises. One JSON file with atomic writes; public keys only, so a
// plain file under Application Support suffices. Unpairing is local: the
// two ends' trust stores are independent.

import Foundation
import LyteClientCore
import LyteCore
import LyteWire

/// One pinned host. The key is the identity; address/port are only the
/// last-known dial hints.
public struct PinnedHost: Codable, Equatable, Sendable {
    /// Bonjour instance name at pairing time (display only).
    public var name: String
    /// Last-known address and Lyte-UDP port.
    public var address: String
    public var port: UInt16
    /// The pinned Noise static public key, 64 lowercase hex digits.
    public var staticPublicKeyHex: String
    /// ISO-8601 stamp of the pairing.
    public var pairedAt: String
    /// Per-host session-start posture: nil and true mean start muted; an
    /// explicit false means start audible. Read only through
    /// `sessionStartHostAudioRouting`. Optional fields below decode older
    /// files unchanged and only seed the connect.
    public var startHostAudioMuted: Bool?
    /// Per-host clipboard consent; nil and false both mean off.
    public var shareClipboard: Bool?
    /// The images rung, meaningful only with `shareClipboard` true; nil
    /// and false both mean text-only.
    public var shareClipboardImages: Bool?
    /// Per-host ChromaTier rawValue; a raw string so an unknown future
    /// tier still decodes. Nil means Good. Read only through
    /// `sessionChromaTier`.
    public var chromaTier: String?

    public init(name: String, address: String, port: UInt16,
                staticPublicKeyHex: String, pairedAt: String,
                startHostAudioMuted: Bool? = nil,
                shareClipboard: Bool? = nil,
                shareClipboardImages: Bool? = nil,
                chromaTier: String? = nil) {
        self.name = name
        self.address = address
        self.port = port
        self.staticPublicKeyHex = staticPublicKeyHex
        self.pairedAt = pairedAt
        self.startHostAudioMuted = startHostAudioMuted
        self.shareClipboard = shareClipboard
        self.shareClipboardImages = shareClipboardImages
        self.chromaTier = chromaTier
    }

    /// The raw 32-byte static, decoded from the stored hex.
    public var staticPublicKey: [UInt8]? {
        guard staticPublicKeyHex.count == 64,
              let bytes = Hex.bytes(staticPublicKeyHex),
              bytes.count == 32
        else { return nil }
        return bytes
    }

    /// The TXT-record identity hash of the pinned static — what browse
    /// results carry, so recognition never touches the network.
    public var publicKeyHash: String? {
        staticPublicKey.map { LyteDiscovery.publicKeyHash(ofStaticPublicKey: $0) }
    }

    /// Only an explicit false means `.hostAudible`.
    public var sessionStartHostAudioRouting: HostAudioRoutingMode {
        startHostAudioMuted == false ? .hostAudible : .hostMuted
    }

    /// Unset, unknown, and unselectable values all land on Good.
    public var sessionChromaTier: ChromaTier {
        guard let raw = chromaTier,
              let tier = ChromaTier(rawValue: raw),
              tier.isSelectable else { return .good }
        return tier
    }
}

/// Pinned hosts keyed by identity hash; load–mutate–save.
public struct PinnedHostStore: Codable, Equatable, Sendable {
    /// pkh (64 lowercase hex) → the pinned host.
    public var hosts: [String: PinnedHost]

    public init(hosts: [String: PinnedHost] = [:]) {
        self.hosts = hosts
    }

    public static var url: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Lyte/pinned_hosts.json")
    }

    /// The store at `url`; empty when the file is absent. A present
    /// file that cannot be read or decoded is quarantined first (see
    /// `loadQuarantiningUnreadable`), so a later `save` never
    /// overwrites the only copy of the pins.
    public static func load(from url: URL = Self.url) -> PinnedHostStore {
        loadQuarantiningUnreadable(from: url).store
    }

    /// `load`, also naming where an unreadable file was renamed aside
    /// (`<name>.corrupt-<UTC stamp>`, never deleted); nil when absent,
    /// decoded, or the rename failed.
    public static func loadQuarantiningUnreadable(
        from url: URL = Self.url
    ) -> (store: PinnedHostStore, quarantinedTo: URL?) {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else {
            return (PinnedHostStore(), nil)
        }
        if let data = try? Data(contentsOf: url),
           var store = try? JSONDecoder().decode(
               PinnedHostStore.self, from: data) {
            // Recognition looks hosts up by key: an entry keyed by any
            // hash but its own static's would dial a different key.
            store.hosts = store.hosts.filter {
                $0.value.publicKeyHash == $0.key.lowercased()
            }
            return (store, nil)
        }
        return (PinnedHostStore(), quarantine(url))
    }

    private static func quarantine(_ url: URL) -> URL? {
        let stamp = Date().formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: false)
                .dateTimeSeparator(.standard).timeSeparator(.omitted)
                .dateSeparator(.omitted))
        let base = "\(url.lastPathComponent).corrupt-\(stamp)"
        let directory = url.deletingLastPathComponent()
        for attempt in 0..<100 {
            let name = attempt == 0 ? base : "\(base)-\(attempt)"
            let target = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: target.path)
            else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: target)
                return target
            } catch {
                return nil
            }
        }
        return nil
    }

    public func save(to url: URL = Self.url) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        // Host names and LAN addresses are the owner's business.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Trust operations

    /// Pins one host static, or refreshes its dial hints (preferences
    /// survive a re-pair). Returns true when the key is new.
    @discardableResult
    public mutating func pin(
        staticPublicKey: [UInt8], name: String, address: String,
        port: UInt16, pairedAt: String
    ) -> Bool {
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: staticPublicKey)
        let hex = Hex.string(staticPublicKey)
        let fresh = hosts[pkh] == nil
        hosts[pkh] = PinnedHost(
            name: name, address: address, port: port,
            staticPublicKeyHex: hex, pairedAt: pairedAt,
            startHostAudioMuted: hosts[pkh]?.startHostAudioMuted,
            shareClipboard: hosts[pkh]?.shareClipboard,
            shareClipboardImages: hosts[pkh]?.shareClipboardImages,
            chromaTier: hosts[pkh]?.chromaTier)
        return fresh
    }

    /// The per-host setters return false when the hash is not pinned.
    @discardableResult
    public mutating func setStartHostAudioMuted(
        publicKeyHash: String, muted: Bool?
    ) -> Bool {
        let key = publicKeyHash.lowercased()
        guard hosts[key] != nil else { return false }
        hosts[key]?.startHostAudioMuted = muted
        return true
    }

    @discardableResult
    public mutating func setShareClipboard(
        publicKeyHash: String, share: Bool?
    ) -> Bool {
        let key = publicKeyHash.lowercased()
        guard hosts[key] != nil else { return false }
        hosts[key]?.shareClipboard = share
        return true
    }

    /// Text-only writes nil.
    @discardableResult
    public mutating func setShareClipboardImages(
        publicKeyHash: String, share: Bool?
    ) -> Bool {
        let key = publicKeyHash.lowercased()
        guard hosts[key] != nil else { return false }
        hosts[key]?.shareClipboardImages = share == true ? true : nil
        return true
    }

    /// Good writes nil.
    @discardableResult
    public mutating func setChromaTier(
        publicKeyHash: String, tier: ChromaTier
    ) -> Bool {
        let key = publicKeyHash.lowercased()
        guard hosts[key] != nil else { return false }
        hosts[key]?.chromaTier = tier == .good ? nil : tier.rawValue
        return true
    }

    /// Removes the pinned entry. Returns the removed host, nil when the
    /// hash was not pinned.
    @discardableResult
    public mutating func unpin(publicKeyHash: String) -> PinnedHost? {
        hosts.removeValue(forKey: publicKeyHash.lowercased())
    }

    /// The pinned host advertising this identity hash, if any.
    public func host(publicKeyHash: String?) -> PinnedHost? {
        publicKeyHash.flatMap { hosts[$0.lowercased()] }
    }

    /// The pinned host last seen at this address or name
    /// (case-insensitive); collisions resolve to the most recent pairing.
    public func host(address: String) -> PinnedHost? {
        hosts.values
            .filter {
                $0.address.caseInsensitiveCompare(address) == .orderedSame
                    || $0.name.caseInsensitiveCompare(address) == .orderedSame
            }
            .max { $0.pairedAt < $1.pairedAt }
    }
}
