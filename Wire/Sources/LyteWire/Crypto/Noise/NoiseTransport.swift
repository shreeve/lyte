// Transport-phase encryption: the two post-Split cipher states with the
// extended-counter nonce discipline:
//
//   nonce (12 B) = chan u8 ‖ epoch u24 LE ‖ extendedCounter u64 LE
//
// The u16 envelope seq wraps in ~3.6 s at peak, so the AEAD nonce is the
// 64-bit extended counter, reconstructed SRTP-ROC-style on the receive
// side from the last-seen position. The channel byte separates channels
// sharing one direction key; the epoch (bumped by rekey, which also
// replaces the key via Noise REKEY) rides the next three bytes, so no
// (key, nonce) pair ever repeats across channels, seq wraps, or rekeys.
//
// Replay policy: each extended counter is admitted once. The receiver keeps
// a 64-entry sliding bitmap per channel: duplicates reject as
// `replayedSequence`, datagrams older than the window as `staleSequence`,
// reorder inside the window is admitted. The counter anchor moves only
// after the AEAD opens, so forged headers cannot desync it. ARQ retransmits
// ride fresh datagrams (fresh seq, fresh nonce), so this window never
// starves them.
//
// Rekey grace: the receive side keeps the
// previous epoch's key alive until the next rekey; unseal tries the
// current epoch first, then the previous — the tag arbitrates — so
// in-flight datagrams survive a rekey.

/// Extended-counter bookkeeping for one (direction, channel).
///
/// Reconstruction is anchored at the last *accepted* counter, so it is
/// exact only while consecutive accepted datagrams sit less than half the
/// u16 seq space (32768) apart. A longer one-way gap — sustained loss on
/// a busy channel — leaves the anchor behind: every later datagram reads
/// as stale or opens under the wrong counter, and because the anchor only
/// moves on a successful open, nothing would ever open again. After
/// `resyncFailureThreshold` consecutive failures the receiver therefore
/// also tries the forward wraps of the same seq; the AEAD tag
/// arbitrates, so a forged datagram costs at most `resyncWrapCount + 1`
/// extra opens (plus the grace-key attempt after a rekey) and never
/// moves the anchor.
package struct ExtendedCounterTracker: Sendable {
    /// Highest extended counter seen/sent; nil until the first datagram.
    /// The first datagram on a channel anchors at rollover 0 — extended =
    /// seq's raw value — on both ends.
    package private(set) var highest: UInt64?
    /// Bit i = (highest − i) already accepted. Bit 0 is always set.
    private(set) var window: UInt64 = 0
    /// Stale or unopenable datagrams since the last accept — the
    /// "anchor may be lost" signal that enables forward resync.
    package private(set) var failuresSinceAccept = 0

    package init() {}

    package static let windowBitCount = 64
    package static let resyncFailureThreshold = 8
    package static let resyncWrapCount = 4

    /// Reconstructs the extended counter for `seq` relative to the
    /// last-seen position via u16 serial distance (ROC-style). Returns
    /// nil when the counter would go below zero (pre-session-start).
    package func extendedCounter(for seq: ChannelSeq) -> UInt64? {
        guard let highest else { return UInt64(seq.rawValue) }
        let lastSeq = ChannelSeq(rawValue: UInt16(truncatingIfNeeded: highest))
        let delta = Int64(lastSeq.distance(to: seq))
        if delta >= 0 {
            return highest &+ UInt64(delta)
        }
        guard highest >= UInt64(-delta) else { return nil }
        return highest - UInt64(-delta)
    }

    /// True once enough consecutive failures suggest the anchor fell a
    /// half-window or more behind the sender.
    package var needsResync: Bool {
        failuresSinceAccept >= Self.resyncFailureThreshold
    }

    /// Forward candidates for `seq` past the anchor: the nearest counter
    /// ahead of `highest` carrying this seq, then each later wrap —
    /// excluding the ordinary reconstruction, which was already tried.
    package func resyncCandidates(for seq: ChannelSeq) -> [UInt64] {
        let ordinary = extendedCounter(for: seq)
        let base: UInt64
        if let highest {
            let lastSeq = UInt16(truncatingIfNeeded: highest)
            let ahead = UInt64(seq.rawValue &- lastSeq)
            base = highest &+ (ahead == 0 ? 1 << 16 : ahead)
        } else {
            base = UInt64(seq.rawValue)
        }
        return (0...Self.resyncWrapCount)
            .map { base &+ UInt64($0) << 16 }
            .filter { $0 != ordinary }
    }

    /// Records a stale or unopenable datagram (never moves the anchor).
    package mutating func noteFailure() {
        failuresSinceAccept &+= 1
    }

    /// Replay-window verdict for a candidate extended counter; call
    /// before the AEAD open. `.fresh` and `.insideWindow` may proceed.
    package enum Verdict {
        case fresh
        case insideWindow
        case replayed
        case stale
    }

    package func verdict(for extended: UInt64) -> Verdict {
        guard let highest else { return .fresh }
        if extended > highest { return .fresh }
        let age = highest - extended
        guard age < UInt64(Self.windowBitCount) else { return .stale }
        return window & (1 << age) != 0 ? .replayed : .insideWindow
    }

    /// Commits an accepted counter — only after a successful open.
    package mutating func accept(_ extended: UInt64) {
        failuresSinceAccept = 0
        guard let highest else {
            self.highest = extended
            window = 1
            return
        }
        if extended > highest {
            let shift = extended - highest
            window = shift >= UInt64(UInt64.bitWidth) ? 0 : window << shift
            window |= 1
            self.highest = extended
        } else {
            window |= 1 << (highest - extended)
        }
    }
}

