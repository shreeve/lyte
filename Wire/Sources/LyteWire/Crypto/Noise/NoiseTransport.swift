// Transport-phase encryption (W5): the two post-Split cipher states with
// the extended-counter nonce discipline the core plan pins (§2 decision 1):
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
// Replay policy (core plan §2 decision 2): a retransmit is a byte-identical
// datagram resend, admitted once — the receiver keeps a 64-entry sliding
// bitmap per channel: duplicates reject as `replayedSequence`, datagrams
// older than the window reject as `staleSequence`, reorder inside the
// window is admitted. Receiver state commits only after the AEAD opens,
// so forged headers cannot desync the counter. The ARQ sublayer does NOT
// rely on datagram-level resends surviving this window: its retransmit
// unit is the segment, re-sealed inside a FRESH datagram (fresh seq,
// fresh nonce) precisely so a busy channel's 64-deep window can never
// starve a straggling retransmit — see ArqFrames.swift's retransmission
// discipline, the W3-flagged interaction resolved.
//
// Rekey grace (core plan §2 decision 1): the receive side keeps the
// previous epoch's key alive until the next rekey; unseal tries the
// current epoch first, then the previous — the tag arbitrates — so
// in-flight datagrams survive a rekey.

/// Extended-counter bookkeeping for one (direction, channel).
package struct ExtendedCounterTracker: Sendable {
    /// Highest extended counter seen/sent; nil until the first datagram.
    /// Anchor rule: the first datagram on a channel anchors at
    /// rollover 0 — extended = seq's raw value. Both ends share the rule,
    /// and a session that loses its entire first seq half-window (32768
    /// datagrams, ≈1.8 s at peak) before delivering one is a failed
    /// session, not a case to paper over.
    package private(set) var highest: UInt64?
    /// Bit i = (highest − i) already accepted. Bit 0 is always set.
    private(set) var window: UInt64 = 0

    package init() {}

    package static let windowBitCount = 64

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
    var trackers: [UInt8: ExtendedCounterTracker] = [:]
    /// Datagrams processed since the last rekey — the trigger input.
    var datagramsSinceRekey: UInt64 = 0

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
        datagramsSinceRekey = 0
    }
}

/// The transport session both `TransportCrypto` sides plug into: `seal`
/// on the send path, `unseal` on the receive path, `rekey*` as the epoch
/// primitive. Produced by `NoiseSession.makeTransport()` after the
/// handshake completes.
public struct NoiseTransport: Sendable {
    var send: TransportDirection
    var receive: TransportDirection

    /// The completed handshake's transcript hash — the W6 PAKE binds to
    /// this (Lyte-UDP decision §8.2) and resume tokens may reference it.
    public let handshakeHash: [UInt8]

    /// Recommended rekey trigger (transport doc §5: every 2^24 datagrams
    /// per direction or hourly, whichever first — the timer is shell
    /// territory, the count is ours).
    public static let rekeyDatagramThreshold: UInt64 = 1 << 24

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
    /// the sealed bytes, it never re-seals (core plan §2 decision 2).
    public mutating func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        channel: ChannelId,
        seq: ChannelSeq
    ) throws -> [UInt8] {
        guard plaintext.count <= WireBudget.maxPlaintextShardByteCount else {
            throw NoiseError.plaintextOverBudget(plaintext.count)
        }
        var tracker = send.trackers[channel.rawValue] ?? ExtendedCounterTracker()
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
        send.trackers[channel.rawValue] = tracker
        send.datagramsSinceRekey &+= 1
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
        var tracker = receive.trackers[channel.rawValue]
            ?? ExtendedCounterTracker()
        guard let extended = tracker.extendedCounter(for: seq) else {
            throw NoiseError.staleSequence
        }
        switch tracker.verdict(for: extended) {
        case .stale: throw NoiseError.staleSequence
        case .replayed: throw NoiseError.replayedSequence
        case .fresh, .insideWindow: break
        }

        let plaintext = try openTryingEpochs(
            wirePayload: wirePayload,
            aad: aad,
            channel: channel,
            extended: extended
        )
        tracker.accept(extended)
        receive.trackers[channel.rawValue] = tracker
        receive.datagramsSinceRekey &+= 1
        return plaintext
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
    /// session territory; this is the pure primitive. The superseded
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
    /// Rekey-trigger inputs: datagrams sealed/opened since the last rekey.
    public var datagramsSealedSinceRekey: UInt64 { send.datagramsSinceRekey }
    public var datagramsOpenedSinceRekey: UInt64 { receive.datagramsSinceRekey }
}
