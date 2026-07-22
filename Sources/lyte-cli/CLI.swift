import AppKit
import ArgumentParser
import Foundation
import LyteUI

struct LyteCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lyte-cli",
        abstract: "Lyte development CLI — discover, pair with, and stream from Lyte-UDP hosts.",
        subcommands: [WireListen.self, WireView.self, WireSend.self, WireDiscover.self, WirePair.self, WireUnpair.self]
    )
}

/// Custom entry point instead of `@main LyteCLI`. AppKit UI (the `wire-view`
/// window) requires NSApplication.run() on the raw main thread: if it runs
/// inside a Swift-concurrency MainActor job (which is where an
/// AsyncParsableCommand's `run()` executes), the main dispatch queue can never
/// drain — AVSampleBufferDisplayLayer never attaches decoded frames (black
/// window) and DispatchQueue.main work is silently dropped. So: parse
/// synchronously, run the command as a Task, and give the main thread to
/// AppKit (for `wire-view`) or to dispatchMain() (for everything else).
@main
enum Main {
    static func main() {
        // wire-view opens a render window and needs NSApplication.run()
        // on the raw main thread; everything else is headless.
        let firstArg = CommandLine.arguments.dropFirst().first ?? ""
        let wantsAppKit = firstArg == "wire-view"
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
