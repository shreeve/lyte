import Foundation
import Network
import Crypto

/// RTSP over TCP, one connection per transaction (matching the reference client:
/// connect, send, read until the host closes, parse).
///
/// Supports encrypted RTSP (`rtspenc://`): each message is wrapped in an
/// AES-128-GCM envelope keyed by the session riKey. Envelope (RtspConnection.c):
///   [typeAndLength: BE32, high bit 0x80000000 set | plaintextLen]
///   [sequenceNumber: BE32]
///   [tag: 16][ciphertext].
/// IV = LE32(seq) ‖ 0*6 ‖ 'C''R' (client→host) / 'H''R' (host→client).
public struct RtspClient {
    public let host: String
    public let port: Int
    public let hostHeader: String        // address form used in Host: and the target URL
    public let targetURL: String

    private let counter = SeqCounter()
    private let encryptionKey: SymmetricKey?
    private let encSeq = SeqCounter(start: 0)   // pre-increment: first sealed message uses 1

    public init(host: String, port: Int, sessionURL: String, riKey: Data? = nil) {
        self.host = host
        self.port = port
        self.hostHeader = host
        self.targetURL = sessionURL
        self.encryptionKey = sessionURL.hasPrefix("rtspenc://") ? riKey.map { SymmetricKey(data: $0) } : nil
    }

    private var encrypted: Bool { encryptionKey != nil }

    public struct Response {
        public let statusCode: Int
        public let statusMessage: String
        public let headers: [String: String]
        public let payload: Data

        public var payloadString: String { String(data: payload, encoding: .utf8) ?? "" }

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Build, send, and parse one RTSP transaction.
    public func request(_ command: String, target: String? = nil,
                        headers extra: [(String, String)] = [],
                        payload: Data? = nil) async throws -> Response {
        let seq = await counter.next()
        var lines = "\(command) \(target ?? targetURL) RTSP/1.0\r\n"
        lines += "CSeq: \(seq)\r\n"
        lines += "X-GS-ClientVersion: 14\r\n"
        lines += "Host: \(hostHeader)\r\n"
        for (name, value) in extra {
            lines += "\(name): \(value)\r\n"
        }
        lines += "\r\n"
        var message = Data(lines.utf8)
        if let payload { message.append(payload) }

        if let key = encryptionKey {
            message = try await seal(message, key: key)
        }
        let raw = try await transact(message)
        let plaintext = try encryptionKey.map { try unseal(raw, key: $0) } ?? raw
        return try Self.parse(plaintext)
    }

    // MARK: - Encrypted RTSP envelope

    private func seal(_ plaintext: Data, key: SymmetricKey) async throws -> Data {
        let seq = UInt32(await encSeq.next())
        var iv = Data(count: 12)
        iv[0] = UInt8(seq & 0xff); iv[1] = UInt8((seq >> 8) & 0xff)
        iv[2] = UInt8((seq >> 16) & 0xff); iv[3] = UInt8((seq >> 24) & 0xff)
        iv[10] = UInt8(ascii: "C"); iv[11] = UInt8(ascii: "R")

        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        var out = Data(capacity: 24 + box.ciphertext.count)
        out.append(be32(0x8000_0000 | UInt32(plaintext.count)))
        out.append(be32(seq))
        out.append(box.tag)
        out.append(box.ciphertext)
        return out
    }

    private func unseal(_ raw: Data, key: SymmetricKey) throws -> Data {
        guard raw.count > 24 else { throw LyteError.host("rtsp: encrypted response too small") }
        let typeAndLen = beRead32(raw, 0)
        guard typeAndLen & 0x8000_0000 != 0 else { throw LyteError.host("rtsp: response not encrypted") }
        let seq = beRead32(raw, 4)

        var iv = Data(count: 12)
        iv[0] = UInt8(seq & 0xff); iv[1] = UInt8((seq >> 8) & 0xff)
        iv[2] = UInt8((seq >> 16) & 0xff); iv[3] = UInt8((seq >> 24) & 0xff)
        iv[10] = UInt8(ascii: "H"); iv[11] = UInt8(ascii: "R")

        let tag = raw.subdata(in: 8..<24)
        let ciphertext = raw.subdata(in: 24..<raw.count)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    private func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }
    private func beRead32(_ d: Data, _ o: Int) -> UInt32 {
        let b = d.startIndex + o
        return UInt32(d[b]) << 24 | UInt32(d[b+1]) << 16 | UInt32(d[b+2]) << 8 | UInt32(d[b+3])
    }

    // MARK: - TCP transaction

    private func transact(_ message: Data) async throws -> Data {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let collector = ResponseCollector(continuation: cont)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: message, completion: .contentProcessed { error in
                            if let error { collector.fail(LyteError.host("rtsp send: \(error)")) }
                        })
                        Self.receiveLoop(connection, collector)
                    case .failed(let error):
                        collector.fail(LyteError.host("rtsp connect: \(error)"))
                    case .cancelled:
                        collector.finish()   // read-until-close completed
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
                // Overall transaction timeout
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                    collector.fail(LyteError.host("rtsp timeout for transaction"))
                    connection.cancel()
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func receiveLoop(_ connection: NWConnection, _ collector: ResponseCollector) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { collector.append(data) }
            if error != nil || isComplete {
                collector.finish()
                connection.cancel()
            } else {
                receiveLoop(connection, collector)
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ raw: Data) throws -> Response {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw LyteError.host("rtsp: no header terminator")
        }
        guard let head = String(data: raw[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw LyteError.host("rtsp: bad header encoding")
        }
        let payload = Data(raw[headerEnd.upperBound...])

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw LyteError.host("rtsp: empty response") }
        let status = lines.removeFirst()
        let parts = status.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw LyteError.host("rtsp: bad status line: \(status)")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Response(statusCode: code,
                        statusMessage: parts.count > 2 ? String(parts[2]) : "",
                        headers: headers, payload: payload)
    }

    private actor SeqCounter {
        private var value: Int
        init(start: Int = 0) { value = start }   // pre-increment: first next() returns start+1
        func next() -> Int { value += 1; return value }
    }

    private final class ResponseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var continuation: CheckedContinuation<Data, Error>?

        init(continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: buffer)
            continuation = nil
        }

        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
