import LyteTransport
import LyteWire

/// Test-only transport double for exercising packet geometry without a
/// handshake. Shipping executables cannot construct or select this type.
public struct PassthroughTransportCrypto: TransportCrypto {
    public init() {}

    public var modeDescription: String { "test-only passthrough" }

    public func open() throws {}

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        Array(wirePayload)
    }

    public func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        Array(plaintext)
    }
}
