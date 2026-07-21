import AppKit
import ArgumentParser
import Foundation
import LyteKit
import LyteUI

struct LyteCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lyte-cli",
        abstract: "Lyte development CLI — stream from, pair with, and poke Sunshine hosts.",
        subcommands: [Discover.self, Info.self, Pair.self, Apps.self, Launch.self, Stream.self, Quit.self, Unpair.self, WireListen.self, WireView.self, WireSend.self],
        defaultSubcommand: Stream.self
    )

}

/// Accept Bonjour names, .local names, hostnames, or IPs anywhere an address
/// is expected: bare names that don't resolve in DNS are matched against
/// discovered _nvstream._tcp services (so `lyte-cli pop` just works).
enum HostAddress {
    static func resolve(_ input: String) async -> String {
        // IPs and dotted names go straight through (the system resolver
        // handles mDNS for .local)
        if input.contains(".") || input.contains(":") { return input }
        let found = await LyteKit.Discovery.browse(duration: 2.0)
        if let match = found.first(where: { $0.name.caseInsensitiveCompare(input) == .orderedSame }) {
            return match.endpoint
        }
        return input
    }
}

/// Custom entry point instead of `@main LyteCLI`. AppKit UI (the `stream`
/// window) requires NSApplication.run() on the raw main thread: if it runs
/// inside a Swift-concurrency MainActor job (which is where an
/// AsyncParsableCommand's `run()` executes), the main dispatch queue can never
/// drain — AVSampleBufferDisplayLayer never attaches decoded frames (black
/// window) and DispatchQueue.main work is silently dropped. So: parse
/// synchronously, run the command as a Task, and give the main thread to
/// AppKit (for `stream`) or to dispatchMain() (for everything else).
@main
enum Main {
    static func main() {
        // `stream` is the default subcommand, so the UI path is "anything
        // that isn't explicitly one of the non-UI subcommands (or help)".
        // wire-view stays off this list: it opens a render window and
        // needs NSApplication.run() on the raw main thread.
        let nonUI: Set<String> = ["discover", "info", "pair", "apps", "launch",
                                  "quit", "unpair", "wire-listen", "wire-send",
                                  "help", "--help", "-h", "--version"]
        let firstArg = CommandLine.arguments.dropFirst().first ?? ""
        let wantsAppKit = !firstArg.isEmpty && !nonUI.contains(firstArg)
        if wantsAppKit {
            // Unbundled binaries inherit the launcher's app identity in the
            // menu bar ("iTerm2" / "lyte-cli"). Rename the LaunchServices
            // registration before AppKit spins up so the menu bar says Lyte.
            ProcessInfo.processInfo.processName = "Lyte"
            let app = NSApplication.shared   // create on the main thread
            ProcessName.set("Lyte")          // must run after LS registration exists
            Task { @MainActor in
                await runParsedCommand()
                // A UI command that returns keeps running until its exit paths
                // (window close / duration timer) call exit().
            }
            app.run()
        } else {
            Task {
                await runParsedCommand()
                Foundation.exit(0)
            }
            dispatchMain()
        }
    }

    private static func runParsedCommand() async {
        do {
            var command = try LyteCLI.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            LyteCLI.exit(withError: error)
        }
    }
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

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String

