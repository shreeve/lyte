// SessionWire: lyte-host's Lyte-UDP session leg (HS-7's Linux half, thin
// over HostWire.Session — which owns the Noise responder handshake, the
// seal discipline, the 1 Hz beacon, the conn-id TLV, path validation, and
// the shared pacer). This file is only syscalls and scheduling: CNetIO
// bind/connect, recvmmsg → Session.receive with real source tuples,
// Session's paced datagrams → sendmmsg with per-class TOS (control 0xC0
// CS6, video 0xA0 CS5 — DSCP 40 per packet is J-G1's tcpdump check), and
// the forced-IDR poll the encoder consults before each frame.
//
// Modes (extending HS-5's --wire-out into a real session):
//   • Noise (default): bind, print the host static public key, block
//     until a client's IK message 1 arrives (that datagram's source is
//     the session's initial validated tuple), connect() to it, complete
//     the handshake, then stream. `--wire-listen PORT` binds a fixed
//     port; `--wire-out HOST:PORT` pre-connects and still awaits msg1.
//   • `--insecure` (CP-3 fallback, §4.1): stream to the fixed peer
//     immediately, passthrough seal — same wiring, mandatory re-gate.
//
// Threading honesty, unchanged from HS-5: everything runs on the PipeWire
// loop thread. sendFrame drains the pacer to empty before returning,
// servicing inbound datagrams and session timers at each wake; the
// idle-floor tick (fps cadence) services them between frames, which is
// what keeps the 1 Hz beacon honest on a static desktop. `--no-idle-floor`
// stalls beacons between damage frames — a documented stub limitation the
// host event-loop era removes.
//
// HS-12 rebind wiring: media re-routing executes .promoted by
// connect()ing to the new tuple, and challenges to unvalidated tuples
// ride lyte_netio_send_to (per-datagram address + TOS on the connected
// socket) — the exact-tuple rule §6 demands. The live G7 roam run is
// still owed when a second client address exists to roam to.

import CNetIO
import Foundation
import HostCore
import HostWire
import LyteWire

/// Class → IPv4 TOS byte, the lyte-pace-check policy verbatim.
private func tos(for c: PacerClass) -> UInt8 {
    switch c {
    case .control, .audio: return 0xC0 // CS6 / DSCP 48
    case .freshVideo, .videoTail, .refinement: return 0xA0 // CS5 / DSCP 40
    case .telemetry: return 0x00
    }
}

func monotonicNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

/// Host µs for envelope timestamps and beacon t1/t4: CLOCK_MONOTONIC —
/// the same family capture.c's graph_us chain bottoms out in, so beacon
/// offsets and capture stamps share a domain.
func monotonicMicros() -> UInt64 {
    monotonicNS() / 1_000
}

final class SessionWire {
    private let netio: OpaquePointer
    private var session: Session!
    private let insecure: Bool
    private let rateBitsPerSecond: Int
    /// HS-9: non-nil = only these client statics may complete message 1
    /// (the paired set, loaded from the keystore by --require-paired).
    private let allowedClientStatics: [[UInt8]]?
    /// HS-9: non-nil = pairing mode. The service consumes the pairing
    /// CTRL types off the reliable stream; replies ride sendReliable.
    private let pairing: PairingResponderService?
    private let onPairingEvent: (PairingResponderService.Event) -> Void

    /// Datagrams handed over by the session's paced sink, flushed as
    /// sendmmsg batches.
    private var outbox: [VideoChannelDatagram] = []

    /// Scratch for one sendmmsg batch: pointers must stay valid for the
    /// duration of the call, so datagrams are staged here.
    private let scratch: UnsafeMutablePointer<UInt8>
    private static let scratchCapacity = Int(LYTE_NETIO_MAX_BATCH) * 1_200

    /// One flat region for recv_batch slots (stable pointers, one slot
    /// stride per batch position).
    private let recvScratch: UnsafeMutablePointer<UInt8>
    private static let recvSlotCapacity = 2_048

    private(set) var framesSent = 0
    private(set) var datagramsSent = 0
    private(set) var bytesSent = 0
    private(set) var challengesSentOffPrimary = 0
    private(set) var lastSendError: String?

    var counters: VideoChannelCounters { session.videoCounters }
    var sessionCounters: SessionCounters { session.counters }
    var clock: SessionClockStats { session.clock }
    var pacerTelemetry: PacerTelemetry { session.pacerTelemetry }

