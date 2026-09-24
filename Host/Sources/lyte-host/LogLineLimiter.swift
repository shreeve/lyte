// A rate limit for log lines a peer can cause once per datagram. Any
// sender that reaches the session port can make a drop line per packet,
// and those lines are written from the SCHED_RR sender thread into
// host.log; a flood must cost a bounded number of writes.

/// The first `burst` lines of each key print; after that the key's lines
/// are only counted, and one summary per `intervalNS` carries the count.
/// Pure value state: the caller owns the clock and the lock.
struct LogLineLimiter {
    let burst: Int
    let intervalNS: UInt64

    private struct Book {
        var printed = 0
        var suppressed = 0
        var windowStartNS: UInt64
    }
    private var books: [String: Book] = [:]

    init(burst: Int = 3, intervalNS: UInt64 = 10_000_000_000) {
        self.burst = burst
        self.intervalNS = intervalNS
    }

    /// The lines one occurrence of `key` emits: its own line while the
    /// burst lasts, then nothing until an interval has passed, when a
    /// summary counts everything suppressed since the last one.
    mutating func admit(
        _ key: String, now: UInt64, line: () -> String
    ) -> [String] {
        var book = books[key] ?? Book(windowStartNS: now)
        defer { books[key] = book }
        if book.printed < burst {
            book.printed += 1
            return [line()]
        }
        book.suppressed += 1
        guard now &- book.windowStartNS >= intervalNS else { return [] }
        return [Self.summary(key, &book, now: now)]
    }

    /// Summaries owed by keys whose interval has passed with lines
    /// suppressed (`final` owes every pending one, as a session ends).
    mutating func due(now: UInt64, final: Bool = false) -> [String] {
        var lines: [String] = []
        for key in books.keys.sorted() {
            guard var book = books[key], book.suppressed > 0,
                  final || now &- book.windowStartNS >= intervalNS
            else { continue }
            lines.append(Self.summary(key, &book, now: now))
            books[key] = book
        }
        return lines
    }

    private static func summary(
        _ key: String, _ book: inout Book, now: UInt64
    ) -> String {
        let seconds = (now &- book.windowStartNS) / 1_000_000_000
        let line = """
            \(key) — \(book.suppressed) more in the last \(seconds) s \
            (rate-limited)
            """
        book.suppressed = 0
        book.windowStartNS = now
        return line
    }
}