    func run() async throws {
        let address = await HostAddress.resolve(host)
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

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String

    func run() async throws {
        let address = await HostAddress.resolve(host)
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

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String

    func run() async throws {
        let address = await HostAddress.resolve(host)
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

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String

    func run() async throws {
        let address = await HostAddress.resolve(host)
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

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Launch an app and hold a live session (RTSP + control channel).")

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String
    @Argument(help: "App name (e.g. Desktop) or numeric ID") var app: String = "Desktop"
    @Option(name: .long) var width: Int = 2048
    @Option(name: .long) var height: Int = 1280
    @Option(name: .long) var fps: Int = 60
    @Option(name: .long, help: "Bitrate in Kbps") var bitrate: Int = 40000
    @Option(name: .long, help: "Seconds to hold the session") var duration: Int = 30

    func run() async throws {
        let address = await HostAddress.resolve(host)
        let store = ClientStore.load()
        guard let host = store.host(address), let pinned = host.serverCertDER,
              let identity = store.identity() else {
            throw ValidationError("Not paired with \(address).")
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID,
                                identity: identity, pinnedServerCertDER: pinned)

        // Resolve app name -> ID
        let apps = try await client.appList()
        guard let target = apps.first(where: { $0.title.caseInsensitiveCompare(app) == .orderedSame || $0.id == app }) else {
            throw ValidationError("App not found. Available: \(apps.map(\.title).joined(separator: ", "))")
        }

        // Launch or resume depending on host state
        let info = try await client.serverInfo(https: true)
        let context: StreamContext
        if let current = info.currentGame, current != "0", !current.isEmpty {
            print("Host busy (app \(current)) — resuming")
            context = try await client.resume(appID: target.id, width: width, height: height,
                                              fps: fps, bitrateKbps: bitrate)
        } else {
            context = try await client.launch(appID: target.id, width: width, height: height,
                                              fps: fps, bitrateKbps: bitrate)
        }
        print("launched \(target.title): rtsp url \(context.rtspSessionURL)")
        // Session key material — pairs a packet capture with the bytes needed
        // to unseal it (golden-transcript rig, PLAN §7 / HOST-PLAN §4).
        print("rikey \(context.riKey.hexString) rikeyid \(context.riKeyID)")
        fflush(stdout)

        // RTSP handshake, starting UDP pings once ports are known
        let pingers = PingerBox()
        let handshake = RtspHandshake(context: context)
        let params = try await handshake.perform(onPortsKnown: { audioPort, videoPort, audioPing, videoPing in
            if let audioPing {
                let p = UdpPinger(host: context.localAddress, port: audioPort, pingPayload: audioPing)
                p.start(); pingers.add(p)
            }
            if let videoPing {
                let p = UdpPinger(host: context.localAddress, port: videoPort, pingPayload: videoPing)
                p.start(); pingers.add(p)
            }
        }, log: { print("rtsp: \($0)"); fflush(stdout) })

        // Control channel
        let control = try ControlChannel(
            host: context.localAddress, port: params.controlPort,
            connectData: params.controlConnectData, riKey: context.riKey,
            encryptionEnabled: params.encryptionEnabled | SSEnc.controlV2
        ) { event in
            switch event {
            case .connected: print("control: connected")
            case .hostMessage(let type, let payload):
                print("control: host message 0x\(String(type, radix: 16)) (\(payload.count) bytes)")
            case .terminated(let code): print("control: TERMINATED by host, code \(code)")
            case .disconnected: print("control: disconnected")
            }
            fflush(stdout)
        }
        try control.start()
        print("session live — holding for \(duration)s (pings on audio/video/control)")
        fflush(stdout)

        try await Task.sleep(for: .seconds(duration))

        control.stop()
        pingers.stopAll()
        print("session closed cleanly after \(duration)s")
    }
}

struct Quit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit the running app on the host.")

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String

    func run() async throws {
        let address = await HostAddress.resolve(host)
        let store = ClientStore.load()
        guard let host = store.host(address), let pinned = host.serverCertDER,
              let identity = store.identity() else {
            throw ValidationError("Not paired with \(address).")
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID,
                                identity: identity, pinnedServerCertDER: pinned)
        try await client.cancel()
        print("quit requested")
    }
}

final class PingerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pingers: [UdpPinger] = []
    func add(_ p: UdpPinger) { lock.lock(); pingers.append(p); lock.unlock() }
    func stopAll() { lock.lock(); pingers.forEach { $0.stop() }; pingers.removeAll(); lock.unlock() }
}
