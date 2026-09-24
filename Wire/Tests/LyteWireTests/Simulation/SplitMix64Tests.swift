import XCTest
import LyteWireTestKit

// SplitMix64's width-independent draws: the pinned sequences below are
// what the stdlib's Int-width draws produce on 64-bit hosts, and they
// must come out identically on wasm32, where Int is 32 bits. Vector
// builders freeze these orders (video-v1.json's reordered scenario), so
// a platform-dependent draw rewrites a frozen file.
final class SplitMix64Tests: XCTestCase {

    func testIntDrawIsPinnedOnEveryPlatform() {
        var rng = SplitMix64(seed: 0x57_1D_00_02)
        XCTAssertEqual(
            (0..<16).map { _ in rng.int(in: 0...3) },
            [1, 2, 1, 3, 3, 2, 3, 3, 0, 0, 0, 3, 0, 1, 2, 1]
        )
    }

    func testBoundedReorderIsPinnedOnEveryPlatform() {
        var rng = SplitMix64(seed: 0x57_1D_00_02)
        XCTAssertEqual(
            Reorder.bounded(Array(0..<20), maxDisplacement: 3, using: &rng),
            [0, 1, 2, 3, 4, 5, 8, 6, 9, 7, 10, 12, 11, 13, 14, 15, 16, 17, 18, 19]
        )
    }

    func testShuffleIsPinnedOnEveryPlatform() {
        var rng = SplitMix64(seed: 7)
        var items = Array(0..<12)
        rng.shuffle(&items)
        XCTAssertEqual(items, [4, 1, 11, 8, 7, 6, 3, 5, 0, 10, 9, 2])
    }

    func testDrawsStayInRangeAtTheExtremes() {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<64 {
            XCTAssertEqual(rng.int(in: 5...5), 5)
            XCTAssertEqual(rng.int(in: -3..<(-2)), -3)
            XCTAssert((-10...10).contains(rng.int(in: -10...10)))
        }
    }

    /// Forbidden-token scan: a replayed draw at Int width differs on
    /// wasm32, so a seed that fails there would not reproduce on a Mac.
    /// Wire's tests and test equipment draw through SplitMix64's helpers.
    func testReplayedDrawsNeverUseIntWidthStdlibHelpers() throws {
        let root = URL(fileURLWithPath: WireVectors.directory)
            .deletingLastPathComponent()
        let forbidden = ["Int.random(in:", ".shuffle(using:", ".shuffled(using:"]
        var offenders: [String] = []
        for directory in ["Tests/LyteWireTests", "Sources/LyteWireTestKit",
                          "Sources/LyteWireVectorGen"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift"
                && !["SplitMix64.swift", "SplitMix64Tests.swift"]
                    .contains(url.lastPathComponent) {
                let text = try String(contentsOf: url, encoding: .utf8)
                for (number, line) in text.split(
                    separator: "\n", omittingEmptySubsequences: false
                ).enumerated()
                where forbidden.contains(where: line.contains)
                    && line.contains("using:") {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    #if _pointerBitWidth(_64)
    /// On 64-bit hosts the helpers are bit-identical to the stdlib, so
    /// switching a builder to them never changes a frozen vector.
    func testMatchesTheStdlibOn64BitHosts() {
        let ranges: [ClosedRange<Int>] = [
            0...0, 0...1, 0...3, -7...7, 1113...8896, 0...Int.max,
            Int.min...Int.max, Int.min...0,
        ]
        for range in ranges {
            var ours = SplitMix64(seed: 99)
            var stdlib = SplitMix64(seed: 99)
            for _ in 0..<256 {
                XCTAssertEqual(
                    ours.int(in: range), Int.random(in: range, using: &stdlib)
                )
            }
        }
        var ours = SplitMix64(seed: 3)
        var stdlib = SplitMix64(seed: 3)
        for count in 0..<40 {
            var a = Array(0..<count)
            var b = a
            ours.shuffle(&a)
            b.shuffle(using: &stdlib)
            XCTAssertEqual(a, b)
            XCTAssertEqual(ours.int(in: 0..<(count + 1)),
                           Int.random(in: 0..<(count + 1), using: &stdlib))
        }
    }
    #endif
}
