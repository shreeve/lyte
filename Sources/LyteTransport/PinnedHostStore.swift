// The client's pinned-host keystore (CL-6): which Noise static public
// keys pairing has promoted to trusted, keyed by the host's identity
// hash (the same sha256-of-static the _lyte._udp TXT `pkh` advertises,
// so discovery recognition is a dictionary lookup). The mirror of the
// host's `paired_clients`: one JSON file, human-inspectable, atomic
// writes. Public keys only — nothing here is secret (the client's own
// private half lives in the Keychain, ClientNoiseIdentity), so a plain
// file under Application Support is the right shelf, same as
// ClientStore's precedent.
//
// Unpairing is a local trust decision: removing the entry means this
// client no longer dials that static without re-pairing. The host's own
// keystore keeps its side until the operator prunes it there — the two
// ends' trust stores are deliberately independent.

import Foundation
import LyteWire

/// One pinned host: everything reconnect needs (address/port are the
/// last-known dial hints; the KEY is the identity — a host that moved
/// addresses is still the same pinned host).
public struct PinnedHost: Codable, Equatable, Sendable {
    /// Bonjour instance name at pairing time (display only).
    public var name: String
    /// Last-known address and Lyte-UDP port.
    public var address: String
    public var port: UInt16
    /// The pinned Noise static public key, 64 lowercase hex digits.
    public var staticPublicKeyHex: String
    /// ISO-8601 stamp of the pairing, for the operator's benefit.
    public var pairedAt: String
    /// Per-host session-start posture (CL-13; semantics flipped by
    /// CL-18). Since CL-18 the app's DEFAULT posture is host-muted —
    /// sound follows the viewer — so this preference is now the
    /// "start audible" OPT-OUT: nil (unset) and true both mean start
    /// muted; an explicit false means start audible. Migration is by
    /// construction: CL-13's setters only ever wrote true or nil
    /// (false was mapped to nil), so no existing file carries a
    /// false — stored trues keep their meaning verbatim and only the
    /// unset default flips. Optional so pre-CL-13 files decode
    /// unchanged. The strip's toggle is the live override — this only
    /// seeds the connect. `sessionStartHostAudioRouting` is the one
    /// reading of these three states.
    public var startHostAudioMuted: Bool?
    /// Per-host clipboard consent (CL-15): start sessions against
    /// THIS host with clipboard sharing ON. Optional so older files
    /// decode unchanged; nil and false both mean OFF — clipboards
    /// carry passwords, so the default is silence. The strip's toggle
    /// is the live override — this only seeds the connect.
    public var shareClipboard: Bool?

    public init(name: String, address: String, port: UInt16,
                staticPublicKeyHex: String, pairedAt: String,
                startHostAudioMuted: Bool? = nil,
                shareClipboard: Bool? = nil) {
        self.name = name
        self.address = address
        self.port = port
        self.staticPublicKeyHex = staticPublicKeyHex
        self.pairedAt = pairedAt
        self.startHostAudioMuted = startHostAudioMuted
        self.shareClipboard = shareClipboard
    }

    /// The raw 32-byte static, decoded from the stored hex.
    public var staticPublicKey: [UInt8]? {
        let hex = staticPublicKeyHex
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// The TXT-record identity hash of the pinned static — what browse
    /// results carry, so recognition never touches the network.
    public var publicKeyHash: String? {
        staticPublicKey.map { LyteDiscovery.publicKeyHash(ofStaticPublicKey: $0) }
    }

    /// The session-start posture this host's preference asks for
    /// (CL-18): the one place the tri-state is read. Unset and true
    /// both mean `.hostMuted` (the flipped default — the
    /// Sunshine/Moonlight posture); only an explicit false — the
    /// "start audible" opt-out — means `.hostAudible`. Lands on
    /// `desiredHostAudioRouting` at connect; inert against a
    /// no-key-9 host (the ask never fires without the host's 0x19).
    public var sessionStartHostAudioRouting: HostAudioRoutingMode {
        startHostAudioMuted == false ? .hostAudible : .hostMuted
    }
}

/// The keystore: pinned hosts keyed by identity hash. Load–mutate–save,
/// like ClientStore; the file is small and pairing is rare.
public struct PinnedHostStore: Codable, Equatable, Sendable {
    /// pkh (64 lowercase hex) → the pinned host.
    public var hosts: [String: PinnedHost]

    public init(hosts: [String: PinnedHost] = [:]) {
        self.hosts = hosts
    }

    /// The production shelf, beside ClientStore's client.json.
    public static var url: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Lyte/pinned_hosts.json")
    }

    public static func load(from url: URL = Self.url) -> PinnedHostStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(PinnedHostStore.self, from: data)
        else {
            return PinnedHostStore()
        }
        return store
    }

    public func save(to url: URL = Self.url) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Trust operations

    /// Pins one host static (or refreshes its dial hints when the key
    /// was already pinned; per-host preferences survive the refresh —
    /// a re-pair is a trust event, not a settings reset). Returns true
    /// when the key is NEW.
    @discardableResult
    public mutating func pin(
        staticPublicKey: [UInt8], name: String, address: String,
        port: UInt16, pairedAt: String
    ) -> Bool {
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: staticPublicKey)
        let hex = staticPublicKey.map { String(format: "%02x", $0) }.joined()
        let fresh = hosts[pkh] == nil
        hosts[pkh] = PinnedHost(
            name: name, address: address, port: port,
            staticPublicKeyHex: hex, pairedAt: pairedAt,
            startHostAudioMuted: hosts[pkh]?.startHostAudioMuted,
            shareClipboard: hosts[pkh]?.shareClipboard)
        return fresh
    }

    /// Sets the per-host session-start posture (CL-13). Returns false
    /// when the hash is not pinned (nothing to hang the preference on).
    @discardableResult
    public mutating func setStartHostAudioMuted(
        publicKeyHash: String, muted: Bool?
    ) -> Bool {
        let key = publicKeyHash.lowercased()
        guard hosts[key] != nil else { return false }
        hosts[key]?.startHostAudioMuted = muted
        return true
    }

    /// Sets the per-host clipboard consent (CL-15). Returns false
    /// when the hash is not pinned.
    @discardableResult
    public mutating func setShareClipboard(
        publicKeyHash: String, share: Bool?
    ) -> Bool {
        let key = publicKeyHash.lowercased()
        guard hosts[key] != nil else { return false }
        hosts[key]?.shareClipboard = share
        return true
    }

    /// Removes the pinned entry. Returns the removed host, nil when the
    /// hash was not pinned.
    @discardableResult
    public mutating func unpin(publicKeyHash: String) -> PinnedHost? {
        hosts.removeValue(forKey: publicKeyHash.lowercased())
    }

    /// The pinned host advertising this identity hash, if any — the
    /// discovery-recognition lookup.
    public func host(publicKeyHash: String?) -> PinnedHost? {
        publicKeyHash.flatMap { hosts[$0.lowercased()] }
    }

    /// The pinned host last seen at this address (name or IP,
    /// case-insensitive) — the manual-dial lookup when no advertisement
    /// is in hand. Address collisions resolve to the most recent pairing.
    public func host(address: String) -> PinnedHost? {
        hosts.values
            .filter {
                $0.address.caseInsensitiveCompare(address) == .orderedSame
                    || $0.name.caseInsensitiveCompare(address) == .orderedSame
            }
            .max { $0.pairedAt < $1.pairedAt }
    }
}
