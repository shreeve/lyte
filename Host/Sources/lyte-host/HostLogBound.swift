import HostIO

/// host.log's bound while the process runs (HostLog): checked at every
/// session boundary and on the janitor's slow cadence during a session,
/// so neither a long service nor one long session grows the log without
/// limit. A no-op unless stdout is the unit's host.log.
enum HostLogBound {
    private static let path: String? = try? HostPaths.current().state("host.log")

    static func check() {
        guard let path else { return }
        do {
            if try HostLog.rotateStandardOutputIfNeeded(path: path) {
                print("""
                    log: host.log passed \(HostLog.rotateAboveBytes >> 20) MiB \
                    — the previous lines are in host.log.1
                    """)
            }
        } catch {
            print("log: host.log rotation failed (\(error)) — still appending")
        }
    }
}
