import LyteCore
import LyteWire

/// Input waiting for the reliable CTRL stream, in capture order. Pointer
/// motion and scroll coalesce into a pending entry of the same kind at the
/// tail, so a stall replays one position rather than every move; key and
/// button edges and a scroll's finish are never merged, and none is lost
/// while the queue is under its bound, so a release the host must see
/// waits out a full reliable queue instead of being dropped.
struct BrowserInputQueue {
    struct Entry {
        var body: InputEvent.Body
        var capturedMicros: UInt64
    }

    /// About a second of 120 Hz edges; past it the session is dying.
    static let capacity = 256

    private var entries = Deque<Entry>()

    var first: Entry? { entries.first }
    var count: Int { entries.count }

    /// False when full: the event is refused.
    mutating func enqueue(_ body: InputEvent.Body, capturedMicros: UInt64) -> Bool {
        if let tail = entries.last,
           let merged = Self.coalesce(tail.body, body), merged.isFinite
        {
            entries[entries.count - 1] = Entry(
                body: merged, capturedMicros: capturedMicros)
            return true
        }
        guard entries.count < Self.capacity else { return false }
        entries.append(Entry(body: body, capturedMicros: capturedMicros))
        return true
    }

    mutating func removeFirst() {
        _ = entries.popFirst()
    }

    /// The one event that replaces `earlier` followed by `later`, or nil
    /// when both must cross.
    private static func coalesce(
        _ earlier: InputEvent.Body, _ later: InputEvent.Body
    ) -> InputEvent.Body? {
        switch (earlier, later) {
        case (.pointerMotionAbsolute, .pointerMotionAbsolute):
            return later
        case (.pointerMotionRelative(let dx0, let dy0),
              .pointerMotionRelative(let dx1, let dy1)):
            return .pointerMotionRelative(dx: dx0 + dx1, dy: dy0 + dy1)
        case (.pointerAxis(let dx0, let dy0, false),
              .pointerAxis(let dx1, let dy1, false)):
            return .pointerAxis(dx: dx0 + dx1, dy: dy0 + dy1, finish: false)
        default:
            return nil
        }
    }
}

extension InputEvent.Body {
    /// Motion and mid-gesture scroll: coalescible, sent on the next beat.
    var coalesces: Bool {
        switch self {
        case .pointerMotionAbsolute, .pointerMotionRelative:
            return true
        case .pointerAxis(_, _, let finish):
            return !finish
        case .keyKeycode, .pointerButton:
            return false
        }
    }

    /// The host decodes only finite coordinates.
    var isFinite: Bool {
        switch self {
        case .pointerMotionAbsolute(let a, let b),
             .pointerMotionRelative(let a, let b),
             .pointerAxis(let a, let b, _):
            return a.isFinite && b.isFinite
        case .keyKeycode, .pointerButton:
            return true
        }
    }
}
