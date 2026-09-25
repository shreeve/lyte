import AppKit
import ArgumentParser
import Foundation
import LyteUI

struct LyteCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lyte-cli",
        abstract: "Lyte development CLI — pair with and stream from Lyte-UDP hosts.",
        subcommands: [WireView.self, WirePair.self]
    )
}

/// Custom entry point instead of `@main`: AppKit UI requires
/// NSApplication.run() on the raw main thread. Inside a MainActor job
/// (where an AsyncParsableCommand's `run()` executes) the main dispatch
/// queue never drains — the display layer shows black and
/// DispatchQueue.main work is dropped. So: parse synchronously, run the
/// command as a Task, and give the main thread to AppKit or
/// dispatchMain().
@main
enum Main {
    static func main() {
        // wire-view opens a render window and needs NSApplication.run()
        // on the raw main thread; everything else is headless.
        if CommandLine.arguments.dropFirst().first == "wire-view" {
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
