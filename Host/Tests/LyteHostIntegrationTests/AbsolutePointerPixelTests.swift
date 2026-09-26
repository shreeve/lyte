import CInputUinput
import XCTest

/// Absolute pointer values land on the pixel the client aimed at, as
/// libinput places them: an axis 0…65535 maps value v to position
/// v · extent / 65536, and the pointer is in pixel floor(position).
final class AbsolutePointerPixelTests: XCTestCase {
    /// pup's panel (2048 × 1280) and common widths and heights, powers
    /// of two and not.
    private let extents: [UInt32] = [
        2048, 1280, 1920, 1080, 2560, 1440, 3840, 2160, 1366, 768, 1, 7,
    ]

    private func landedPixel(_ px: Double, extent: UInt32) -> Int {
        let value = lyte_uinput_abs_value(px, extent)
        XCTAssert((0...65_535).contains(value), "\(px)/\(extent) → \(value)")
        return Int(Int64(value) * Int64(extent) / 65_536)
    }

    func testEveryWholePixelLandsOnItself() {
        for extent in extents {
            let misses = (0..<Int(extent)).filter {
                landedPixel(Double($0), extent: extent) != $0
            }
            XCTAssertEqual(misses.count, 0, "extent \(extent): \(misses.prefix(5))")
        }
    }

    func testFractionalPositionsLandInTheirPixel() {
        for extent in extents {
            var misses: [Double] = []
            for pixel in 0..<Int(extent) {
                let base = Double(pixel)
                for px in [base + 0.25, base + 0.5, base + 0.75,
                           (base + 1).nextDown]
                where landedPixel(px, extent: extent) != pixel {
                    misses.append(px)
                }
            }
            XCTAssertEqual(misses.count, 0, "extent \(extent): \(misses.prefix(5))")
        }
    }

    func testPositionsPastTheEdgesClampToTheEdgePixels() {
        for extent in extents {
            let last = Int(extent) - 1
            XCTAssertEqual(lyte_uinput_abs_value(-5, extent), 0)
            XCTAssertEqual(
                lyte_uinput_abs_value(-.greatestFiniteMagnitude, extent), 0)
            XCTAssertEqual(landedPixel(Double(extent), extent: extent), last)
            XCTAssertEqual(
                landedPixel(.greatestFiniteMagnitude, extent: extent), last)
        }
    }
}
