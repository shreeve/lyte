import ArgumentParser
import Foundation
import LyteKit

@main
struct LyteCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lyte-cli",
        abstract: "Lyte development CLI — M1: pair with a Sunshine host and list apps.",
        subcommands: [Discover.self, Info.self, Pair.self, Apps.self, Unpair.self]
    )

}

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find Sunshine hosts via Bonjour.")

    @Option(name: .shortAndLong) var seconds: Double = 3.0

    func run() async throws {
        let hosts = await LyteKit.Discovery.browse(duration: seconds)
        if hosts.isEmpty { print("No hosts found."); return }
        for h in hosts { print("\(h.name)\t\(h.endpoint)") }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Query serverinfo.")

    @Argument(help: "Host address (IP or name)") var address: String

    func run() async throws {
        let store = ClientStore.load()
        let identity = store.identity()
        let pinned = store.host(address)?.serverCertDER
        let paired = identity != nil && pinned != nil
        let client = HostClient(address: address, uniqueID: store.uniqueID,
                                identity: identity, pinnedServerCertDER: pinned)
        let info = try await client.serverInfo(https: paired)
        print("""
        hostname:  \(info.hostname)
        version:   \(info.appVersion) \(info.isSunshine ? "(Sunshine)" : "(GFE?)")
        state:     \(info.state)
        paired:    \(info.pairStatus ? "yes" : "no")
        codecs:    0x\(String(info.codecModeSupport, radix: 16))
        mac:       \(info.mac)
        transport: \(paired ? "https (mutual TLS, pinned)" : "http (unpaired)")
        """)
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pair with a Sunshine host.")

    @Argument(help: "Host address (IP or name)") var address: String

    func run() async throws {
        var store = ClientStore.load()
        let identity: ClientIdentity
        if let existing = store.identity() {
            identity = existing
        } else {
            identity = try ClientIdentity.create()
            store.clientCertPEM = identity.certificatePEM
            try store.save()
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID)

        let pin = PairingSession.generatePIN()
        print("PIN: \(pin)")
        print("Enter this PIN in the Sunshine web UI: https://\(address):47990/pin")
        print("Waiting for PIN entry…")
        fflush(stdout)   // visible immediately even when piped

        let session = PairingSession(client: client, identity: identity)
        let result = try await session.pair(pin: pin)

        let info = try await HostClient(address: address, uniqueID: store.uniqueID,
                                        identity: identity,
                                        pinnedServerCertDER: result.serverCertDER)
            .serverInfo(https: true)
        store.upsert(ClientStore.Host(name: info.hostname, address: address,
                                      serverCertPEM: result.serverCertPEM, mac: info.mac),
                     key: address)
        try store.save()
        print("Paired with \(info.hostname) ✓  (server cert pinned, identity in Keychain)")
    }
}

struct Apps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List apps on a paired host.")

    @Argument(help: "Host address (IP or name)") var address: String

    func run() async throws {
        let store = ClientStore.load()
        guard let host = store.host(address), let pinned = host.serverCertDER else {
            throw ValidationError("Not paired with \(address) — run `lyte-cli pair \(address)` first.")
        }
        guard let identity = store.identity() else {
            throw ValidationError("No client identity — run `lyte-cli pair \(address)` first.")
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID,
                                identity: identity, pinnedServerCertDER: pinned)
        for app in try await client.appList() {
            print("\(app.id)\t\(app.title)")
        }
    }
}

struct Unpair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpair from a host.")

    @Argument(help: "Host address (IP or name)") var address: String

    func run() async throws {
        var store = ClientStore.load()
        guard let identity = store.identity() else {
            throw ValidationError("No client identity stored.")
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID, identity: identity)
        try await PairingSession(client: client, identity: identity).unpair()
        store.hosts.removeValue(forKey: address.lowercased())
        try store.save()
        print("Unpaired from \(address).")
    }
}
