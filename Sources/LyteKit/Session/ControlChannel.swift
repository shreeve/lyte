import Foundation
import Crypto
import CEnet

/// The ENet control channel (UDP 47999): encrypted NVCTL messaging, the
/// Start A/B handshake, and the 100 ms periodic ping that keeps the session
/// alive and RTT measured. Sunshine / Gen 7.1.431+ (encrypted control) only.
///
/// Wire format (ControlStream.c):
///   NVCTL_ENCRYPTED_PACKET_HEADER { u16le type=0x0001; u16le length; u32le seq }
///   + 16-byte AES-GCM tag
///   + ciphertext( u16le msgType; u16le payloadLength; payload )
/// IV (control-v2): 12 bytes = LE32(seq) ‖ 0*6 ‖ 'C' 'C' (client→host); 'H' 'C' back.
public final class ControlChannel: @unchecked Sendable {
    public enum Event: Sendable {
        case connected
        case hostMessage(type: UInt16, payload: Data)
        case terminated(code: UInt32)
        case disconnected
    }

    private let host: String
    private let port: UInt16
    private let connectData: UInt32
    private let key: SymmetricKey
    private let onEvent: @Sendable (Event) -> Void

    private let lock = NSLock()
    private var client: OpaquePointer?          // ENetHost*
    private var peer: OpaquePointer?            // ENetPeer*
    private var sendSequence: UInt32 = 0
    private var running = false
    private var serviceThread: Thread?
    private var pingThread: Thread?

    private static let channelCount = 0x30      // 48 channels
    private static let startAType: UInt16 = 0x0302   // == request IDR frame (Gen7Enc)
    private static let startBType: UInt16 = 0x0307
    private static let periodicPingType: UInt16 = 0x0200
    private static let terminationType: UInt16 = 0x0109

    public init(host: String, port: UInt16, connectData: UInt32, riKey: Data,
                encryptionEnabled: UInt32,
                onEvent: @escaping @Sendable (Event) -> Void) throws {
        guard encryptionEnabled & SSEnc.controlV2 != 0 else {
            throw LyteError.host("host does not support control encryption v2 (legacy 16-byte GCM IV unimplemented)")
        }
        self.host = host
        self.port = port
        self.connectData = connectData
        self.key = SymmetricKey(data: riKey)
        self.onEvent = onEvent
    }

    // MARK: - Lifecycle

    public func start() throws {
        enet_initialize()

        var address = ENetAddress()
        var storage = sockaddr_in()
        storage.sin_family = sa_family_t(AF_INET)
        storage.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, host, &storage.sin_addr) == 1 else {
            throw LyteError.host("control: bad IPv4 address \(host)")
        }
        withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = enet_address_set_address(&address, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = enet_address_set_port(&address, port)

        guard let clientHost = enet_host_create(Int32(AF_INET), nil, 1, Self.channelCount, 0, 0) else {
            throw LyteError.host("control: enet_host_create failed")
        }
        client = OpaquePointer(clientHost)

        guard let peerPtr = enet_host_connect(clientHost, &address, Self.channelCount, connectData) else {
            enet_host_destroy(clientHost)
            client = nil
            throw LyteError.host("control: enet_host_connect failed")
        }
        peer = OpaquePointer(peerPtr)

        // Wait up to 10 s for the connect to complete
        var event = ENetEvent()
        let rc = enet_host_service(clientHost, &event, 10_000)
        guard rc > 0, event.type == ENET_EVENT_TYPE_CONNECT else {
            enet_peer_reset(peerPtr)
            enet_host_destroy(clientHost)
            client = nil; peer = nil
            throw LyteError.host("control: ENet connect to \(host):\(port) failed (rc \(rc), event \(event.type.rawValue))")
        }
        enet_host_flush(clientHost)
        enet_peer_timeout(peerPtr, 2, 10_000, 10_000)
        onEvent(.connected)

        // Start A, Start B (both tiny preconstructed payloads)
        try send(type: Self.startAType, payload: Data([0, 0]))
        try send(type: Self.startBType, payload: Data([0]))

        running = true
        let service = Thread { [weak self] in self?.serviceLoop() }
        service.name = "lyte-control-service"
        service.start()
        serviceThread = service

        let ping = Thread { [weak self] in self?.pingLoop() }
        ping.name = "lyte-control-ping"
        ping.start()
        pingThread = ping
    }

    public func stop() {
        running = false
        lock.lock()
        if let peer { enet_peer_disconnect_now(UnsafeMutablePointer(peer), 0) }
        if let client { enet_host_destroy(UnsafeMutablePointer(client)) }
        peer = nil; client = nil
        lock.unlock()
    }

