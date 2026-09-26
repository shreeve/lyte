/// Walks a command line after its program name: the next flag, and each
/// flag's value parsed or refused with a reason that names the flag.
struct ArgumentCursor {
    private var rest: ArraySlice<String>

    init(_ args: ArraySlice<String>) { rest = args }

    mutating func next() -> String? { rest.popFirst() }

    /// The argument after `flag` through `parse`; a missing or refused
    /// value throws "`flag` needs `want`".
    mutating func value<T>(
        _ flag: String, _ want: String, _ parse: (String) -> T?
    ) throws -> T {
        guard let raw = rest.popFirst(), let value = parse(raw) else {
            throw HostError("\(flag) needs \(want)")
        }
        return value
    }

    /// A finite number above zero ("inf" and "nan" parse as Doubles).
    mutating func positive(_ flag: String) throws -> Double {
        try value(flag, "a positive number") {
            Double($0).flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        }
    }

    mutating func port(_ flag: String) throws -> UInt16 {
        try value(flag, "a port, 1-65535") {
            UInt16($0).flatMap { $0 > 0 ? $0 : nil }
        }
    }
}