/// One direction (send or receive) of the transport: the Noise cipher
/// state plus epoch and per-channel counters.
struct TransportDirection: Sendable {
    var cipher: NoiseCipherState
    /// Previous epoch's cipher, kept for the receive-side grace window.
    var previousCipher: NoiseCipherState?
    var epoch: UInt32 = 0
    /// Indexed by channel number.
    var trackers = [ExtendedCounterTracker](
        repeating: ExtendedCounterTracker(), count: 256
    )

    init(cipher: NoiseCipherState) {
        self.cipher = cipher
    }

    /// The pinned nonce layout: chan ‖ epoch u24 LE ‖ extended u64 LE.
    static func nonce(
        channel: ChannelId, epoch: UInt32, extended: UInt64
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: NoisePrimitives.nonceByteCount)
        bytes[0] = channel.rawValue
        bytes[1] = UInt8(truncatingIfNeeded: epoch)
        bytes[2] = UInt8(truncatingIfNeeded: epoch >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: epoch >> 16)
        for i in 0..<8 {
            bytes[4 + i] = UInt8(truncatingIfNeeded: extended >> (8 * i))
        }
        return bytes
    }

    /// Noise REKEY + epoch bump. `keepPrevious` retains the outgoing
    /// key one epoch — the receive-grace window; the send direction
    /// passes false so its superseded key leaves memory immediately
    /// (nothing ever seals under it again, so holding it only widens
    /// the compromise surface).
    mutating func rekey(keepPrevious: Bool) throws {
        previousCipher = keepPrevious ? cipher : nil
        try cipher.rekey()
        epoch &+= 1
    }
}

/// The transport session both `TransportCrypto` sides plug into: `seal`
/// on the send path, `unseal` on the receive path, `rekey*` as the epoch
/// primitive. Produced by `NoiseSession.makeTransport()` after the
/// handshake completes.
public struct NoiseTransport: Sendable {
    var send: TransportDirection
    var receive: TransportDirection

    /// The completed handshake's transcript hash — the pairing PAKE binds
    /// to it.
    public let handshakeHash: [UInt8]

    init(
        send: NoiseCipherState,
        receive: NoiseCipherState,
        handshakeHash: [UInt8]
    ) {
        self.send = TransportDirection(cipher: send)
        self.receive = TransportDirection(cipher: receive)
        self.handshakeHash = handshakeHash
    }

    // MARK: Send

