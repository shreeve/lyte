import HostIO

/// Every line lyte-host prints carries its UTC instant: host.log is the
/// service's only record, and recoveries, blackouts and handshakes must be
/// placed in time and against the client's log. One write per call, so a
/// line never interleaves with another thread's.
func print(
    _ items: Any..., separator: String = " ", terminator: String = "\n"
) {
    let text = items.map { "\($0)" }.joined(separator: separator)
    Swift.print(
        HostLog.stamped(text, unixNanoseconds: HostLog.nowUnixNanoseconds),
        terminator: terminator)
}
