import LyteTransport
import XCTest
@testable import Lyte

/// The connection window's typed address: what it accepts, and whom it
/// dials — a paired host it names or was last seen at, else the pairing
/// sheet for a host no pin knows.
final class ConnectAddressTests: XCTestCase {
    private func parsed(_ text: String) -> TypedHostAddress? {
        try? TypedHostAddress.parse(text).get()
    }

    private func problem(_ text: String) -> TypedHostAddress.Problem? {
        guard case .failure(let problem) = TypedHostAddress.parse(text)
        else { return nil }
        return problem
    }

    func testHostsAndPortsParse() {
        XCTAssertEqual(parsed("10.0.0.5"),
                       TypedHostAddress(host: "10.0.0.5", port: nil))
        XCTAssertEqual(parsed("  10.0.0.5:41200 \n"),
                       TypedHostAddress(host: "10.0.0.5", port: 41_200))
        XCTAssertEqual(parsed("pup.tail-net.ts.net"),
                       TypedHostAddress(host: "pup.tail-net.ts.net", port: nil))
        XCTAssertEqual(parsed("pup:1"), TypedHostAddress(host: "pup", port: 1))
        XCTAssertEqual(parsed("pup:65535"),
                       TypedHostAddress(host: "pup", port: 65_535))
    }

    func testBadPortsAreRefused() {
        for text in ["pup:", "pup:0", "pup:65536", "pup:41 151", "pup:-1",
                     "pup:+5", "pup:٤١١٥١", "pup:port"] {
            XCTAssertEqual(problem(text), .badPort, text)
        }
    }

    func testIPv6IsRefusedByName() {
        for text in ["::1", "fe80::1", "[::1]", "[::1]:41151",
                     "[2001:db8::7]:41151"] {
            XCTAssertEqual(problem(text), .ipv6, text)
        }
    }

    func testBadHostsAreRefused() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem(" \t "), .empty)
        for text in ["10.0.0.300", "10.0.0", "my host", "-pup", "pup-",
                     "pup..local", ".pup", "pup_1", ":41151",
                     "pup/x"] {
            XCTAssertEqual(problem(text), .badHost, text)
        }
    }

    func testAPairedHostIsDialedWhereverTheTextPoints() throws {
        var store = PinnedHostStore()
        let key = [UInt8](repeating: 3, count: 32)
        store.pin(staticPublicKey: key, name: "pup", address: "10.0.0.3",
                  port: 41_300, pairedAt: "2026-09-01T00:00:00Z")
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)

        // Its pinned address, no port typed: the pinned port.
        let atPin = try XCTUnwrap(parsed("10.0.0.3"))
        let pin = try XCTUnwrap(atPin.pinned(in: store))
        XCTAssertEqual(atPin.dialing(pin), DiscoveredLyteHost(
            name: "pup", address: "10.0.0.3", port: 41_300, wireVersion: nil,
            publicKeyHash: pkh))

        // Its name: the pinned address, at a typed port.
        let byName = try XCTUnwrap(parsed("PUP:41400"))
        XCTAssertEqual(byName.dialing(try XCTUnwrap(byName.pinned(in: store))),
                       DiscoveredLyteHost(
                        name: "pup", address: "10.0.0.3", port: 41_400,
                        wireVersion: nil, publicKeyHash: pkh))

        // A new address the human names the host at: dialed there, under
        // the pinned identity.
        let moved = try XCTUnwrap(parsed("100.64.0.9"))
        XCTAssertNil(moved.pinned(in: store))
        XCTAssertEqual(moved.dialing(pin), DiscoveredLyteHost(
            name: "pup", address: "100.64.0.9", port: 41_300,
            wireVersion: nil, publicKeyHash: pkh))
    }

    /// No pin knows the address: the pairing sheet's target carries no
    /// advertised identity, so the sheet asks for the host's key.
    func testAnUnknownAddressIsAPairingTargetOnTheDefaultPort() throws {
        let typed = try XCTUnwrap(parsed("192.168.7.20"))
        XCTAssertNil(typed.pinned(in: PinnedHostStore()))
        XCTAssertEqual(typed.unpaired, DiscoveredLyteHost(
            name: "192.168.7.20", address: "192.168.7.20", port: 41_151,
            wireVersion: nil, publicKeyHash: nil))
        XCTAssertEqual(try XCTUnwrap(parsed("kit:41200")).unpaired.port,
                       41_200)
    }
}