    /// Seals one shard: `aad` is the exact header bytes that will ride
    /// the wire (fixed envelope + TLV block), `channel`/`seq` feed the
    /// nonce. Enforces plaintext ≤ 1112 B; output is ciphertext ‖ 16 B
    /// tag, ≤ 1128 B by construction. The (chan, seq) must advance past
    /// everything already sealed on that channel — a retransmit resends
    /// the sealed bytes, it never re-seals.
    public mutating func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        channel: ChannelId,
        seq: ChannelSeq
    ) throws -> [UInt8] {
        guard plaintext.count <= WireBudget.maxPlaintextShardByteCount else {
            throw NoiseError.plaintextOverBudget(plaintext.count)
        }
        var tracker = send.trackers[Int(channel.rawValue)]
        guard let extended = tracker.extendedCounter(for: seq),
              tracker.verdict(for: extended) == .fresh else {
            throw NoiseError.sendSequenceNotMonotonic
        }
        let sealed = try send.cipher.seal(
            nonceBytes: TransportDirection.nonce(
                channel: channel, epoch: send.epoch, extended: extended
            ),
            aad: aad,
            plaintext: plaintext
        )
        tracker.accept(extended)
        send.trackers[Int(channel.rawValue)] = tracker
        return sealed
    }

    public mutating func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        try seal(
            plaintext: plaintext,
            aad: aad,
            channel: envelope.channel,
            seq: envelope.seq
        )
    }

    // MARK: Receive

    /// Unseals one wire payload (ciphertext ‖ tag) against the exact
    /// received header bytes as AAD. Reconstructs the extended counter
    /// ROC-style, enforces the replay window, and tries the previous
    /// epoch's key inside the rekey grace window. State commits only on
    /// success.
    public mutating func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        channel: ChannelId,
        seq: ChannelSeq
    ) throws -> [UInt8] {
        guard wirePayload.count >= NoisePrimitives.tagByteCount,
              wirePayload.count <= WireBudget.maxWirePayloadByteCount else {
            throw NoiseError.wirePayloadOutOfBounds(wirePayload.count)
        }
        var tracker = receive.trackers[Int(channel.rawValue)]
        let plaintext: [UInt8]
        let extended: UInt64
        do {
            guard let ordinary = tracker.extendedCounter(for: seq) else {
                throw NoiseError.staleSequence
            }
            switch tracker.verdict(for: ordinary) {
            case .stale: throw NoiseError.staleSequence
            case .replayed: throw NoiseError.replayedSequence
            case .fresh, .insideWindow: break
            }
            plaintext = try openTryingEpochs(
                wirePayload: wirePayload,
                aad: aad,
                channel: channel,
                extended: ordinary
            )
            extended = ordinary
        } catch let error as NoiseError where error != .replayedSequence {
            guard tracker.needsResync,
                  let resynced = resyncOpen(
                      wirePayload: wirePayload, aad: aad, channel: channel,
                      candidates: tracker.resyncCandidates(for: seq)
                  )
            else {
                tracker.noteFailure()
                receive.trackers[Int(channel.rawValue)] = tracker
                throw error
            }
            (plaintext, extended) = resynced
        }
        tracker.accept(extended)
        receive.trackers[Int(channel.rawValue)] = tracker
        return plaintext
    }

    /// Tries each forward resync candidate under the current epoch key;
    /// the first that authenticates is the sender's counter.
    private func resyncOpen(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        channel: ChannelId,
        candidates: [UInt64]
    ) -> (plaintext: [UInt8], extended: UInt64)? {
        for candidate in candidates {
            if let plaintext = try? receive.cipher.open(
                nonceBytes: TransportDirection.nonce(
                    channel: channel, epoch: receive.epoch, extended: candidate
                ),
                aad: aad,
                ciphertextAndTag: wirePayload
            ) {
                return (plaintext, candidate)
            }
        }
        return nil
    }

    public mutating func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        try unseal(
            wirePayload: wirePayload,
            aad: aad,
            channel: envelope.channel,
            seq: envelope.seq
        )
    }

    private func openTryingEpochs(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        channel: ChannelId,
        extended: UInt64
    ) throws -> [UInt8] {
        do {
            return try receive.cipher.open(
                nonceBytes: TransportDirection.nonce(
                    channel: channel, epoch: receive.epoch, extended: extended
                ),
                aad: aad,
                ciphertextAndTag: wirePayload
            )
        } catch NoiseError.authenticationFailure {
            guard let previous = receive.previousCipher else {
                throw NoiseError.authenticationFailure
            }
            return try previous.open(
                nonceBytes: TransportDirection.nonce(
                    channel: channel,
                    epoch: receive.epoch &- 1,
                    extended: extended
                ),
                aad: aad,
                ciphertextAndTag: wirePayload
            )
        }
    }

    // MARK: Rekey

    /// Rekeys the send direction (Noise REKEY, epoch += 1). Coordination
    /// — telling the peer to `rekeyReceive()` via a CTRL message — is
    /// session territory, and wire v1 has no such message, so no v1 end
    /// rekeys; this is the pure primitive. The superseded
    /// send key is dropped, not retained: only the receive side needs a
    /// grace key.
    public mutating func rekeySend() throws {
        try send.rekey(keepPrevious: false)
    }

    /// Rekeys the receive direction; the outgoing key is retained one
    /// epoch as the grace key so in-flight datagrams still open.
    public mutating func rekeyReceive() throws {
        try receive.rekey(keepPrevious: true)
    }

    public var sendEpoch: UInt32 { send.epoch }
    public var receiveEpoch: UInt32 { receive.epoch }
}
