// The sealed-datagram codec: the one place the "header bytes are the
// AAD" rule is written down. A sealed datagram is
//
//   header (24 B fixed + TLV block) ‖ AEAD(plaintext, aad: header)
//
// so both ends authenticate exactly the header bytes on the wire. The
// seal/open steps are closures so any AEAD plugs into the same assembly;
// `NoiseTransport.sealDatagram` / `openDatagram` are the transport's
// direct forms. Bytes are identical to
// `envelope.encode(payload: seal(plaintext, aad: envelope.encode()))`.

extension Envelope {
    /// Builds the whole sealed datagram. The encoded header is both the
    /// AAD handed to `seal` and the output buffer the returned wire
    /// payload is appended to, so the header is encoded once. Enforces
    /// the 1128 B wire-payload and 1152 B datagram budgets on the result.
    public func sealedDatagram(
        _ plaintext: ArraySlice<UInt8>,
        seal: (
            _ plaintext: ArraySlice<UInt8>, _ aad: ArraySlice<UInt8>
        ) throws -> [UInt8]
    ) throws -> [UInt8] {
        var datagram = try encode(payload: [])
        datagram.reserveCapacity(
            datagram.count + plaintext.count + WireBudget.aeadTagByteCount
        )
        let wirePayload = try seal(plaintext, datagram[...])
        guard wirePayload.count <= WireBudget.maxWirePayloadByteCount else {
            throw WireError.payloadOverBudget(wirePayload.count)
        }
        let total = datagram.count + wirePayload.count
        guard total <= WireBudget.maxDatagramByteCount else {
            throw WireError.datagramOverBudget(total)
        }
        datagram.append(contentsOf: wirePayload)
        return datagram
    }

    /// Decodes one received datagram and opens its payload with the
    /// received header bytes as AAD. `open` sees the decoded envelope
    /// first, so a caller can refuse a channel before paying for the
    /// AEAD. Decode failures throw `WireError`; `open`'s errors pass
    /// through unchanged.
    public static func openDatagram(
        _ datagram: ArraySlice<UInt8>,
        open: (
            _ envelope: Envelope,
            _ wirePayload: ArraySlice<UInt8>,
            _ aad: ArraySlice<UInt8>
        ) throws -> [UInt8]
    ) throws -> (envelope: Envelope, plaintext: [UInt8]) {
        let (envelope, wirePayload) = try decode(datagram)
        let aad = datagram[datagram.startIndex..<wirePayload.startIndex]
        return (envelope, try open(envelope, wirePayload, aad))
    }
}

extension NoiseTransport {
    /// Seals `plaintext` into a complete datagram under this transport's
    /// send key: header ‖ ciphertext ‖ tag, the header as AAD.
    public mutating func sealDatagram(
        _ envelope: Envelope, plaintext: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        try envelope.sealedDatagram(plaintext) { plaintext, aad in
            try seal(plaintext: plaintext, aad: aad, envelope: envelope)
        }
    }

    public mutating func sealDatagram(
        _ envelope: Envelope, plaintext: [UInt8]
    ) throws -> [UInt8] {
        try sealDatagram(envelope, plaintext: plaintext[...])
    }

    /// Decodes and opens one received datagram under this transport's
    /// receive keys (replay window, rekey grace, and resync included).
    public mutating func openDatagram(
        _ datagram: ArraySlice<UInt8>
    ) throws -> (envelope: Envelope, plaintext: [UInt8]) {
        try Envelope.openDatagram(datagram) { envelope, wirePayload, aad in
            try unseal(wirePayload: wirePayload, aad: aad, envelope: envelope)
        }
    }

    public mutating func openDatagram(
        _ datagram: [UInt8]
    ) throws -> (envelope: Envelope, plaintext: [UInt8]) {
        try openDatagram(datagram[...])
    }
}