    /// - Parameters:
    ///   - listenPort: bind here and await a connecting client (nil =
    ///     kernel-assigned port, requires `peer`).
    ///   - peer: pre-connected far end (insecure mode's fixed peer; in
    ///     Noise mode message 1 must still arrive from it).
    init(
        listenPort: UInt16?,
        peer: (host: String, port: UInt16)?,
        insecure: Bool,
        rateBitsPerSecond: Int,
        allowedClientStatics: [[UInt8]]? = nil,
        pairing: PairingResponderService? = nil,
        onPairingEvent: @escaping (PairingResponderService.Event) -> Void
            = { _ in }
    ) throws {
        precondition(listenPort != nil || peer != nil,
                     "a session needs a port to listen on or a peer")
        self.insecure = insecure
        self.rateBitsPerSecond = rateBitsPerSecond
        self.allowedClientStatics = allowedClientStatics
        self.pairing = pairing
        self.onPairingEvent = onPairingEvent

        var err = [CChar](repeating: 0, count: 256)
        guard let n = lyte_netio_new("0.0.0.0", listenPort ?? 0,
                                     &err, err.count) else {
            throw HostError("session socket open failed: \(errString(err))")
        }
        netio = n
        if let peer {
            guard lyte_netio_set_peer(n, peer.host, peer.port,
                                      &err, err.count) == 0 else {
                lyte_netio_free(n)
                throw HostError("connect to \(peer.host):\(peer.port) "
                    + "failed: " + errString(err))
            }
        }
        scratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Self.scratchCapacity)
        recvScratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Int(LYTE_NETIO_MAX_BATCH) * Self.recvSlotCapacity)

        if insecure {
            guard let peer else {
                lyte_netio_free(n)
                scratch.deallocate()
                throw HostError("--insecure streams to a fixed peer; "
                    + "give --wire-out HOST:PORT")
            }
            makeSession(
                crypto: .insecure,
                clientTuple: FourTuple(
                    localAddress: "0.0.0.0",
                    localPort: lyte_netio_local_port(n),
                    remoteAddress: peer.host, remotePort: peer.port
                )
            )
            print("session: INSECURE passthrough (CP-3 fallback — no "
                + "crypto, re-gate when a paired client exists) → "
                + "\(peer.host):\(peer.port)")
        }
    }

    deinit {
        scratch.deallocate()
        recvScratch.deallocate()
        lyte_netio_free(netio)
    }

    private func makeSession(crypto: SessionCryptoMode, clientTuple: FourTuple) {
        session = Session(
            config: SessionConfig(
                crypto: crypto,
                rateBitsPerSecond: rateBitsPerSecond,
                allowedClientStaticPublicKeys: allowedClientStatics
            ),
            clientTuple: clientTuple,
            now: monotonicNS()
        ) { [weak self] datagram in
            self?.outbox.append(datagram)
        }
    }

    /// Noise mode: block until a client completes message 1 (the session
    /// establishes inside `receive`), up to `timeoutSeconds`. Prints the
    /// static public key the client must hold. Call before capture opens
    /// so no video is encoded for nobody.
    func awaitClient(hostStatic: NoiseKeyPair, timeoutSeconds: Double) throws {
        print("noise: host static public key "
            + HostStaticKey.hex(hostStatic.publicKey))
        print("noise: awaiting client handshake on port "
            + "\(lyte_netio_local_port(netio)) …")

        let deadline = monotonicNS() + UInt64(timeoutSeconds * 1e9)
        while monotonicNS() < deadline {
            var established = false
            try receiveAll { [weak self] datagram, tuple in
                guard let self else { return }
                if self.session == nil {
                    // First datagram: its source is the session's initial
                    // tuple; connect() so the send path has a peer.
                    var err = [CChar](repeating: 0, count: 256)
                    guard lyte_netio_set_peer(
                        self.netio, tuple.remoteAddress, tuple.remotePort,
                        &err, err.count) == 0 else {
                        print("session: connect to \(tuple.remoteAddress):"
                            + "\(tuple.remotePort) failed: \(errString(err))")
                        return
                    }
                    self.makeSession(
                        crypto: .noise(hostStatic: hostStatic),
                        clientTuple: tuple
                    )
                }
                let events = self.session.receive(
                    datagram, from: tuple,
                    now: monotonicNS(), hostMicroseconds: monotonicMicros()
                )
                for event in events {
                    self.log(event)
                    if case .handshakeCompleted = event { established = true }
                }
            }
            try flushOutbox() // message 2 + the session-start beacon
            if established, session.phase == .established {
                try drainToIdle()
                return
            }
            usleep(2_000)
        }
        throw HostError("no client handshake within \(Int(timeoutSeconds))s "
            + "— is lyte-cli wire-view pointed at this host and holding "
            + "the printed static key?")
    }

    /// The encoder-loop poll (HS-12 promotion or a client 0x10): consult
    /// before each encode; true forces the next frame to IDR.
    func takeForcedIdr() -> Bool {
        session?.takeFreshKeyframeRequest() ?? false
    }

    /// One encoded Annex-B packet → sealed shards on the wire. Runs on
    /// the PipeWire loop thread; returns once the pacer fully drained.
    func sendFrame(
        data: UnsafePointer<UInt8>, size: Int, isKeyframe: Bool,
        captureMicros: UInt64
    ) throws {
        guard let session else {
            throw HostError("sendFrame before the session exists")
        }
        let frame = Array(UnsafeBufferPointer(start: data, count: size))
        try session.ingestVideoFrame(
            frame,
            captureTimestampMicroseconds: captureMicros,
            isKeyframe: isKeyframe,
            now: monotonicNS()
        )
        framesSent += 1
        try drainToIdle()
    }

    /// The between-frames service hook (idle-floor tick cadence):
    /// inbound datagrams, session timers (beacons), pacer leftovers.
    func service() {
        guard session != nil else { return }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
    }

    /// Pumps the pacer at its own wake instants until empty, servicing
    /// inbound + timers at each pass and flushing each pump's datagrams
    /// as sendmmsg batches. The sleep is capped: while the pacer holds
    /// bytes its wake is ≤ one quantum away, and the session's other
    /// timers (a beacon up to 1 s out) must never stall the encoder.
    private func drainToIdle() throws {
        while true {
            try serviceOnce()
            try flushOutbox()
            if session.isIdle { return }
            let now = monotonicNS()
            if let wake = session.nextWake(now: now), wake > now {
                usleep(UInt32(min((wake - now) / 1_000 + 1, 2_000)))
            }
        }
    }

    private func serviceOnce() throws {
        try receiveAll { [weak self] datagram, tuple in
            guard let self, let session = self.session else { return }
            for event in session.receive(
                datagram, from: tuple,
                now: monotonicNS(), hostMicroseconds: monotonicMicros()
            ) {
                self.log(event)
            }
        }
        for event in session.advance(
            now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        session.pump(now: monotonicNS())
    }

    private func receiveAll(
        _ handle: ([UInt8], FourTuple) -> Void
    ) throws {
        var err = [CChar](repeating: 0, count: 256)
        let batchSize = Int(LYTE_NETIO_MAX_BATCH)
        while true {
            var slots = (0..<batchSize).map { i -> lyte_netio_slot in
                var slot = lyte_netio_slot()
                slot.data = recvScratch.advanced(by: i * Self.recvSlotCapacity)
                slot.cap = Self.recvSlotCapacity
                return slot
            }
            let got = slots.withUnsafeMutableBufferPointer { s in
                lyte_netio_recv_batch(netio, s.baseAddress, Int32(s.count),
                                      &err, err.count)
            }
            if got < 0 {
                throw HostError("recv failed: \(errString(err))")
            }
            if got == 0 { return }
            let localPort = lyte_netio_local_port(netio)
            for i in 0..<Int(got) {
                let slot = slots[i]
                let datagram = Array(UnsafeBufferPointer(
                    start: recvScratch.advanced(by: i * Self.recvSlotCapacity),
                    count: slot.len
                ))
                var ip = slot.src_ip
                let source = withUnsafeBytes(of: &ip) { raw -> String in
                    String(decoding: raw.prefix(while: { $0 != 0 }),
                           as: UTF8.self)
                }
                handle(datagram, FourTuple(
                    localAddress: "0.0.0.0", localPort: localPort,
                    remoteAddress: source, remotePort: slot.src_port
                ))
            }
            if got < Int32(batchSize) { return }
        }
    }

    private func log(_ event: SessionEvent) {
        switch event {
        case .handshakeCompleted(let remote):
            print("noise: handshake complete — client static "
                + HostStaticKey.hex(remote))
            // HS-9: the pairing run binds to THIS session's transcript
            // and statics; a re-handshake rebinds (and keeps the guess
            // budget — reconnecting never refills it).
            if let pairing, let hash = session.handshakeHash {
                pairing.sessionEstablished(
                    clientStaticPublicKey: remote,
                    noiseHandshakeHash: hash
                )
            }
        case .beaconSent:
            break // 1 Hz; the final stats line carries the count
        case .beaconEchoAccepted(let seq, let offset, let rtt):
            if seq % 10 == 0 {
                print("beacon: echo \(seq) offset \(offset) µs rtt \(rtt) µs")
            }
        case .reliableCtrl(let group, let message):
            // The pairing service claims its four CTRL types; nil means
            // the message is some other consumer's (none exist yet —
            // capabilities land with W7).
            if let pairing,
               let output = pairing.handleReliableCtrl(
                   message, now: monotonicNS()
               ) {
                for reply in output.replies {
                    do {
                        try session.sendReliable(
                            reply, now: monotonicNS(),
                            hostMicroseconds: monotonicMicros()
                        )
                    } catch {
                        print("pairing: reply send failed: \(error)")
                    }
                }
                for pairingEvent in output.events {
                    onPairingEvent(pairingEvent)
                }
                return
            }
            print("ctrl-arq: message group \(group.rawValue) "
                + "(\(message.count) B, type "
                + "0x\(String(message.first ?? 0, radix: 16)))")
        case .reliableOneShotAcknowledged(let group):
            print("ctrl-arq: one-shot group \(group.rawValue) acknowledged")
        case .arqIgnored(let reason):
            print("ctrl-arq: ignored \(reason)")
        case .idrRequested(let request):
            print("ctrl: IDR request seq \(request.requestSeq) "
                + "(frame \(request.frame.rawValue), "
                + "coalesced \(request.coalescedCount))")
        case .path(let pathEvent):
            print("path: \(pathEvent)")
            if case .promoted(let primary, _) = pathEvent {
                // Execute the rebind: media now targets the new tuple.
                var err = [CChar](repeating: 0, count: 256)
                if lyte_netio_set_peer(
                    netio, primary.tuple.remoteAddress,
                    primary.tuple.remotePort, &err, err.count) != 0 {
                    print("path: rebind connect failed: \(errString(err))")
                }
            }
        case .dropped(.handshakeThrottled):
            // A flood would print per datagram; the final stats line
            // carries the handshakesThrottled count instead.
            break
        case .dropped(let reason):
            print("drop: \(reason)")
        case .sendFailed(let what):
            print("send-failed: \(what)")
        }
    }

    private func flushOutbox() throws {
        guard !outbox.isEmpty else { return }
        defer { outbox.removeAll(keepingCapacity: true) }
        var err = [CChar](repeating: 0, count: 256)

        // Challenges to unvalidated tuples ride sendmsg-with-address on
        // the connected socket (lyte_netio_send_to): the challenge MUST
        // travel on the exact probed tuple — that is what it proves.
        let deliverable = outbox.filter { datagram in
            guard let destination = datagram.destination,
                  destination != session.validator.primary.tuple
            else { return true }
            let rc = datagram.bytes.withUnsafeBufferPointer { buf -> Int32 in
                var pkt = lyte_netio_pkt(
                    data: buf.baseAddress, len: buf.count,
                    tos: tos(for: datagram.pacerClass))
                return lyte_netio_send_to(
                    netio, &pkt,
                    destination.remoteAddress, destination.remotePort,
                    &err, err.count)
            }
            if rc == 1 {
                challengesSentOffPrimary += 1
                datagramsSent += 1
                bytesSent += datagram.bytes.count
                print("path: challenge sent to \(destination.remoteAddress):"
                    + "\(destination.remotePort) (off-primary sendto)")
            } else {
                lastSendError = errString(err)
                print("path: challenge to \(destination.remoteAddress):"
                    + "\(destination.remotePort) failed: \(errString(err))")
            }
            return false
        }

        var staged = 0
        while staged < deliverable.count {
            let batch = deliverable[staged..<min(
                staged + Int(LYTE_NETIO_MAX_BATCH), deliverable.count)]
            var pkts: [lyte_netio_pkt] = []
            pkts.reserveCapacity(batch.count)
            var offset = 0
            for d in batch {
                precondition(offset + d.bytes.count <= Self.scratchCapacity)
                d.bytes.withUnsafeBufferPointer { src in
                    scratch.advanced(by: offset)
                        .update(from: src.baseAddress!, count: src.count)
                }
                pkts.append(lyte_netio_pkt(
                    data: scratch.advanced(by: offset),
                    len: d.bytes.count,
                    tos: tos(for: d.pacerClass)
                ))
                offset += d.bytes.count
            }

            var sentTotal = 0
            while sentTotal < pkts.count {
                let sent = pkts[sentTotal...].withUnsafeBufferPointer { buf in
                    lyte_netio_send_batch(netio, buf.baseAddress,
                                          Int32(buf.count), nil,
                                          &err, err.count)
                }
                if sent < 0 {
                    lastSendError = errString(err)
                    throw HostError("session send failed: \(errString(err))")
                }
                if sent == 0 { usleep(200); continue }
                sentTotal += Int(sent)
            }
            for d in batch {
                datagramsSent += 1
                bytesSent += d.bytes.count
            }
            staged += batch.count
        }
    }
}
