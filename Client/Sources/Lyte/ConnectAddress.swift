import Foundation
import LyteTransport

/// A host address typed into the connection window: a host name or an
/// IPv4 literal, with an optional `:port`. The transport dials IPv4 only,
/// so an IPv6 literal is refused by name rather than failing at the dial.
struct TypedHostAddress: Equatable {
    /// The standing host service's port.
    static let defaultPort: UInt16 = 41_151

    let host: String
    /// nil when no port was typed: a paired host's pinned port, else
    /// `defaultPort`.
    let port: UInt16?

    enum Problem: Error, Equatable {
        case empty
        case badHost
        case badPort
        case ipv6

        var message: String {
            switch self {
            case .empty: "Type a host name or IPv4 address"
            case .badHost: "Not a host name or IPv4 address"
            case .badPort: "The port must be a number from 1 to 65535"
            case .ipv6: "Lyte dials IPv4 addresses and host names — not IPv6"
            }
        }
    }

    static func parse(_ text: String) -> Result<TypedHostAddress, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // A bracketed or many-colon form is IPv6, with or without a port.
        guard !trimmed.hasPrefix("["),
              trimmed.count(where: { $0 == ":" }) <= 1
        else { return .failure(.ipv6) }
        let parts = trimmed.split(
            separator: ":", omittingEmptySubsequences: false)
        let host = String(parts[0])
        var port: UInt16?
        if parts.count == 2 {
            guard parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let typed = UInt16(parts[1]), typed != 0
            else { return .failure(.badPort) }
            port = typed
        }
        guard isHostName(host) || isIPv4(host) else {
            return .failure(.badHost)
        }
        return .success(TypedHostAddress(host: host, port: port))
    }

    /// The paired host this text names, or was last seen at.
    func pinned(in store: PinnedHostStore) -> PinnedHost? {
        store.host(address: host)
    }

    /// Dials `pinned` at the typed address, or at its pinned address
    /// when the text is its name. Noise IK still verifies the host's
    /// pinned static, wherever the dial goes.
    func dialing(_ pinned: PinnedHost) -> DiscoveredLyteHost {
        let byName = pinned.name.caseInsensitiveCompare(host) == .orderedSame
            && pinned.address.caseInsensitiveCompare(host) != .orderedSame
        return DiscoveredLyteHost(
            name: pinned.name,
            address: byName ? pinned.address : host,
            port: port ?? pinned.port,
            wireVersion: nil,
            publicKeyHash: pinned.publicKeyHash)
    }

    /// A host no pin knows: the pairing sheet's target. It advertises no
    /// identity, so the sheet needs the host's key hand-carried.
    var unpaired: DiscoveredLyteHost {
        DiscoveredLyteHost(
            name: host, address: host, port: port ?? Self.defaultPort,
            wireVersion: nil, publicKeyHash: nil)
    }

    /// A dotted-quad string is judged as IPv4 alone, so `10.0.0.300`
    /// is refused rather than looked up as a name.
    private static func isHostName(_ text: String) -> Bool {
        guard text.count <= 253,
              !text.allSatisfy({ $0.isNumber || $0 == "." })
        else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                (1...63).contains(label.count)
                    && label.first != "-" && label.last != "-"
                    && label.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
                    }
            }
    }

    private static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }
}
