@testable import HostEye
import XCTest

final class EncoderRateLatchTests: XCTestCase {
    /// A fall purge's tightening directive and its recovery IDR arrive in
    /// the same snapshot: the IDR carries the new cap, not the old one.
    func testADirectiveThatCoincidesWithAnIDRSizesThatIDR() {
        var latch = EncoderRateLatch(bitsPerSecond: 40_000_000, hrdBufferBits: nil)
        latch.request(bitsPerSecond: 10_000_000, hrdBufferBits: 500_000)
        XCTAssertEqual(latch.take(forIDR: true),
                       .init(bitsPerSecond: 10_000_000, hrdBufferBits: 500_000))
        XCTAssertNil(latch.take(forIDR: false), "consumed once")
        XCTAssertEqual(latch.current.bitsPerSecond, 10_000_000)
    }

    func testAnIDRResendsThePostureInForce() {
        var latch = EncoderRateLatch(bitsPerSecond: 40_000_000, hrdBufferBits: 900)
        XCTAssertEqual(latch.take(forIDR: true),
                       .init(bitsPerSecond: 40_000_000, hrdBufferBits: 900))
        XCTAssertNil(latch.take(forIDR: false))
        latch.request(bitsPerSecond: 20_000_000, hrdBufferBits: nil)
        XCTAssertEqual(latch.take(forIDR: false),
                       .init(bitsPerSecond: 20_000_000, hrdBufferBits: nil))
        XCTAssertEqual(latch.take(forIDR: true),
                       .init(bitsPerSecond: 20_000_000, hrdBufferBits: nil),
                       "a later IDR keeps the directive's move")
    }

    func testTheLatestRequestWins() {
        var latch = EncoderRateLatch(bitsPerSecond: 1, hrdBufferBits: nil)
        latch.request(bitsPerSecond: 2, hrdBufferBits: nil)
        latch.request(bitsPerSecond: 3, hrdBufferBits: 7)
        XCTAssertEqual(latch.take(forIDR: false), .init(bitsPerSecond: 3, hrdBufferBits: 7))
    }
}
