// CL-5: the browse surfaced. `lyte-cli wire-discover` lists every
// `_lyte._udp` advertiser on the LAN with its resolved address, SRV
// port, and TXT identity (v/pkh) — the scriptable gate evidence for the
// HS-10 advertisement, and the operator's answer to "what Lyte hosts can
// this Mac see". Pass --pinned-key (the same 64-hex static the wire-view
// --host-key takes) and each row says whether its advertised identity
// hash matches — recognition of an already-pinned host from the browse
// list alone, before any packet flows. Manual host:port everywhere else
// remains the always-working fallback; this command only observes.

import ArgumentParser
import Foundation
import LyteTransport
import LyteWire

struct WireDiscover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-discover",
        abstract: "Find Lyte hosts on the LAN (_lyte._udp via Bonjour).")

    @Option(name: .shortAndLong, help: "Seconds to browse")
    var seconds: Double = 3.0
    @Option(name: .long,
            help: "A pinned host static public key (64 hex digits) to recognize in the results")
    var pinnedKey: String?

    func run() async throws {
        let pinned: [UInt8]? = try pinnedKey.map {
            try NoiseTransportCrypto.parseKeyHex($0)
        }

        let hosts = await LyteDiscovery.browse(duration: seconds)
        if hosts.isEmpty {
            print("No Lyte hosts found. (Manual host:port always works — "
                + "e.g. `lyte-cli wire-view PORT --host ADDR --host-key HEX`.)")
            return
        }
        for host in hosts {
            var fields = ["\(host.name)", "\(host.address):\(host.port)"]
            if let v = host.wireVersion {
                let compat = host.speaksOurWireVersion
                    ? "" : " (client speaks v\(WireVersion.major))"
                fields.append("v=\(v)\(compat)")
            } else {
                fields.append("v=?")
            }
            fields.append("pkh=\(host.publicKeyHash ?? "?")")
            if let pinned {
                fields.append(host.matches(pinnedStaticPublicKey: pinned)
                    ? "PINNED-KEY MATCH" : "not the pinned key")
            }
            print(fields.joined(separator: "  "))
        }
    }
}
