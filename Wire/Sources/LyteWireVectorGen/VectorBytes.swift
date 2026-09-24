// Shared byte fixtures for the vector builders.

/// `count` bytes counting up from `offset`, wrapping at 256 — the
/// recognizable payload most vectors carry.
func counting(from offset: Int, count: Int) -> [UInt8] {
    (0..<count).map { UInt8((offset + $0) & 0xFF) }
}