    // MARK: - Sending

    /// Ask the host to encode an IDR frame (Gen7Enc: same message as Start A).
    public func requestIdrFrame() {
        try? send(type: Self.startAType, payload: Data([0, 0]))
    }

    public func send(type: UInt16, payload: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let client, let peer else { throw LyteError.host("control: not connected") }

        sendSequence += 1
        let seq = sendSequence

        // 12-byte IV: LE32(seq) + zeros + 'C''C'
        var iv = Data(count: 12)
        iv[0] = UInt8(seq & 0xff)
        iv[1] = UInt8((seq >> 8) & 0xff)
        iv[2] = UInt8((seq >> 16) & 0xff)
        iv[3] = UInt8((seq >> 24) & 0xff)
        iv[10] = UInt8(ascii: "C")
        iv[11] = UInt8(ascii: "C")

        // Plaintext: V2 header + payload
        var plaintext = Data(capacity: 4 + payload.count)
        plaintext.append(le16(type))
        plaintext.append(le16(UInt16(payload.count)))
        plaintext.append(payload)

        guard let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv)) else {
            throw LyteError.crypto("control: AES-GCM seal failed")
        }

        let length = UInt16(4 + 16 + plaintext.count)   // seq + tag + v2hdr+payload
        var packet = Data(capacity: 8 + 16 + plaintext.count)
        packet.append(le16(0x0001))
        packet.append(le16(length))
        packet.append(le32(seq))
        packet.append(sealed.tag)
        packet.append(sealed.ciphertext)

        let enetPacket = packet.withUnsafeBytes { bytes in
            enet_packet_create(bytes.baseAddress, bytes.count, ENET_PACKET_FLAG_RELIABLE.rawValue)
        }
        guard let enetPacket else { throw LyteError.host("control: packet create failed") }
        guard enet_peer_send(UnsafeMutablePointer(peer), 0, enetPacket) >= 0 else {
            enet_packet_destroy(enetPacket)
            throw LyteError.host("control: send failed")
        }
        enet_host_flush(UnsafeMutablePointer(client))
    }

    // MARK: - Loops

    private func serviceLoop() {
        while running {
            var event = ENetEvent()
            lock.lock()
            guard let client else { lock.unlock(); break }
            let rc = enet_host_service(UnsafeMutablePointer(client), &event, 0)
            lock.unlock()

            if rc > 0 {
                switch event.type {
                case ENET_EVENT_TYPE_RECEIVE:
                    if let packet = event.packet {
                        let data = Data(bytes: packet.pointee.data, count: packet.pointee.dataLength)
                        enet_packet_destroy(packet)
                        handleHostPacket(data)
                    }
                case ENET_EVENT_TYPE_DISCONNECT:
                    running = false
                    onEvent(.disconnected)
                default:
                    break
                }
            } else {
                usleep(5_000)   // 5 ms
            }
        }
    }

    private func pingLoop() {
        // LE: u16 payload length (4), u32 timestamp (0), padded to 8 bytes
        let payload = Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        while running {
            do {
                try send(type: Self.periodicPingType, payload: payload)
            } catch {
                if running { onEvent(.disconnected) }
                return
            }
            usleep(100_000)     // 100 ms
        }
    }

    // MARK: - Receiving

    private func handleHostPacket(_ data: Data) {
        guard data.count >= 8 else { return }
        let headerType = UInt16(data[0]) | UInt16(data[1]) << 8
        guard headerType == 0x0001 else { return }   // must be encrypted
        let seq = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24

        var iv = Data(count: 12)
        iv[0] = UInt8(seq & 0xff)
        iv[1] = UInt8((seq >> 8) & 0xff)
        iv[2] = UInt8((seq >> 16) & 0xff)
        iv[3] = UInt8((seq >> 24) & 0xff)
        iv[10] = UInt8(ascii: "H")
        iv[11] = UInt8(ascii: "C")

        guard data.count >= 8 + 16 + 4 else { return }
        let tag = data.subdata(in: 8..<24)
        let ciphertext = data.subdata(in: 24..<data.count)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: key), plain.count >= 4 else {
            return
        }

        let msgType = UInt16(plain[plain.startIndex]) | UInt16(plain[plain.startIndex + 1]) << 8
        let payload = plain.dropFirst(4)

        if msgType == Self.terminationType {
            var code: UInt32 = 0
            if payload.count >= 4 {
                let b = [UInt8](payload.prefix(4))
                code = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            }
            running = false
            onEvent(.terminated(code: code))
        } else {
            onEvent(.hostMessage(type: msgType, payload: Data(payload)))
        }
    }

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
}
