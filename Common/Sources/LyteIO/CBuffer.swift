extension String {
    /// Decodes a C character buffer — an `err`/`errlen` out-parameter, a GL
    /// info log, a hostname — as UTF-8 up to its first NUL, or whole when
    /// it has none. Invalid UTF-8 decodes to U+FFFD rather than failing.
    public init(cBuffer: [CChar]) {
        let bytes = cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self.init(decoding: bytes, as: UTF8.self)
    }
}
