import HostCore
@testable import lyte_host
import LyteWire
import XCTest

/// Client pointer and axis values are raw f64 bit patterns. Whatever a
/// client sends, the host refuses it or clamps it; nothing reaches a
/// trapping conversion.
final class InputBoundaryTests: XCTestCase {
    private let hostile: [Double] = [
        .nan, -.nan, .signalingNaN, .infinity, -.infinity,
    ]

    func testNonFiniteCoordinatesAreRefusedForEveryPointerKind() {
        for value in hostile {
            XCTAssertNil(UinputInjector.leafCall(
                for: .pointerMotionRelative(dx: value, dy: 1)), "\(value)")
            XCTAssertNil(UinputInjector.leafCall(
                for: .pointerMotionRelative(dx: 1, dy: value)), "\(value)")
            XCTAssertNil(UinputInjector.leafCall(
                for: .pointerMotionAbsolute(x: value, y: 1)), "\(value)")
            XCTAssertNil(UinputInjector.leafCall(
                for: .pointerMotionAbsolute(x: 1, y: value)), "\(value)")
            XCTAssertNil(UinputInjector.leafCall(
                for: .pointerAxis(dx: value, dy: 0, finish: false)), "\(value)")
            XCTAssertNil(UinputInjector.leafCall(
                for: .pointerAxis(dx: 0, dy: value, finish: true)), "\(value)")
            XCTAssertNil(InputCoordinate.pixel(x: value, y: 0), "\(value)")
        }
    }

    func testHugeFiniteValuesSaturate() {
        let limit = InputCoordinate.relativeLimit
        XCTAssertEqual(
            UinputInjector.leafCall(
                for: .pointerMotionRelative(dx: 1e300, dy: -1e10)),
            .moveRelative(limit, -limit))
        XCTAssertEqual(
            UinputInjector.leafCall(
                for: .pointerAxis(dx: -1e300, dy: 1e300, finish: false)),
            .scroll(-InputCoordinate.scrollLimit, InputCoordinate.scrollLimit))
        XCTAssertEqual(
            InputCoordinate.pixel(x: 1e300, y: -Double.greatestFiniteMagnitude),
            CursorHotspot.Point(
                x: Int(InputCoordinate.pixelLimit),
                y: -Int(InputCoordinate.pixelLimit)))
    }

    func testOrdinaryValuesRoundToTheLeafsUnits() {
        XCTAssertEqual(
            UinputInjector.leafCall(
                for: .pointerMotionRelative(dx: 2.6, dy: -1.4)),
            .moveRelative(3, -1))
        // 15 px is one detent: 120 v120 units.
        XCTAssertEqual(
            UinputInjector.leafCall(
                for: .pointerAxis(dx: 15, dy: -7.5, finish: false)),
            .scroll(120, -60))
        XCTAssertEqual(
            UinputInjector.leafCall(
                for: .pointerMotionAbsolute(x: 1023.5, y: 4)),
            .moveAbsolute(1023.5, 4))
        XCTAssertEqual(
            UinputInjector.leafCall(for: .keyKeycode(keycode: 30, pressed: true)),
            .key(30, pressed: true))
        XCTAssertEqual(
            InputCoordinate.pixel(x: 99.5, y: 0.4),
            CursorHotspot.Point(x: 100, y: 0))
    }
}
