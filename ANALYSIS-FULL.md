Architecture review — Lyte
Findings (ranked)
1. The ARQ datagram repack and its budget formula are duplicated verbatim across two packages — MEDIUM-HIGH, architecture
Host/Sources/HostWire/Session.swift:2484 (repackArq) and Sources/LyteTransport/ReliableCtrlEndpoint.swift:391 (static func repack) are the same algorithm line-for-line, down to the // Already within budget — keep the endpoint's packing (ACK piggybacked ahead of segments) byte-verbatim. comment. The budget that drives them is also computed twice: Session.swift:887 and ReliableCtrlEndpoint.swift:76 both spell min(WireBudget.maxPlaintextShardByteCount, WireBudget.maxWirePayloadByteCount - WireBudget.aeadTagByteCount - (1 + 2 + ConnectionId.byteCount)), and each then clamps maxSegmentBodyByteCount by budget - ArqBounds.segmentHeaderByteCount independently. Every input to this is already a LyteWire type (WireBudget, ConnectionId.byteCount, ArqBounds, ArqFrame.decodeAll), so the natural home is Wire — one ArqRepack/sessionPlaintextBudget beside WireBudget.swift. Today a change to the geometry (the DPLPMTUD raise that WireBudget.swift:5 already anticipates) has to be made in two packages that cannot see each other, and no vector covers the packing decision, so nothing fails if only one moves.

2. No test anywhere drives the real client core against the real host core — MEDIUM-HIGH, architecture
Tests/LyteTransportTests depends on LyteTransport, COpus, LyteWire, LyteWireTestKit; Host/Tests/HostWireTests depends on HostWire, HostCore, LyteWire, LyteWireTestKit. Neither can see the other, and the situation is acknowledged in-tree at Tests/LyteTransportTests/NackRepairClientGateTests.swift:17 ("The root package cannot import HostWire; the stand-in rebuilds VideoChannel.enqueueRepair's shape from the same Wire parts"). Each end's gate suite therefore verifies itself against a hand-built LyteWire counterpart that the same author wrote. The frozen vectors pin the codecs, so byte-level drift is caught — but the composition (Noise IK responder → capability intersection → ARQ ordered stream → lifecycle flip → teardown drain) is only ever exercised against a mock on each side, and meets for real only on a live wire during quality-probe.sh. The seam to fix this already exists and is deliberate: Host/Package.swift:5-9 vends HostCore and HostWire as libraries that "build everywhere, including macOS" precisely so the pipeline is testable off Linux. A test-only .package(path: "Host") on LyteTransportTests would give a true both-ends-in-one-process gate without creating a production client→host dependency.

3. Nothing mechanically requires a new wire-visible message to have a vector — MEDIUM, architecture
Wire/Sources/LyteWire/CtrlMessage.swift:30-173 declares the type registry as 36 public static let constants on a bare enum CtrlMessageType, not a CaseIterable enum. No test enumerates it (grep across all three test suites finds CtrlMessageType. only inside individual codec tests), and Wire/Tests/LyteWireTests/*VectorFileTests.swift each hardcode their own filename — there is no directory scan and no registry cross-check. The discipline itself is genuinely excellent (all 16 files in Wire/Vectors/ are loaded by some test; the README's per-file inventories are exemplary), but it is held entirely by convention and reviewer memory. Adding CtrlMessageType.foo = 0x24 plus a codec plus both ends' handling would ship green with zero vector coverage. A single "every registered type byte is named by some vector file" gate would convert the convention into the contract the README already claims it is.

4. LyteWire.AudioWire is shadowed on the host, and the audio dialect's constants are unbound from Wire — MEDIUM, architecture
Wire/Sources/LyteWire/AudioDepacketizer.swift:38 declares public enum AudioWire { sampleRate = 48_000; channels = 2; samplesPerPacket = 240 } — the wire-visible audio dialect. Host/Sources/lyte-host/AudioWire.swift:39 declares final class AudioWire for the Linux PipeWire capture/encode leg. Both are in lyte-host's namespace, so the local class wins and AudioWire.sampleRate is unreachable by name on the host; grep confirms no host file ever references the Wire constants. The host's numbers instead live independently at Host/Sources/COpusEncode/include/*.h:17-19 as LYTE_OPUS_RATE 48000 / LYTE_OPUS_CHANNELS 2 / LYTE_OPUS_FRAME 240, with nothing binding them to Wire's values (the client, at Sources/LyteTransport/OpusStreamDecoder.swift:26-27, does use AudioWire.sampleRate/channels correctly). Two distinct problems in one spot: a name collision that inverts the repo's own Wire convention, and a wire-visible parameter whose host-side value can drift silently because the C leaf cannot import Swift and no test asserts the equality.

5. main.swift carries three charters, and the quality-ratchet policy is stranded where nothing can test it — MEDIUM, architecture
Host/Sources/lyte-host/main.swift is 2140 lines holding enum Backend/struct Options + arg parsing (19-431), final class Sink (433-1235, ~800 lines with 60+ mutable stored properties), the pairing surface and trampolines (1235-1371), and run() (1373-2140, ~770 lines). Three named files — Options.swift, CaptureEncodeSink.swift, Run.swift — would cost nothing structurally. The sharper issue is what is in Sink: ratchetTick at main.swift:850 is a settle-time / stable-count / convergence state machine taking wall-clock now: Double, alongside ratchetStep, ratchetStableCount, ratchetPrevBytes, ratchetEpisodeBytes (494-501). That is policy, not IO, and it is the exception in an otherwise disciplined host: its siblings — EncoderVbv, EncoderReconfigureBooks (HostWire/EncoderVbv.swift:532), EncoderRecipe.ratchetFloorQP (HostCore/EncoderRecipe.swift:47) — all live in cross-platform packages with gate tests (EncoderVbvGateTests.swift:590). Only the ratchet's decision loop sits in the Linux-only executable, where no macOS gate can reach it.

6. HostWire.Session is a ~2300-line class with 77 members — MEDIUM, architecture
Host/Sources/HostWire/Session.swift:652 opens public final class Session and it does not close until 2966. Its own header (lines 1-63) enumerates eight distinct responsibilities, and the MARK sections confirm them as largely independent state islands: input (796), video (1174), audio (1234), lifecycle (1344), reliable CTRL (1572), bulk channel (1618-2007), the rate-estimator diet (2134-2514), timers/pumping (2514), handshake (2681), crypto (2932). Several are pure glue over types that already exist as separate Wire/HostWire values (BulkEngines, ClipboardImageChannel, RateEstimator, ArqEndpoint), so the honest split is not file-splitting extensions — Swift's file-scoped private makes that a downgrade to internal — but promoting the cohesive state islands into member structs (BulkChannelState, InputState, LifecycleRunner) that the class holds and delegates to. The file is well-organized and heavily commented; the concern is that 77 members in one lock-free-by-convention class is where the next concurrency or ordering bug will hide.

7. 1127 lines of verification-harness code ship inside the production client transport library — MEDIUM, architecture
Sources/LyteTransport/CorpusFrames.swift (573), CorpusGates.swift (302), CorpusPNG.swift (93), and VideoReadbackTap.swift (159) are members of LyteTransport, which Sources/Lyte (the shipping Lyte.app) links. Their consumers are Sources/lyte-cli/CorpusCommands.swift, Sources/lyte-cli/DecodeProbeCommand.swift, and Tests/LyteTransportTests/CorpusHarnessGateTests.swift; grep for Corpus|ReadbackTap across Sources/Lyte/ returns nothing. So the app binary carries a hand-drawn 5×7 glyph bitmap face, a procedural photographic-noise generator, a PNG encoder, and a VTDecompressionSession readback path it never calls. A LyteCorpus target depending on LyteTransport, with lyte-cli and the tests depending on it, restores the boundary — the same move Package.swift already made for COpus ("test-only; production encodes nothing client-side").

8. The crypto and reliable-CTRL seams are protocols on the client and inlined switches on the host — LOW-MEDIUM, architecture
Sources/LyteTransport/TransportCrypto.swift:29 defines a TransportCrypto protocol with open/seal/unseal, two conformances (InsecureTransportCrypto, NoiseTransportCrypto), and a refinement (HandshakingTransportCrypto) for the pre-thread handshake window — a crisp, swappable seam. The host's mirror is Session.swift:2934-2963: two private methods that switch config.crypto { case .insecure: return Array(...); case .noise: ... }, with no protocol and no seam. The same asymmetry repeats one layer up: the client's ARQ carriage is a named, independently testable ReliableCtrlEndpoint class (which is also what made it channel-generic for chan 8, per its header at line 40), while the host holds arq and bulkArq as two bare ArqEndpoint<HostClock> fields inside Session (688, 701) with the carriage logic spread across serviceArq, repackArq, and the bulk section. Both ends work, but the host has no place to stand for a mode swap, and finding #1's duplication is a direct consequence of the missing host-side seam.

9. lyte sniff drags the whole NVENC/libavcodec leaf in for two lines of setvbuf — LOW-MEDIUM, architecture
Host/Sources/CHevcEncode/include/lyte_hevc_encode.h:12-13 declares lyte_stdout_linebuf() / lyte_stdout_flush(), implemented at encode.c:26-27 as one-line setvbuf/fflush wrappers. Host/Sources/lyte-host/Sniff.swift:9 reads import CHevcEncode // lyte_stdout_linebuf — the header dissector, whose only job is decoding cleartext envelope bytes via HostWire.SniffFormat, takes a module dependency on the hardware encoder purely for stdout buffering. RemoteDesktopSpike.swift:691 and lyte-encode-check/main.swift:255 do the same. Process-global stdio configuration is not the HEVC encoder's charter; a two-function CStdio leaf (or the existing CNetIO, which Sniff.swift already imports) is the right home, and it would let sniff stop pretending it needs libavcodec.

10. Pure-Swift utilities are duplicated because Wire is the only shared package — LOW, architecture
Two verified instances, both with in-code admissions. (a) Sources/LyteTransport/InputSender.swift:39-45 documents LatencyHistogram as "the byte-for-byte shape of HostCore.Histogram … the root package cannot import HostCore"; the two are 54 and ~60 lines with matching record/percentile/p50/p99 surfaces. (b) Wire/Sources/LyteWire/AnnexBCheck.swift:1-11 documents itself as "carried over from … HostCore's AnnexB helpers … deliberately distinct from HostCore's HevcNal/NalUnit/AnnexB so both modules can meet in the host's build graph without qualification fights" — two Annex-B NAL scanners with duplicate NAL-type tables (HostCore/AnnexB.swift:4-17 vs AnnexBCheck.swift:13-26) both live in lyte-host's graph, and the older one still has three live call sites at main.swift:1909-1914. Both are consequences of a real constraint (Wire's charter is protocol-only, and nothing else is shared), but retiring HostCore.AnnexB onto AnnexBCheck is a mechanical change today. Related and much milder: HostWire/BulkFileStore.swift:19-23 imports Darwin/Glibc for POSIX open/pwrite/fsync/rename inside a package that Session.swift:56 calls "Sans-IO in the house style" — it is properly confined behind the BulkReceiveStore protocol and explicitly justified in its header, but neither Host/Package.swift's HostWire comment nor Session.swift's claim mentions the exception.

Strengths — what to protect
Wire's sans-IO discipline is real and mechanically enforced, not aspirational. Wire/Scripts/lint-no-foundation.sh bans Foundation/Dispatch/Network including scoped imports, confines import Crypto to Sources/LyteWire/Crypto/, and bans CryptoKit outright — and NoFoundationLintTests runs it under swift test on every platform. The grep confirms it holds: LyteWire's only imports are CNanorsWire (one file) and Crypto (three files, all under Crypto/). No wall-clock, no file IO, no print, and only five preconditions in the whole module, all on constructor arguments.

The injected-time discipline goes further than most sans-IO cores. WireTimestamp<Domain> with phantom HostClock/ClientClock (Vocabulary.swift:59-92) makes it a type error to feed a client instant to a host machine. ArqEndpoint<ClockDomain> and SessionStateMachine<ClockDomain> are generic over it; every entry point takes now: and returns (actions, nextDeadline) rather than sleeping. VideoAssembler, BulkEngines, and CapabilityNegotiator follow the same shape. Randomness is injected the same way (ConnectionId.random(using:), BulkMessages.swift:64, CPace's scalar), with BoxedRng at Session.swift:2971 as the honest workaround for storing a some RandomNumberGenerator.

Dependency directions are clean in both directions. Wire depends on nothing but swift-crypto and its vendored FEC leaf; HostWire and LyteTransport each depend on Wire and never on each other; nothing depends back on Wire's consumers. LyteUI has no Lyte dependencies at all (only AppKit/Foundation), which is what makes ControlStripPolicy virtual-time testable without the app shell. The app layer's three import LyteWire sites use vocabulary types only (HostAudioRoutingMode, InputEvent.Body, CapabilityNegotiationError) — it never constructs wire bytes.

The vector contract is unusually well-specified where it exists. Sixteen frozen files, every one loaded by a test; per-file inventories in Vectors/README.md that state coverage claims as counts ("Inventory (68): 63 message vectors … rejects covering every one of the 16 BulkMessageError case names"); external oracles where they exist (RFC 8949 appendix A, draft-irtf-cfrg-cpace-21, snow/cacophony Noise vectors) and explicit self-consistent provenance labels where they do not; hand-computed anchors so "the codec never grades its own homework"; and a freeze policy that treats disagreement as a contract break to investigate rather than a regeneration prompt. Scripts/wasm-test.sh attesting the same bytes on a third platform is a genuinely strong move.

Shared test infrastructure lives in the right place. SimNet is defined once in LyteWireTestKit/SimNet.swift:43 and drives gate tests in all three suites; BulkTransferHarness and the vector loaders likewise. That is exactly the pattern finding #2 asks you to extend one step further.

Seam design is right where it was done deliberately. BulkReceiveShell (sans-IO engine driver) over the BulkReceiveStore protocol with BulkFileStore as the one POSIX conformance, mirrored client-side by BulkSendShell (one transfer) over BulkSendCoordinator (queue, capability gate, resume) — both headers state their threading contract and their engine/shell split precisely. ClipboardWire's Swift-side seam letting the Mutter leaf land behind gate tests written against a scripted implementation is the same pattern paying off. The C leaves' headers (lyte_hevc_encode.h) document ownership sharply: latency invariants are baked into the leaf, tunable knobs are explicit, and the default is stated to live in Swift (HostCore.EncoderRecipe, test-pinned) — with unknown knob values failing the open loudly rather than falling back silently.

Bash
IN
cd /Users/shreeve/Data/Code/lyte; grep -rn "lyte_pw_capture_quit\|lyte_pw_audio_quit\|lyte_pw_audio_free\|lyte_opus_enc_free" --include=*.swift Host/Sources | head -20

OUT
(eval):1: no matches found: --include=*.swift
Bash Read lifecycle/idr/repair codecs
IN
cd /Users/shreeve/Data/Code/lyte/Wire/Sources/LyteWire && sed -n '30,120p' SessionLifecycle.swift; echo ===; sed -n '30,90p' IdrRequest.swift; echo ===; sed -n '55,120p' RepairRefusal.swift

OUT
Exit code 1
//
// Both are exactly their fixed size: truncation and trailing bytes
// reject, a foreign type byte rejects with what it found (the beacon
// codecs' doctrine). FROZEN/RECOVERY never appear on the wire — they
// are the path-loss overlay each end derives locally (overview §2);
// only the two wire modes are signaled.

/// The two wire modes (overview §2): ACTIVE = unreliable datagram video
/// is flowing; IDLE = sparse reliable frames only. Signaled on CTRL by
/// the sender's SessionStateMachine; FROZEN/RECOVERY are local overlay
/// states, never wire values.
public enum SessionWireMode: UInt8, Hashable, CaseIterable, Sendable {
    case active = 0x01
    case idle = 0x02
}

/// Why a session ended, as the wire carries it. `takenOver` is the
/// transport pillar's multi-client ruling (`taken-over-by`);
/// `shuttingDown` is any orderly local end. Liveness timeouts send
/// nothing — the peer that would read the message is the one that died.
public enum SessionTeardownReason: UInt8, Hashable, CaseIterable, Sendable {
    case takenOver = 0x01
    case shuttingDown = 0x02
}

/// The ACTIVE⇄IDLE mode-transition CTRL message (type 0x09).
public struct ModeTransition: Hashable, Sendable {
    public var mode: SessionWireMode

    public init(mode: SessionWireMode) {
        self.mode = mode
    }

    public static let encodedByteCount = 2

    /// Encodes the 2-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        [CtrlMessageType.modeTransition, mode.rawValue]
    }

    /// Decodes a whole ARQ-delivered CTRL message (type byte first).
    /// Throws on the wrong type, truncation, trailing bytes, and an
    /// unknown mode value; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> ModeTransition {
        guard payload.count >= encodedByteCount else {
            throw LifecycleMessageError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw LifecycleMessageError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.modeTransition else {
            throw LifecycleMessageError.unexpectedType(payload[base])
        }
        guard let mode = SessionWireMode(rawValue: payload[base + 1]) else {
            throw LifecycleMessageError.unknownMode(payload[base + 1])
        }
        return ModeTransition(mode: mode)
    }

    public static func decode(_ payload: [UInt8]) throws -> ModeTransition {
        try decode(payload[...])
    }
}

/// The typed session-teardown CTRL message (type 0x0A).
public struct SessionTeardown: Hashable, Sendable {
    public var reason: SessionTeardownReason

    public init(reason: SessionTeardownReason) {
        self.reason = reason
    }

    public static let encodedByteCount = 2

    /// Encodes the 2-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        [CtrlMessageType.sessionTeardown, reason.rawValue]
    }

    /// Decodes a whole ARQ-delivered CTRL message (type byte first).
    /// Throws on the wrong type, truncation, trailing bytes, and an
    /// unknown reason value; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> SessionTeardown {
        guard payload.count >= encodedByteCount else {
            throw LifecycleMessageError.truncatedMessage
        }
(eval):1: == not found
Bash Read exactTighten within-band test
IN
sed -n '/func testExactTightenRetunesTheMaterialWithinBandFall/,/^    }/p' Host/Tests/HostWireTests/EncoderVbvGateTests.swift

OUT
    func testExactTightenRetunesTheMaterialWithinBandFall() {
        let policy = exactPolicy()
        _ = policy.note(frameByteCeiling: 12_500, now: 0) // 4.0 Mbps
        // 10,937 B ⇒ 3,499,840 b/s: −12.5%, materially below the
        // applied max but INSIDE the covering half-rung's band — the
        // ladder absorbs this shape (control pin below); exact mode
        // retunes onto the fallen rate.
        let fall = policy.note(frameByteCeiling: 10_937, now: 2 * Self.ms)
        XCTAssertEqual(fall?.kind, .tighten)
        XCTAssertEqual(fall?.maxBitsPerSecond, 3_499_840)
        XCTAssertEqual(policy.directivesIssued, 2)
    }
Bash Check timestamp delta + ctrl types
IN
grep -rn "func microseconds(since" -A 10 Wire/Sources/LyteWire/Vocabulary.swift | head -30; grep -rn "rekey\|0x1F\|epochBump" Wire/Sources/LyteWire/CtrlMessage.swift | head

OUT
Wire/Sources/LyteWire/Vocabulary.swift:82:    public func microseconds(since earlier: WireTimestamp) -> Int64 {
Wire/Sources/LyteWire/Vocabulary.swift-83-        Int64(bitPattern: microseconds &- earlier.microseconds)
Wire/Sources/LyteWire/Vocabulary.swift-84-    }
Wire/Sources/LyteWire/Vocabulary.swift-85-
Wire/Sources/LyteWire/Vocabulary.swift-86-    public static func < (lhs: Self, rhs: Self) -> Bool {
Wire/Sources/LyteWire/Vocabulary.swift-87-        lhs.microseconds < rhs.microseconds
Wire/Sources/LyteWire/Vocabulary.swift-88-    }
Wire/Sources/LyteWire/Vocabulary.swift-89-}
Wire/Sources/LyteWire/Vocabulary.swift-90-
Wire/Sources/LyteWire/Vocabulary.swift-91-public typealias HostTimestamp = WireTimestamp<HostClock>
Wire/Sources/LyteWire/Vocabulary.swift-92-public typealias ClientTimestamp = WireTimestamp<ClientClock>
Wire/Sources/LyteWire/CtrlMessage.swift:151:    public static let bulkAck: UInt8 = 0x1F
Bash
IN
grep -n "public static func load\|func save\|FileManager\|Data(contentsOf" -A 8 Sources/LyteTransport/PinnedHostStore.swift | head -40

OUT
142:        FileManager.default.urls(
143-            for: .applicationSupportDirectory, in: .userDomainMask
144-        )[0].appendingPathComponent("Lyte/pinned_hosts.json")
145-    }
146-
147:    public static func load(from url: URL = Self.url) -> PinnedHostStore {
148:        guard let data = try? Data(contentsOf: url),
149-              let store = try? JSONDecoder().decode(PinnedHostStore.self, from: data)
150-        else {
151-            return PinnedHostStore()
152-        }
153-        return store
154-    }
155-
156:    public func save(to url: URL = Self.url) throws {
157-        let dir = url.deletingLastPathComponent()
158:        try FileManager.default.createDirectory(
159-            at: dir, withIntermediateDirectories: true)
160-        let encoder = JSONEncoder()
161-        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
162-        try encoder.encode(self).write(to: url, options: .atomic)
163-    }
164-
165-    // MARK: Trust operations
166-
Bash Read NackPolicy handle
IN
sed -n '150,300p' Sources/LyteTransport/NackPolicy.swift

OUT
    /// out-of-cadence flush — the host's cadence-derived freeze budget
    /// (HS-32, ~1.5 cadences) rewards asks that travel promptly).
    private let emit: @Sendable ([FeedbackReport.NackEntry]) -> Void
    /// Rule 4's exit: the existing coalesced IDR requester.
    private let escalate: @Sendable (FrameNumber, ClientTimestamp) -> Void

    private struct FrameBook {
        /// How an asked frame's story ended — the late-vs-superseded
        /// discriminator for answers that keep arriving afterward.
        enum Fate {
            case pending
            /// Decoded (originals, FEC, repairs — any mix).
            case decoded
            /// Abandoned: skipped/evicted, or rule-4 escalated to IDR.
            case gone
        }
        var askedIndices: Set<UInt8> = []
        /// Asked indices whose repair was accepted (the duplicate
        /// discriminator).
        var acceptedRepairIndices: Set<UInt8> = []
        var firstAskAt: ClientTimestamp?
        var refusedStale = false
        var sawRepair = false
        var fate: Fate = .pending
        var settled: Bool { fate != .pending }
        var lastTouched: ClientTimestamp
    }

    private let lock = NSLock()
    private var books: [UInt32: FrameBook] = [:]
    private var stats = Stats()

    public init(
        config: NackPolicyConfig = NackPolicyConfig(),
        rtt: @escaping @Sendable () -> Int64?,
        emit: @escaping @Sendable ([FeedbackReport.NackEntry]) -> Void,
        escalate: @escaping @Sendable (FrameNumber, ClientTimestamp) -> Void
    ) {
        self.config = config
        self.rtt = rtt
        self.emit = emit
        self.escalate = escalate
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: Signals

    /// One forwarded assembler signal. Emissions/escalations fire
    /// outside the lock.
    public func handle(_ signal: VideoRepairSignal, now: ClientTimestamp) {
        switch signal {
        case .nackCandidates(let frame, let missing, let parity, let age):
            handleCandidates(
                frame: frame, missingIndices: missing,
                parityShards: parity, frameAgeMicroseconds: age, now: now
            )
        case .repairShardAccepted(let frame, let index):
            lock.lock()
            stats.repairShardsReceived += 1
            if var book = books[frame.rawValue] {
                book.sawRepair = true
                if book.askedIndices.contains(index) {
                    book.acceptedRepairIndices.insert(index)
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
            lock.unlock()
        case .frameDecoded(let frame):
            lock.lock()
            if var book = books[frame.rawValue], !book.settled {
                if book.sawRepair, !book.askedIndices.isEmpty {
                    stats.framesCompletedByRepair += 1
                }
                book.fate = .decoded
                book.lastTouched = now
                books[frame.rawValue] = book
            }
            lock.unlock()
        case .framesGone(let from, let through):
            var expired: [FrameNumber] = []
            var brokeUnhealed = false
            lock.lock()
            var frame = from
            while true {
                if var book = books[frame.rawValue] {
                    if !book.settled {
                        if !book.askedIndices.isEmpty {
                            // Asked, never completed: rule 4, now.
                            stats.framesEscalatedToIdr += 1
                            expired.append(frame)
                        } else {
                            brokeUnhealed = true
                        }
                        book.fate = .gone
                        book.lastTouched = now
                        books[frame.rawValue] = book
                    }
                    // Settled books: .decoded emitted (no break);
                    // .gone already ran its escalation. Neither re-fires.
                } else {
                    // No book at all — not one shard, candidate, or
                    // repair ever arrived for this frame number.
                    brokeUnhealed = true
                }
                if frame == through { break }
                frame = frame.next
            }
            // The whole-loss rule: every gone frame died undecoded — a
            // broken HEVC reference — but a frame that never landed a
            // shard has no book, no ask, and no fecImpossible verdict,
            // so no other path reaches the IDR requester (and since
            // rate reconfigures stopped minting IDRs, nothing heals it
            // incidentally either: the glass stays broken until an
            // unrelated wake). One escalation covers the whole range —
            // one IDR heals everything — and the asked-frame rule-4
            // escalations above already cover it when they fired.
            if brokeUnhealed, expired.isEmpty {
                stats.whollyLostEscalations += 1
                expired.append(from)
            }
            lock.unlock()
            for frame in expired { escalate(frame, now) }
        case .satisfiedShardDropped(let frame, let index):
            // Only asked shards are repair accounting; an unasked
            // duplicate is ordinary network duplication of an original.
            lock.lock()
            if var book = books[frame.rawValue],
               book.askedIndices.contains(index) {
                if book.acceptedRepairIndices.contains(index) {
                    stats.repairsDuplicate += 1
                } else {
                    stats.repairsLate += 1
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
            lock.unlock()
        case .staleShardDropped(let frame):
            lock.lock()
            if var book = books[frame.rawValue], !book.askedIndices.isEmpty {
                // Decoded frames age out of the tracker and their turn
                // passes — a straggling answer is merely LATE. A frame
                // that died undecoded (skipped/evicted/escalated) was
                // SUPERSEDED by newer frames or the IDR heal. (.pending
                // cannot reach here in practice: a frame's turn passing
Bash
IN
cd /Users/shreeve/Data/Code/lyte; ls Host/Sources/CPipeWireAudio Host/Sources/COpusEncode; wc -l Host/Sources/CPipeWireAudio/*.c Host/Sources/COpusEncode/*.c

OUT
Host/Sources/COpusEncode:
include/
opus_codec.c

Host/Sources/CPipeWireAudio:
include/
audio.c
     735 Host/Sources/CPipeWireAudio/audio.c
     117 Host/Sources/COpusEncode/opus_codec.c
     852 total
Bash Read test policy helpers
IN
sed -n '/func exactPolicy/,/^    }/p;/func policy(/,/^    }/p' Host/Tests/HostWireTests/EncoderVbvGateTests.swift | head -40

OUT
    private func exactPolicy() -> EncoderVbvPolicy {
        EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineAverageBitsPerSecond: 10_000_000,
            baselineMaxBitsPerSecond: 10_000_000,
            baselineVbvBits: 10_000_000 / 60,
            rungsPerOctave: 2,
            exactTighten: true
        ))
    }
Bash
IN
grep -n "public func snapshotCounters\|func handleDatagram\|private let lock" -A 6 Sources/LyteTransport/LyteUdpSession.swift | head -50

OUT
336:    private let lock = NSLock()
337-    private var machine: SessionStateMachine<ClientClock>
338-    private var negotiator: CapabilityNegotiator
339-    private var lastState: SessionState = .active
340-    private var lastWireMode: SessionWireMode = .active
341-    private var agreed: Capabilities?
342-    /// The 0x19-confirmed posture of the host's own speakers (CL-13);
--
926:    public func handleDatagram(
927-        _ outcome: IngestOutcome, arrivalMicroseconds: UInt64
928-    ) {
929-        guard case .accepted(let envelope, let payload) = outcome else {
930-            return
931-        }
932-        let now = now()
--
1099:    public func snapshotCounters() -> LyteUdpSessionCounters {
1100-        lock.lock()
1101-        defer { lock.unlock() }
1102-        return counters
1103-    }
1104-
1105-    // MARK: The machine
--
1735:    private let lock = NSLock()
1736-    private var stored: LyteUdpSessionCore?
1737-    var value: LyteUdpSessionCore? {
1738-        get { lock.lock(); defer { lock.unlock() }; return stored }
1739-        set { lock.lock(); stored = newValue; lock.unlock() }
1740-    }
1741-}
--
1745:    private let lock = NSLock()
1746-    private var raised = false
1747-    func exchange(_ value: Bool) -> Bool {
1748-        lock.lock()
1749-        defer { lock.unlock() }
1750-        let was = raised
1751-        raised = value
Read audio.c (lines 2-241)
Read audio.c (lines 241-520)
Bash Check framesSkipped emission range
IN
grep -n "framesSkipped" -B6 -A10 Wire/Sources/LyteWire/VideoAssembler.swift | head -60

OUT
139-
140-public enum VideoAssemblerEvent: Hashable, Sendable {
141-    /// A frame, byte-identical to the packetizer's input, in frame order.
142-    case decoded(DecodeUnit)
143-    /// Frames `from`…`through` (inclusive) will never emit; the reason
144-    /// applies to every frame in the range.
145:    case framesSkipped(from: FrameNumber, through: FrameNumber, reason: VideoFrameSkipReason)
146-    /// The group cannot recover from what is still plausibly in flight —
147-    /// emitted once per frame, the CL-3 IDR-request trigger.
148-    case fecImpossible(FrameNumber, presumedLostDataShards: Int, bestCaseParityShards: Int)
149-    /// Newly presumed-lost seqs whose retransmit would help this frame —
150-    /// §4.7's NACK-decision output; CL-12's NACK policy consumes it.
151-    /// `missingSeqs` are the candidates NEW this pass (the firing
152-    /// condition); the remaining fields are the frame's whole current
153-    /// picture, everything rule 3's client half needs in one event:
154-    /// `missingShardIndices` = ALL currently-absent presumed-lost FEC
155-    /// shard indices (the W4a NACK bitmap's coordinates, self-correcting
--
544-                    events.append(.decoded(unit))
545-                    continue
546-                }
547-                if group.corrupt {
548-                    groups.removeValue(forKey: awaited.rawValue)
549-                    lastEmitted = awaited
550:                    events.append(.framesSkipped(
551-                        from: awaited, through: awaited, reason: .corruptSuppressed
552-                    ))
553-                    continue
554-                }
555-                if let reason = holdbackExpiry(now: now) {
556-                    groups.removeValue(forKey: awaited.rawValue)
557-                    lastEmitted = awaited
558:                    events.append(.framesSkipped(
559-                        from: awaited, through: awaited, reason: reason
560-                    ))
561-                    continue
562-                }
563-                return
564-            }
565-
566-            // The awaited frame is a numbering gap: nothing tracked
567-            // between `awaited` and the lowest tracked frame. Wait for it
568-            // within the holdback bounds, then skip the whole gap at once.
569-            guard awaited.rawValue < lowestTracked else {
570-                // lastEmitted has passed everything tracked (wrap-around
571-                // corner); nothing to order against.
572-                return
573-            }
574-            guard let reason = holdbackExpiry(now: now) else { return }
575:            events.append(.framesSkipped(
576-                from: awaited,
577-                through: FrameNumber(rawValue: lowestTracked - 1),
578-                reason: reason
579-            ))
580-            lastEmitted = FrameNumber(rawValue: lowestTracked - 1)
581-        }
582-    }
583-
584-    /// Whether the frames blocking emission have exhausted their welcome:
585-    /// too many decoded frames held, or the oldest held one waited past
Bash Find envelope header recomputation sites
IN
grep -rn "headerByteCount" --include="*.swift" Sources Host/Sources Wire/Sources Wire/Tests | grep -v "Wire/Sources/LyteWire/\(IdleFrame\|InputMessages\|ArqFrames\|ClipboardImages\)" | head -30

OUT
Wire/Sources/LyteWire/Envelope.swift:54:    public var headerByteCount: Int {
Wire/Sources/LyteWire/Envelope.swift:74:        let total = headerByteCount + payload.count
Wire/Tests/LyteWireTests/RoundTripPropertyTests.swift:24:            let headroom = WireBudget.maxDatagramByteCount - envelope.headerByteCount
Wire/Tests/LyteWireTests/RoundTripPropertyTests.swift:70:            if envelope.headerByteCount > 200 {
Wire/Tests/LyteWireTests/ControlCodecTests.swift:41:        for length in 0...IdleFrame.headerByteCount {
Bash Find AAD computation on receive
IN
grep -rn "aad:" --include="*.swift" Sources Host/Sources | head -30

OUT
Sources/LyteTransport/NoiseTransportCrypto.swift:292:        aad: ArraySlice<UInt8>,
Sources/LyteTransport/NoiseTransportCrypto.swift:304:                wirePayload: wirePayload, aad: aad, envelope: envelope)
Sources/LyteTransport/NoiseTransportCrypto.swift:312:        aad: ArraySlice<UInt8>,
Sources/LyteTransport/NoiseTransportCrypto.swift:321:            plaintext: plaintext, aad: aad, envelope: envelope)
Sources/LyteTransport/TransportSender.swift:81:                plaintext: plaintext[...], aad: header[...], envelope: envelope)
Sources/LyteTransport/TransportCrypto.swift:44:        aad: ArraySlice<UInt8>,
Sources/LyteTransport/TransportCrypto.swift:55:        aad: ArraySlice<UInt8>,
Sources/LyteTransport/TransportCrypto.swift:74:        aad: ArraySlice<UInt8>,
Sources/LyteTransport/TransportCrypto.swift:82:        aad: ArraySlice<UInt8>,
Sources/LyteTransport/ReceiveDemux.swift:118:            plaintext = try crypto.unseal(wirePayload: payload, aad: aad, envelope: envelope)
Host/Sources/HostWire/VideoChannel.swift:81:    _ aad: ArraySlice<UInt8>,
Host/Sources/HostWire/Session.swift:956:                try self.sealPayload(plaintext, aad: aad, envelope: envelope)
Host/Sources/HostWire/Session.swift:1102:            plaintext = try unsealPayload(payload, aad: aad, envelope: envelope)
Host/Sources/HostWire/Session.swift:1275:                payload[...], aad: header[...], envelope: envelope
Host/Sources/HostWire/Session.swift:1807:            body[...], aad: header[...], envelope: envelope
Host/Sources/HostWire/Session.swift:2921:            payload = try sealPayload(body[...], aad: header[...], envelope: envelope)
Host/Sources/HostWire/Session.swift:2936:        aad: ArraySlice<UInt8>,
Host/Sources/HostWire/Session.swift:2945:                plaintext: plaintext, aad: aad, envelope: envelope
Host/Sources/HostWire/Session.swift:2952:        aad: ArraySlice<UInt8>,
Host/Sources/HostWire/Session.swift:2961:                wirePayload: wirePayload, aad: aad, envelope: envelope
Read audio.c (lines 518-737)
Bash Inspect receive-side AAD derivation
IN
sed -n '100,125p' Sources/LyteTransport/ReceiveDemux.swift; echo ===; sed -n '1090,1110p' Host/Sources/HostWire/Session.swift

OUT
Exit code 1
        } catch let error as WireError {
            totals.malformed += 1
            return .malformed(error)
        } catch {
            totals.malformed += 1
            return .malformed(.truncatedEnvelope)
        }

        guard !envelope.channel.isReserved else {
            totals.reservedDropped += 1
            return .reservedChannel(envelope.channel.rawValue)
        }

        // The header rides as AAD: exactly the received bytes ahead of the
        // payload, fixed envelope + TLV block.
        let aad = datagram[datagram.startIndex..<payload.startIndex]
        let plaintext: [UInt8]
        do {
            plaintext = try crypto.unseal(wirePayload: payload, aad: aad, envelope: envelope)
        } catch {
            totals.unsealFailures += 1
            channels[envelope.channel.rawValue, default: ChannelAccount()].stats.unsealFailures += 1
            return .unsealFailed(error)
        }

        totals.accepted += 1
(eval):1: == not found
Bash Check envelope TLV tests and vectors
IN
cd /Users/shreeve/Data/Code/lyte/Wire && grep -n "extensionsFlag\|0x01\]\|flags" Tests/LyteWireTests/EnvelopeTests.swift | head -20; echo "=== vectors ==="; ls Vectors; grep -l "extension" Vectors/*.json 2>/dev/null

OUT
20:        0x00,  // flags = no extensions
60:        let encoded = try envelope.encode(payload: [0x01])
61:        // Header: fixed 24 with flags bit0, then count=1, then 7F 03 AA BB CC.
64:        expected += [0x01, 0x7F, 0x03, 0xAA, 0xBB, 0xCC, 0x01]
69:        XCTAssertEqual(Array(payload), [0x01])
=== vectors ===
video-corpus-v1/
README.md
arq-v1.json
beacon-v1.json
bulk-v1.json
capabilities-v1.json
clipboard-images-v1.json
clipboard-v1.json
control-v1.json
envelope-v1.json
fec-v1.json
lifecycle-v1.json
noise-v1.json
pairing-v1.json
repair-refusal-v1.json
retry-v1.json
session-v1.json
video-v1.json
Vectors/envelope-v1.json
Vectors/control-v1.json
Vectors/session-v1.json
Bash Inspect envelope vector cases
IN
cd /Users/shreeve/Data/Code/lyte/Wire && python3 -c "
import json
d=json.load(open('Vectors/envelope-v1.json'))
def walk(o,p=''):
    if isinstance(o,dict):
        for k,v in o.items(): walk(v,p+'/'+k)
    elif isinstance(o,list):
        print(p, len(o))
        for i,v in enumerate(o[:60]):
            if isinstance(v,dict): print('  ', {k:(str(x)[:60]) for k,x in v.items() if k in ('name','note','reason','error','hex')})
walk(d)
" 2>&1 | head -60

OUT
/seqComparisons 10
   {}
   {}
   {}
   {}
   {}
   {}
   {}
   {}
   {}
   {}
/vectors 17
   {'name': 'nominal-video-shard'}
   {'name': 'nominal-audio'}
   {'name': 'empty-payload'}
   {'name': 'max-plaintext-shard'}
   {'name': 'max-wire-payload'}
   {'name': 'seq-wrap-high'}
   {'name': 'seq-wrap-low'}
   {'name': 'tlv-reserved-types'}
   {'name': 'tlv-unknown-skipped'}
   {'name': 'reserved-flag-bits-ignored'}
   {'name': 'tlv-flag-empty-block'}
   {'error': 'shardOverBudget', 'name': 'shard-over-budget'}
   {'error': 'payloadOverBudget', 'name': 'payload-over-budget'}
   {'error': 'datagramOverBudget', 'name': 'datagram-over-budget-tlv'}
   {'error': 'truncatedEnvelope', 'name': 'truncated-envelope'}
   {'error': 'truncatedExtensions', 'name': 'truncated-tlv-block'}
   {'error': 'datagramOverBudget', 'name': 'oversize-datagram'}
I've read the full app shell, UI layer, helper, and CLI entry paths. Findings below are ranked; every correctness claim was re-read before inclusion, and none of them are on TODO.md's six caveats.

Ranked findings
1. HIGH / lifecycle — closing a stream window tears down nothing.
/Users/shreeve/Data/Code/lyte/Sources/Lyte/ConnectionWindow.swift:5 (no .onDisappear), /Users/shreeve/Data/Code/lyte/Sources/Lyte/ConnectionModel.swift:451 (endLyteSession is the only teardown, reachable only from Disconnect / peer teardown / capability failure). ConnectionModel has no deinit, and LyteUdpSession (/Users/shreeve/Data/Code/lyte/Sources/LyteTransport/LyteUdpSession.swift:1486) has none either — stopParts() runs only from close()/stop(). Meanwhile UdpReceiveEndpoint's receive thread keeps a strong self for the whole receiveLoop (UdpReceiveEndpoint.swift:160, running only cleared by stop()), and that thread transitively retains demux → coreBox → LyteUdpSessionCore → FeedbackSender/machineTimer. Failure scenario: user is streaming and presses ⌘W (the reflex on macOS). No typed 0x0A leaves; the receive thread, the 100 ms machine beat, and the feedback cadence keep running forever, so the host never hits its liveness verdict and keeps encoding and sending at full bitrate into a window nobody can see; AgentState.streamEnded() is never called, so activeStreams stays ≥ 1 (menu bar reads "Lyte — streaming"), HelperClient.streamEnded() never fires (awdl0 stays forced down — AirDrop/Continuity broken), and the radio watchdog task loops for the life of the process. Only quitting the app recovers. Every other exit (Disconnect, ⌘D, host teardown) is clean — it's specifically the window-close verb that has no seam.

2. HIGH / correctness — the local mute is not applied to a freshly connected session.
ConnectionModel.swift:30-32 (var muted didSet pushes into lyteSession), :280-305 (first connect: lyteSession = lyte with no setAudioMuted call), contrasted with :783 where the roaming path correctly does lyte.setAudioMuted(muted). LyteAudioPlayer.muted defaults to false (LyteAudioPlayer.swift:263) and endLyteSession never resets model.muted. Failure scenario: mute playback in the strip (headphones glyph slashed, muted == true), Disconnect, then reconnect from the same window — the new session's mixer comes up at full volume while the strip and the ⌘⇧M menu item both still render "muted"; the toggle appears dead until you cycle it twice. The one-line fix mirrors line 783 into the connect path.

3. MED / input — no key/modifier release when the window stops being key.
/Users/shreeve/Data/Code/lyte/Sources/Lyte/LyteInputCapture.swift:203-231: handleKey forwards each flagsChanged as an evdev down/up and each keyDown/Up as a keycode, but every path is gated on window.isKeyWindow, and stop() (:98) merely removes the monitors. There is no "release everything held" flush on resign-key, on stop(), or on teardown — I grepped both this repo's client and Host/Sources for any all-keys-up path and found none. Failure scenario: hold ⌥ (or ⌘) over the video — KEY_LEFTALT/KEY_LEFTMETA down is on the wire — then ⌘Tab away. The release flagsChanged is delivered to the other app, so our monitor never sees it and the host is left with Super/Alt latched: subsequent typing on the host fires window-manager chords, and the host's uinput device stays wedged until something else releases it. Same shape for a plain key held across an app switch (down sent, up lost ⇒ host-side auto-repeat storm).

4. MED / resource — HelperClient sets no interruptionHandler, so the watchdog's documented re-engage never runs on a daemon crash.
/Users/shreeve/Data/Code/lyte/Sources/Lyte/HelperClient.swift:114-119 installs only invalidationHandler; /Users/shreeve/Data/Code/lyte/Sources/Lyte/AgentMenu.swift:106-111 re-engages only if !HelperClient.shared.engaged, with the comment "A crashed daemon's connection already invalidated (engaged=false)". A crashed mach-service peer produces an interruption, not an invalidation — the connection object stays valid and reusable. Failure scenario: lyte-helperd dies mid-stream; its side releases the hold (lyte-helperd/main.swift:139), awdl0 comes back up, the watchdog sees radioUp == true, logs "awdl0 UP while streaming — re-engaging", and then does nothing because engaged is still true. Two more checks later the overlay just says AWDL LOOSE for the rest of the session, with no attempt to relaunch — which is exactly the case the re-engage was written for. (Sending on the interrupted proxy would have re-launched it via launchd.)

5. MED / main-thread — Keychain and pinned-store I/O run on the main actor in both dial paths.
ConnectionModel.swift:175 (ClientNoiseIdentity.loadOrCreate() inside connectLyte) and :718-728 (PinnedHostStore.load() + loadOrCreate() inside runRoamingDial, which is called synchronously from roamingInput). ClientNoiseIdentity is SecItemCopyMatching/SecItemAdd (ClientNoiseIdentity.swift:60,88) and PinnedHostStore.load is Data(contentsOf:) + JSON decode (PinnedHostStore.swift:147). The handshake itself is correctly off-main (Task.detached { candidate.start() }), so this is narrow but sharp: failure scenario — on a build whose signature changed (the exact situation docs/MACOS-SIGNING.md exists for), SecItemCopyMatching blocks on the Keychain ACL prompt; because it holds the main actor, the whole app beachballs, including the Cancel button that ConnectView.swift:25 offers for precisely this wait, and every other window's UI.

6. MED-LOW / overlay truthfulness — the in-fps meter and the delivery books outlive the session whose counters they read.
ConnectionModel.swift:102-105 (videoDeliveryBooks and videoInMeter are model-lifetime lets) vs :1177-1179, which feeds videoInMeter.rate(count: pipelineStats.framesDecoded, …) — a per-session counter that restarts at 0 with each LyteUdpSession. RateMeter.rate computes count &- anchor.count on UInt64 (VideoDeliveryBooks.swift:41) and its eviction always keeps one anchor regardless of age. Failure scenario: leave the stats overlay open through a roaming re-dial (detachWireSession/adoptReconnectedSession deliberately don't clear statsVisible): the first ticks after re-attach compute 5 - 12000 as an unsigned wrap and the video row prints an ~1.8e19 fps in-rate for up to ~3 s until the stale anchor ages out. Related, same site: the hop p50/p99 ring and enqueued are never reset, so "deliver p50/p99" silently blends the previous session's samples into the new one.

7. MED-LOW / clarity trap — the CLI's UI-command rule is an allow-list, but its own documentation says the opposite.
/Users/shreeve/Data/Code/lyte/Sources/lyte-cli/CLI.swift:29-30 — wantsAppKit = firstArg == "wire-view" || firstArg == "decode-probe" — versus /Users/shreeve/Data/Code/lyte/Sources/lyte-cli/WireViewCommand.swift:21-24: "Main.main treats every subcommand not on its non-UI list as a UI command". The invariant the CLI actually holds is the reverse, and it defaults the dangerous way: a future subcommand that opens a window gets dispatchMain(), the main dispatch queue never drains, and it reproduces the exact black-window symptom the header warns about — with the header reassuring the next reader it can't happen. I verified today's list is correct: wire-view returns into app.run() with everything retained (:451-456) and decode-probe's run() ends in Foundation.exit (DecodeProbeCommand.swift:190) or throws into LyteCLI.exit(withError:), so both genuinely need AppKit and every other subcommand is genuinely headless.

8. LOW / main-thread — the per-host preference accessors re-read the store from disk on every menu validation.
ConnectionModel.swift:842-855, :910-939 each call PinnedHostStore.load() in their getter, and LyteCommands.swift:50-91 binds three of them into Toggles that AppKit re-evaluates on every menu open and key-equivalent validation pass — three file reads + JSON decodes per pass, plus more from ConnectView.swift:120-167's context menu. Harmless today (small file), but it's synchronous disk I/O on the main actor sitting behind a UI-rate call site; a cached snapshot invalidated on save() would be the honest seam.

9. LOW / clarity — contradictory gauge-window comments in the same file.
ConnectionModel.swift:103-105 says the in-fps meter rides "the same ~1 s window shape as the delivery books' out-fps", while :1170-1173 (and VideoDeliveryBooks.swift:10, the owner's ruling) say 3 s. RateMeter's default is overlayGaugeWindowSeconds = 3.0, so the first comment is stale post-extraction — it's the one comment a reader would trust when judging whether the in/out slash-pair compares like with like.

10. LOW / correctness — wire-view's finish latch is a non-atomic test-and-set.
WireViewCommand.swift:407-410: let already = finished.value; finished.value = true; guard !already. Four triggers (SIGINT, window close, duration timer, session-closed event) fire on different queues; two landing together can both read false. LyteUdpSession.close/stop are internally latched (SessionFlag) so the wire behavior is safe, but printFinal() can double-print and two exit(0)s race — enough to corrupt the machine-parsed summary block that quality-probe.sh greps for.

11. LOW / clarity — the helper's version probe is dead API, so engaged is a claim rather than a fact.
LyteHelperProtocol.swift:13 declares version(reply:) "Liveness/version probe" and lyte-helperd/main.swift:135 implements it, but nothing in the app ever calls it. HelperClient.streamBegan() (HelperClient.swift:85-101) sets engaged = true purely from service.status == .enabled — and per the ledger's rule, remoteObjectProxy hands back a proxy whether or not a daemon exists. The awdl0 interface check is a good ground truth and is honestly documented, but the one reply-carrying call that could turn "registered" into "actually spawned" is present and unused; either wire it into streamBegan or delete it so the protocol stops implying a discipline the client doesn't practice.

12. LOW / clarity — ConnectionModel is a 1,252-line eight-role object.
ConnectionModel.swift now carries: the connect state machine, roaming/reconnect driving, chroma tier policy, host-audio posture, clipboard consent + watcher, bulk-drop coordination, the per-host preference accessors, and the ~180-line statsLines() renderer. The natural seams are already visible in the MARKs, and statsLines() in particular is pure formatting over snapshot structs — it could move to a StatsOverlayLines type in LyteUI with no behavior change and would then be pinnable (the wrap in finding #6 is exactly the kind of thing a test would have caught).

Strengths
The epoch fence works. sessionEpoch (ConnectionModel.swift:117, 364-369) is bumped in both teardown paths before the old session can speak, so cross-session event reordering — a genuine hazard given every event arrives via an unordered Task { @MainActor } — cannot resurrect negotiated flags on a dead session. That's the one place where the unordered hop would have bitten, and it's covered.
The video delivery hop is a real fix, not a patch. The serial videoDeliveryQueue + VideoDeliveryBooks (:100-102, :330-342) keeps frame order, gets enqueue off the receive thread so a CA transaction can't dam the audio demux, and the p50/p99 hop stat makes the failure it was built for visible. The nonisolated(unsafe) ownership-transfer comment is exactly right about why it's sound.
The hit-test capture rule. landsOnVideoSurface (LyteInputCapture.swift:125-138) correctly converts into the content view's superview space before hitTest, and the ancestor-hit-passes-through rule (with the CL-16 regression recorded in the comment) is the right invariant for SwiftUI overlays over an NSView. Coordinate mapping through the aspect-fit rect is scale-correct: points→normalized→host pixels cancels the backing scale factor, and unknown stream size drops rather than guesses.
Capability gating is negotiation-driven end to end. Strip buttons exist iff the key survived intersection, menus mirror the same model verbs with no state of their own, and the host-mute control renders the 0x19-confirmed posture rather than the ask — so a refused flip visibly snaps back instead of lying.
Sans-IO policies with injected clocks (StripRevealPolicy, RoamingPolicy, ChromaFallbackPolicy, RadioHoldPolicy) keep the views as thin drivers; StripRevealBooks being a deliberately non-Observable class to keep pointer-rate mutation out of SwiftUI invalidation is a good call, and its deadline-task loop provably can't spin (every tick outcome leads to a nil nextDeadline or a future one).
No GameStream-era remnants in the client shell. I grepped for the ⌃⌥ mouse-release chord, CGWarpMouse/CGAssociateMouseAndMouseCursorPosition, event taps, and Windows-VK mapping: the only hits are in docs/20260722-gamestream-client-plan-historical.md. LyteInputCapture is purely evdev/NSEvent-monitor based, and there is no mouse-lock mode left to have edge cases.
PasteboardSync is consent-shaped: start() re-baselines changeCount so pre-consent content is never read, the images rung gates whether image flavors are even read, and the content read happens under the same lock as the count check so an apply can't interleave.
lyte-helperd's hold accounting is per-connection with an invalidation release, so a crashed app can't leave AirDrop broken — the failure direction it chose to be safe in is the right one.
Bash Inspect tlv-flag-empty-block vector
IN
cd /Users/shreeve/Data/Code/lyte/Wire && python3 -c "
import json
d=json.load(open('Vectors/envelope-v1.json'))
for v in d['vectors']:
    if v.get('name')=='tlv-flag-empty-block': print(json.dumps(v,indent=1))
"

OUT
{
 "datagramHex": "020134120d0c0b0a08070605040302018877665544332211006c797465",
 "description": "Flags bit0 set with a zero TLV count: legal but non-canonical (the canonical encoding omits the block). Decodes to the nominal envelope with no extensions.",
 "envelope": {
  "chan": 2,
  "fecHex": "0x1122334455667788",
  "frame": 168496141,
  "seq": 4660,
  "timestampHex": "0x102030405060708"
 },
 "kind": "decodeLenient",
 "name": "tlv-flag-empty-block",
 "payloadHex": "6c797465"
}
The architecture agent is back first — ten findings, none severe, led by: the ARQ repack algorithm and its budget formula duplicated verbatim across HostWire/Session.swift and ReliableCtrlEndpoint.swift (with Wire as the natural shared home), no test anywhere driving the real client core against the real host core in one process (each end gates against a hand-built stand-in), and no mechanical guard forcing a new wire message type to have a frozen vector. It also confirmed the strengths run deep: the sans-IO lint is mechanically enforced, the phantom-typed clock domains make cross-end time mixing a type error, and dependency directions are clean everywhere.

Five agents still working — I'll hold the full synthesis until everything is in.

I've read the six TODO caveats first (they're excluded below), then read main.swift, SessionWire.swift, AudioWire.swift, Sniff.swift, Signals.swift, encode.c, capture.c, audio.c (+ headers), netio.c's recv path, and the three shell instruments in full.

Ranked findings
1 · HIGH · memory safety / thread model — AudioWire is freed without joining its loop thread
AudioWire.swift:121-125 (deinit) frees the PipeWire loop (lyte_pw_audio_free) and the Opus encoder with no join, and stop() (AudioWire.swift:198-204) waits on finished with a 2 s timeout and then proceeds regardless: thread = nil; restoreRouting(). Two live doors. (a) main.swift:1840 — try sink.flushEncoder() (or any throw after audio.start() at main.swift:1740) unwinds run(), releasing the local audioWire while the audio thread is still inside lyte_pw_audio_run; deinit then destroys the pw_main_loop under it, and the trampoline's Unmanaged.passUnretained (AudioWire.swift:86, 267-275) resolves a freed object on the next 5 ms callback. (b) On a 2 s-timed-out stop(), restoreRouting() → lyte_pw_audio_restore → roundtrip() (audio.c:117-123) calls pw_main_loop_run on the same loop the audio thread is still running — two threads inside one non-reentrant pw loop — and then main.swift:1748-1749's audioWire?.stop(); audioWire = nil drops the last reference and frees it. Failure scenario: NVENC returns an error at flush on a session where audio is up ⇒ SIGSEGV/heap corruption instead of the intended lyte-host: error: encoder flush failed. Fix shape: make stop() an unconditional join (or a while on the semaphore), and have deinit refuse to free while thread != nil.

2 · HIGH · memory safety — double free on AudioWire's init error paths
AudioWire.swift:83 assigns encoder = enc, which completes phase-1 initialization (every other stored property has a default). Swift runs deinit when a class initializer throws after self is fully initialized, so the explicit lyte_opus_enc_free(enc) at AudioWire.swift:90 (PipeWire audio setup failed) and at 109 (routing-state persist failed) is followed by deinit's lyte_opus_enc_free(encoder) at 124 on the same pointer. deinit's if let capture is correctly pre-nil'd at line 108, so the encoder is the only double — but it is a plain free() of a live opus struct. Failure scenario: a host with no default sink / no wireplumber (lyte_pw_audio_new fails, audio.c:401-405 or setup_virtual_sink) — the intended behavior is main.swift:1778's "audio: unavailable — video-only session"; the actual behavior is a glibc free(): double free detected abort of the whole host. Drop the explicit frees (let deinit own them) or make the C frees idempotent by nulling.

3 · HIGH · memory safety — the encode path trusts frame-0 geometry and never validates size/stride
capture.c:160-172 forwards d->chunk->size, d->chunk->stride and the currently negotiated c->format.size.{width,height} with no consistency check; main.swift:629-721 opens the encoder with the first frame's width/height and every later frame skips the geometry block entirely, so lyte_hevc_enc_send (encode.c:334-340) reads (e->height-1)*src_stride + e->width*4 bytes from the mapped buffer using dimensions that may no longer describe it. on_stream_param_changed (capture.c:80-120) accepts a size range of 1×1…8192×8192, so a mid-session renegotiation is expected, not exotic. Failure scenario: the user changes the monitor mode (or the portal restarts the stream) from 2560×1440 to 1920×1080 mid-session — the compositor now delivers ~8.3 MB buffers while the encoder still memcpys 1440 rows at the old stride, reading ~6 MB past the mapped MemFd ⇒ SIGBUS/SIGSEGV, or silently encoding adjacent heap. Cheap fix: reject (or fail()) any frame whose width/height differ from the opened encoder's, and require size >= (height-1)*stride + width*4 and stride > 0. The same "validate once, trust forever" shape exists in the audio leaf (AudioWire.swift:212-227 fixes channels from the first callback while audio.c:331-333 re-reads a->format.channels each buffer), but there the EnumFormat pins 2ch so it is only latent.

4 · MED-HIGH · error path / thread model — --no-idle-floor in session mode swallows SIGINT/SIGTERM and never services the session
main.swift:1828-1834 arms the tick only if opts.idleFloor, and Sink.onTick is the only reader of lyteTerminationRequested (main.swift:805-812), the only caller of wire.service() (814), and the only observer of wire.sessionEnded (821). But lyteInstallTerminationHandlers() (main.swift:1492) runs unconditionally in session mode, replacing the default SIGINT/SIGTERM disposition with a flag-setter nobody polls. Failure scenario: lyte-host --wire-listen 41151 --no-idle-floor; Ctrl-C and kill are now no-ops — the process must be SIGKILLed, which is exactly the path AudioWire.sweepLeftoverRouting exists to clean up after (--host-audio muted then strands the user's default sink until the next start). Secondary effects on the same flag: a peer-gone session runs to the safety timeout, and frameWindowSizes/qualityWindow*/stage*Us (only drained by the tick's flush*Window) grow without bound for the session's life. The header comment at SessionWire.swift:47-48 documents the beacon stall but not the signal swallow.

5 · MED · error path — PipeWire round-trips with no timeout can wedge startup and shutdown
capture.c:261-289 (resolve_target_serial) calls pw_main_loop_run inside lyte_pw_capture_new with no timer armed — the safety timeout is only added later, in lyte_pw_capture_run (capture.c:418-426). If the compositor/session manager never answers the pw_core_sync (done/error are the only exits, capture.c:233-253), the host blocks forever before printing anything past "portal: ScreenCast granted". audio.c:117-123 has the identical shape and is worse-placed: lyte_pw_audio_restore → roundtrip runs at shutdown, so a wedged wireplumber hangs the exit with the desktop's default sink still pointed at "Lyte Audio". Both want a bounded timer source (the pattern already exists in lyte_pw_capture_run) or a pw_loop iteration deadline.

6 · MED · memory safety — SessionWire.init's late throw double-frees and orphans the drain thread
SessionWire.swift:359-362 allocates scratch/recvScratch, 373-380 starts the drain thread holding a strong self, and only then can 382-388 throw (lyte_netio_free(n); scratch.deallocate(); throw). Self is fully initialized by then, so deinit (403-407) runs and repeats scratch.deallocate() and lyte_netio_free(netio) — a double free of both — while recvScratch is leaked by the manual path and the already-started lyte-wire-drain thread is left calling drainLoop() on a deallocated object. Currently unreachable from the CLI (main.swift:1440-1443 rejects --insecure without --wire-out first), so this is a latent trap rather than a live bug — but it is armed by any new throw added between line 359 and the end of init, and the fix is one line (move the insecure validation above the allocations, or drop the manual cleanup).

7 · MED · thread model — post-handshake configuration is published to a running thread without synchronization
The drain thread is started in init and, once the session establishes inside awaitClient (main.swift:1627), it runs drainLoop → drainToIdle → serviceOnce → session.receive → log(...), which reads inputInjector (SessionWire.swift:1450), clipboardApplyHandler (1387), clipboardImageApplyHandler (1411) and appends to pendingBulkMessages. Main then writes those same vars unlocked at main.swift:1684-1723 (w.inputInjector = injector, the clipboard closures, w.bulkShell = shell, w.audioRoutingHandler). Unsynchronized publication of class/closure references across threads is a real data race in Swift (non-atomic pointer store plus an ARC retain on the reader side). The window is small (between awaitClient returning and line 1723) but non-empty: a client that sends an input event or a clipboard set immediately after msg3 hits it. noteMonitorExtent (SessionWire.swift:1479-1481) is the mirror image — it mutates the injector from the video thread with no lock while injectInput uses it from the drain thread under lock; for UinputInjector that is a concurrent lyte_uinput_set_extent against a live inject. Route all of these through lock (they are all cold paths).

8 · MED-LOW · error path — unbounded send retry while holding the session lock
SessionWire.swift:1546-1562: if sent == 0 { usleep(200); continue } has no iteration bound and no deadline, and the whole flushOutbox runs under lock. A socket that persistently returns 0 from sendmmsg (a wedged interface, a full sndbuf that never drains) spins forever holding the one lock the audio thread's 5 ms cadence, the capture thread's ingest, and sessionEnded all need — the process wedges with no log line at all. notePeerGone/sent < 0 are handled; only the 0 case is open-ended. A retry cap (say 50 passes = 10 ms) that throws would land it in the same drainFailed path everything else uses.

9 · MED-LOW · thread model — lyte_pw_audio_quit writes loop state from a foreign thread
audio.c:500-504 sets a->exit_reason = 0 from whatever thread calls it (AudioWire.stop() on the main thread, onAudio on the audio thread) while the loop thread reads it at audio.c:495-497 and may concurrently store -1 from on_stream_state_changed/on_core_error. pw_main_loop_quit itself is eventfd-signalled and fine; the plain-int store is not. Practical consequence is small but real: a stream error that lands in the same instant as stop() is overwritten with "quit requested", so runError is never reported and main.swift:2093's run error line silently prints nothing. Make it _Atomic int (or only let the loop thread write it, with quit carrying an explicit reason field). Minor companion in the same family: capture.c:212-217's LYTE_PW_DEBUG line passes a possibly-NULL spa_dict_lookup result to %s — UB, benign on glibc.

10 · LOW · performance — a full copy of every encoded packet on the hot path in ratchet+session mode
main.swift:1213-1217 allocates a fresh [UInt8] and copies the entire packet per frame (lastEncodedPacket = Array(...)), while the value is consumed only on the rare convergence tick (main.swift:889-893). At the shipped --ratchet posture that is one malloc + memcpy of up to a ceiling-sized IDR (~300 KB) on the capture thread for every frame, to serve an event that happens once per idle episode. lastEncodedPacket.removeAll(keepingCapacity: true) + append(contentsOf:) removes the allocation; nothing removes the copy without restructuring, but the allocation is the expensive half. Same family, smaller: receiveAll (SessionWire.swift:1109-1114) rebuilds a 32-element lyte_netio_slot array on every pass of a loop that runs every ≤2 ms on the drain thread — hoisting it to a stored property is free. Print volume on the hot paths is fine (1 Hz quality, 1/5 s frames+stages, sparse IDR lines).

11 · LOW · shell — quality-probe.sh's wire leg cannot fail when the host never starts
Host/Scripts/quality-probe.sh:187-209: HOST_PID=$(ssh … & echo \$!) is unchecked, and the readiness loop at 195-198 (for _ in $(seq 1 20); grep -q 'awaiting client handshake') simply falls through after 20 s without a verdict. If the remote launch fails (stale HOST_BIN, portal consent pending, port in use), the script still runs wire-view for WIRE_SECS + 45 = 195 s, cats a nonexistent log into an empty local file, and parse_wire yields empty R_* — the summary block then prints FAIL rows with blank numbers that read like a measured regression. Since the script runs set -uo pipefail without -e, nothing upstream catches it either. One || { echo "wire leg: host never announced 'awaiting client handshake'"; exit 1; } after the loop closes it.

12 · LOW · shell — the secrets rail false-alarms on a host that has never paired
Host/Scripts/quality-probe.sh:103-107 runs sha256sum over three files and takes awk '{print $1}'; if ~/.config/lyte-host/paired_clients doesn't exist (the normal state of a freshly provisioned host, or one used only with --insecure), sha256sum emits two hashes instead of three and the line positions shift — sed -n 2p then compares the portal_token hash, which rotates by design on every host run, and KEY_OK reports *** CHANGED — INVESTIGATE *** on every clean run. Use sha256sum … 2>/dev/null | awk '{print $2, $1}' | sort keyed by filename, or [ -f ]-guard each. Neighbouring nits in the same file: psnr_numbers's remote heredoc failure surfaces only as empty read vars (a silent 0.00 dB FAIL), and corpus-harness.sh:206's ssh "$PUP" "rm -rf ~/$REMOTE" interpolates an env-overridable path unquoted into a remote rm -rf.

Strengths
The lock discipline in SessionWire is genuinely well-built: one lock, an explicitly documented lock → drainCondition order that is actually acyclic (signalDrain is called only after unlock at every one of its four call sites), the PR-#8 log buffering with emit/flushLogLines to keep console I/O out of the critical section, and every off-lock hand-off (clipboard applies, bulk messages, routing flips) drained into a local and released before the blocking work. The audio second-pass loop (SessionWire.swift:739-759) is bounded and hands leftovers to the sender thread rather than spinning.
audio.c's teardown is the best C in the tree: spa_hook_remove before every pw_proxy_destroy, restore-before-disconnect ordering with a stated reason, connection-owned sink so SIGKILL cannot leak it, and an on-disk crash ledger written before the switch with a next-start sweep — the failure model is thought through end to end.
encode.c's single goto fail → lyte_hevc_enc_free idiom makes every error path leak-free by construction (the calloc+idempotent-free pairing is exactly right), and set_opt/set_opt_int failing the open loudly rather than riding a default is the correct posture for an A/B instrument. set_err/averr are vsnprintf-bounded everywhere with no unbounded string handling anywhere in the three leaves.
The signal design is right: a flag-only handler writing one Int32 (matching sig_atomic_t on Linux) polled from a non-inlinable C callback, deliberately placed outside the top-level-code file with the reason written down.
The idle-floor/resend path really is copy-free now — lyte_hevc_enc_resend moves only pts and pict_type and correctly avoids av_frame_make_writable, with the reason (and the cost it would re-buy) recorded in the comment.
Test-coverage gaps worth closing (hardware-independent)
Every policy decision in Sink lives in the lyte-host executable target and is therefore untestable as written, though almost all of it is pure: the ratchet convergence rule (main.swift:870-880 — skip-bytes, the stableRatio band, stablePasses), the backpressure bound min(2 × 1e9/fps, 25 ms) (744-751), the chroma-hold deadline and grandfathered fallback (640-656), the IDR cause-attribution merge (909-1003, including the noResetRateMoves truth-by-observation branch), the starvation tripwire's three-way guard (1136-1155), and the percentile helper pct that is re-implemented three times with rounded(.up) indexing (1025, 1053, 1109) — an off-by-one there would silently mis-report every quality line. HostCore already demonstrates the pattern (Pacer, Histogram, EncoderRecipe are all extracted and pinned); moving these decision functions there would cost nothing and needs no GPU. Also unpinned and pure: AudioWire.emitPacket's mark-interpolation timestamp arithmetic (AudioWire.swift:234-253), errString on an unterminated buffer, and flushOutbox's batch-staging/offset math (SessionWire.swift:1524-1568), which a fake-netio seam could pin at the LYTE_NETIO_MAX_BATCH boundary and against the scratchCapacity precondition. The C leaves have no unit tests at all; repack_bgrx_gbrp and the yuv444 plane copy are pure and could be hashed through lyte-encode-check without touching NVENC.

Bash Collect exact line numbers
IN
grep -n "let seq = seqByChannel\|sealed = try crypto.seal\|lock.unlock()" Sources/LyteTransport/TransportSender.swift | head; echo ---; grep -n "if sourceCaptured\|peerAddress = source\|if n < 0\|ECONNREFUSED\|EAGAIN\|return   // socket closed" Sources/LyteTransport/UdpReceiveEndpoint.swift; echo ---; grep -n "retarget()\|private func retarget\|residuals.sort\|chronologicalSkewWindow" Sources/LyteTransport/AudioJitterBuffer.swift; echo ---; grep -n "func write\|writeCounter.store\|var depthFrames\|readCounter.load\|write = writeCounter.load" Sources/LyteTransport/LyteAudioPlayer.swift

OUT
63:        let seq = seqByChannel[channel.rawValue] ?? ChannelSeq(rawValue: 0)
65:        lock.unlock()
80:            sealed = try crypto.seal(
85:            lock.unlock()
93:        lock.unlock()
99:        defer { lock.unlock() }
---
7:// 100 ms SO_RCVTIMEO so stop() unblocks the loop, and ECONNREFUSED
222:            if n < 0 {
224:                if errno == ECONNREFUSED { continue }
225:                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
226:                return   // socket closed by stop()
229:            if sourceCaptured {
231:                peerAddress = source
340:            // ECONNREFUSED bounced off the host between sends is
---
359:        retarget()
372:    private func retarget() {
374:        let samples = chronologicalSkewWindow()
403:        residuals.sort()
422:    private func chronologicalSkewWindow() -> [Int64] {
---
124:    var depthFrames: Int {
126:            - readCounter.load(ordering: .relaxed)
139:        let read = readCounter.load(ordering: .relaxed)
140:        let write = writeCounter.load(ordering: .acquiring)
215:    func write(_ pcm: [Float]) {
217:        let write = writeCounter.load(ordering: .relaxed)
225:        writeCounter.store(write + frames, ordering: .releasing)
Bash Confirm recvGroups lifecycle
IN
cd /Users/shreeve/Data/Code/lyte/Wire/Sources/LyteWire && grep -n "recvGroups" ArqEndpoint.swift

OUT
232:    private var recvGroups: [UInt16: RecvGroup] = [:]
363:        if let existing = recvGroups[gid] {
370:                guard recvGroups.count < config.maxActiveReceiveGroups else {
392:            recvGroups[gid] = state
399:            recvGroups[gid] = state
407:            recvGroups[gid] = state
443:            recvGroups.removeValue(forKey: gid)
451:            recvGroups[gid] = state
620:            } else if let state = recvGroups[gid] {
I read the TODO caveats first and excluded those six items. Everything below was verified by reading the code paths named.

Ranked findings
1 — HIGH · concurrency/correctness · Sources/LyteTransport/TransportSender.swift:62-87 (with Wire/Sources/LyteWire/Crypto/NoiseTransport.swift:182-186)
send() allocates the channel seq under lock (line 63), unlocks at line 65, and only then builds the header and calls crypto.seal (line 80). NoiseTransport.seal requires the extended counter to be strictly .fresh and throws sendSequenceNotMonotonic otherwise. Channel 0 has three independent senders on three different threads: ReliableCtrlEndpoint.serviceLocked (main thread on sendInput, receive thread on ACK service, PTO timer thread), BeaconEchoResponder.emit (receive thread), and IdrRequester.emit (feedback-cadence thread) — see the wiring at LyteUdpSession.swift:457-489. Failure scenario: a beacon echo takes seq 41 on the receive thread while a keystroke's ARQ segment takes seq 42 on the main thread; the echo loses the race to NoiseTransportCrypto.lock, so the tracker commits 42 first and the echo's seal throws — but symmetrically the ARQ pass can lose, and then serviceLocked's catch (line 359) abandons every remaining repacked payload in that pass, delaying the keystroke by a full PTO. Both paths are self-healing (echo is telemetry, ARQ retransmits), which is exactly why this would never be noticed except as an occasional input-latency spike during a loss storm — precisely when IDR requests and ARQ traffic collide most. Fix shape: hold lock across allocate+seal, or move seq allocation inside the crypto lock. (The same allocate-outside-the-send shape exists at InputSender.swift:222-249, where nextSeq is read under the lock and incremented only after the send returns — harmless while a single capture thread calls it, a duplicate-seq trap the moment a second caller appears.)

2 — MEDIUM-HIGH · correctness/security · Sources/LyteTransport/UdpReceiveEndpoint.swift:202-205, 229-233
peerAddress is overwritten from any datagram whose source parses as AF_INET — before demux.ingest, i.e. before the envelope decode and before the AEAD ever sees the bytes. Every outbound datagram (ARQ segments carrying input events, feedback, echoes, IDR requests) goes to that address via sendToPeer. Failure scenario: anything that lands on the client's bound port — an off-path forgery, a stale datagram from a previous host session, a scanner — retargets the entire return leg until the next genuine host datagram restores it; a sustained trickle at ~50 Hz costs the session most of its ACKs and input while the host sees a dead client. The host side has PathValidator for the mirror case; the client has nothing. The fix is nearly free and strictly better for roaming too: adopt the source only when the outcome is .accepted (an authenticated datagram teaches a migrated host address just as well).

3 — MEDIUM · correctness · Sources/LyteTransport/UdpReceiveEndpoint.swift:222-227, :167-173
The receive loop tolerates ECONNREFUSED, EAGAIN, and EWOULDBLOCK and treats every other recvmsg error as "socket closed by stop()" — return, thread gone, silently. EINTR is not handled: one signal delivered to lyte-wire-recv without SA_RESTART (a profiler's SIGPROF, a debugger, any tooling that signals threads) permanently deafens the session; nothing fires an event, and the user sees a frozen frame until the 30 s liveness clock closes it. Related, same loop: fd is a plain var Int32 written by stop() on another thread while the loop reads it, and stop() close()s it without joining the thread — during a roaming re-dial the new endpoint's socket() can take the same fd number inside the ≤100 ms window before the old loop notices running == false. Both are one-liners (if errno == EINTR { continue }; atomic/guarded fd with a join or a self-pipe).

4 — MEDIUM · performance · Sources/LyteTransport/AudioJitterBuffer.swift:359, 372-418
retarget() runs on every fresh audio packet (200/s), on the receive thread, inside AudioReceiver's lock. Each call does: chronologicalSkewWindow() (once the ring fills, a 512-element two-slice concat = one allocation + copy), a 512-element residuals allocation, two least-squares passes, and residuals.sort() — 512 Doubles, 200 times a second. That is ~1M comparisons/s plus ~8 KB/packet of transient allocation, all to recompute a target that is quantized to whole 5 ms packets and physically cannot move meaningfully between adjacent arrivals. It also sits directly in front of the video demux on the same thread. Recomputing every N packets (or on a 25 ms cadence) is behaviourally indistinguishable and ~8× cheaper. Note PR #15 fixed exactly this shape ("pay for one sorting, not two") on the overlay side; this is the bigger remaining instance and it is on the hot path rather than the display path.

5 — MEDIUM · correctness/clarity · Sources/LyteTransport/AudioJitterBuffer.swift:172-174 vs the doc at :309-311
insert() calls noteArrivalForAdaptation first, before the late-drop check (:176-180) and the duplicate check (:181-184), and the only exclusion inside is guard !packet.recovered. The doc comment on that function states the opposite: "Fresh, wire-carried arrivals feed the adaptation (recovered packets arrive on parity's schedule and duplicates on retransmit luck — neither describes the path)." Duplicates are not excluded. Failure scenario: a network-duplicated packet (or a retransmit) for number N arrives 40 ms after N's slot; it is dropped for playout as a duplicate, but it has already contributed a +40 ms skew sample to the 512-deep window, where it survives ~2.6 s and inflates the p99−min spread that sets targetPackets — added playout latency purchased from a packet that was never played. The pairwise-deviation branch above it does guard (numberDelta != 0); the skew branch does not. Either move the call below the two guards or add the duplicate/late test there, and make the comment match.

6 — MEDIUM · concurrency · Sources/LyteTransport/LyteAudioPlayer.swift:124-127, 139-140, 215-226
The render side is correct: writeCounter.load(.acquiring) at :140 pairs with writeCounter.store(.releasing) at :225, and readCounter.store(.releasing) at the end of render pairs with… nothing — the writer never performs an acquiring load of readCounter. The no-overwrite invariant is instead enforced at the caller (pumpOnce's ringDepth + packetFrames <= capacity guard) using depthFrames, which loads both counters .relaxed (:124-127). That is the one half of the SPSC pair that isn't formally established; today it is unreachable in practice (1 s of capacity against a target of ≤20 packets, and the accelerator-flush write at the top of pumpOnce carries no capacity check at all but can only fire when the ring is below one packet). Worth either an .acquiring load in the depth used for the capacity decision, or a comment at write() stating that overflow safety lives at the call site — right now neither the code nor the header doctrine says where the invariant is held. Everything else about the render callback checks out: no locks, no allocation, no ObjC/Swift runtime calls, preallocated declick state, and the block captures the ring rather than the player.

7 — MEDIUM-LOW · performance · Sources/LyteTransport/NoiseTransportCrypto.swift:290-322 (+ ReceiveDemux.swift:92-123)
One NSLock guards both seal and unseal, though the two directions are entirely disjoint state (separate cipher states, separate trackers, separate epochs). Every outbound datagram therefore serializes behind an inbound AEAD open and vice-versa, at ~3k datagrams/s inbound. Compounding it, ReceiveDemux.ingest holds its lock across the whole crypto.unseal call, so the feedback thread's drainArrivalSamples/snapshotChannels also queue behind AEAD work. Neither is fatal (AEAD on 1.1 KB is a few µs), but splitting the crypto lock in two is a two-line change that removes the only send/receive coupling in the datagram path.

8 — MEDIUM-LOW · correctness/clarity · Wire/Sources/LyteWire/Crypto/NoiseTransport.swift:1-28, 130-135, 296-317
The rekey machinery — epoch bump, previous-epoch grace key, openTryingEpochs, rekeyDatagramThreshold = 2^24 — has no production caller on either end. grep for rekey outside Crypto/ finds only the vector generator and the test kit; there is no CTRL message type for rekey coordination in CtrlMessage.swift. So a session key lives for the entire session, the "rekey grace" path is dead code, and the file header's "the epoch (bumped by rekey, which also replaces the key via Noise REKEY)" describes something that never happens. Nonce uniqueness is still sound (the 64-bit extended counter is monotonic, so no reuse), so this is hygiene and doc-truth rather than a break — but the header should say "the primitive exists; no shell drives it yet", or it belongs in the deferred ledger.

9 — LOW-MEDIUM · correctness · Sources/LyteTransport/UdpReceiveEndpoint.swift:235 → FeedbackSender.swift:199-213
arrivalUs = kernelUs ?? (DispatchTime.now().uptimeNanoseconds / 1000) mixes two clock domains in one field: SCM_TIMESTAMP is wall-clock-since-epoch (~1.7×10¹⁵ µs) and the fallback is uptime-since-boot (~10¹¹ µs). Every consumer treats them as one domain. Failure scenario: a single datagram whose cmsg is absent or truncated gets a monotonic stamp; it becomes the min that buildDispersion uses as base (:199), so every other sample's delta is ~10¹⁵ µs, blows the u24 field, and the entire dispersion section is dropped and counted as decimated — the host's rate/queue estimator goes blind for that report with no signal that anything is wrong. ChannelStats.lastArrivalDeltaMicros goes similarly wild. A wall-clock NTP step has the same effect. Cheap fix: normalise to one domain at the stamp site, or tag the sample with which clock produced it.

10 — LOW · clarity/dead code · Sources/LyteTransport/LyteUdpSession.swift:926-932
handleDatagram(_:arrivalMicroseconds:) never reads arrivalMicroseconds — it takes now() at :932 and passes now.microseconds to the echo responder at :941. That is deliberate and correct (BeaconEchoResponder's doc at :87-93 explicitly forbids the wall-clock kernel stamp for t2), but the parameter is now a decoy: UdpReceiveEndpoint's doc at :39-43 still promises consumers "the same arrival stamp the demux got", and a future reader wiring t2 from the parameter would silently corrupt every RTT sample. Either drop the parameter from the core's hook or annotate it with the reason it is ignored.

11 — LOW · performance · Sources/LyteTransport/VideoRenderFactory.swift:55-69
Three full-frame copies per delivered frame: the assembler's unit.annexB, then lengthPrefixed() builds a second whole-frame array (:55), then CMBlockBufferCreateWithMemoryBlock(memoryBlock: nil) allocates a third and CMBlockBufferReplaceDataBytes copies into it (:59-69). At 60 fps with IDRs this is a few MB/s of avoidable memcpy on the receive thread. The Annex-B → length-prefix rewrite is in-place-able for 4-byte start codes, and the finished buffer can be handed to CoreMedia with a custom block source instead of copied. Small, but it is the only remaining per-frame copy chain and the sweep already went after this class of waste (PR #17).

Correctness-critical paths with no dedicated pin
TransportSender under concurrent same-channel senders. testSendPathAllocatesIndependentSeqsPerChannel (FeedbackPathTests:267) pins the single-threaded case only; nothing pins that two threads sealing on chan 0 both survive. This is finding #1's pin.
Receive-loop error taxonomy. LoopbackEndpointTests covers bind/receive/sendToPeer happy paths; no test asserts which errnos continue and which terminate, so #3 can regress invisibly.
Peer-address adoption policy. testSendToPeerReachesTheDatagramSource (LoopbackEndpointTests:126) pins the permissive behaviour; there is no pin saying an unauthenticated datagram must not retarget the return leg — so the fix for #2 would look like a test failure rather than a test-backed improvement.
AudioPcmRing.write capacity/overflow and true SPSC concurrency. The declick suite drives render against pre-filled state; nothing exercises writer-vs-reader wrap at capacity or the accelerator-flush write path.
Jitter-buffer adaptation inputs. AudioJitterGateTests pins target growth under bursty jitter, but nothing pins that a duplicate or already-late packet must not move targetPackets — the invariant #5 breaks.
HostClockModel.estimate's accepted.last!-as-offset0 under reordered ingest (HostClockModel.swift:140): anchor is chosen by max timestamp, offset0 by array position. testWindowSlidesAndEvicts covers eviction, not out-of-order ingest.
Strengths
The lock discipline around LyteUdpSessionCore is genuinely good: every callback (onEvent, reliable.send, processImageEvents, dispatch(actions)) fires strictly outside the lock, and the reliable endpoint mirrors it (events collected under the lock at ReliableCtrlEndpoint.swift:223-232, fired after the unlock), so the receive-thread → ARQ → machine → ARQ re-entry that would deadlock a naïve design is structurally impossible. The render callback is exemplary real-time code — preallocated declick state, ring-captured closure, no locks or allocation, and the underrun counter gated on recent write activity so a FROZEN blackout doesn't masquerade as a device underrun. Serial arithmetic is wrap-aware essentially everywhere it matters (Int32(bitPattern: a &- b) in the jitter buffer, the assembler dedupe, the photon-loop closure, the seq tracker). The replay window commits only after the AEAD opens, so forged headers cannot desync the counter. The evidence-stamp refactor (#12) and the adaptive pump (#18) both landed clean and read as intended. And the doc comments are, with the handful of exceptions above, unusually honest — several of them (the CL-8 detector deviation, the captureToFeed above-the-floor construction, the noteVideoShard fast-out trade) pre-empt exactly the questions a reviewer arrives with.

I've read the whole Wire/Sources/LyteWire tree (plus the vectors and the ARQ/video/bulk tests) against the four lenses. TODO.md's six advisory items are excluded below.

Ranked findings
1. [Medium — correctness] ARQ receive groups are never reclaimed; one-shot admission wedges permanently
Wire/Sources/LyteWire/ArqEndpoint.swift:232, 349–453 (removal only at :443)

recvGroups is removed from in exactly one place: a one-shot group that delivered its complete message (:443). There is no timeout, no LRU, no eviction, and poisoned groups (:379–382, :420–428) also stay forever. Failure scenario: a peer opens 63 one-shot groups that never complete — e.g. for each fresh group id it sends segment seq 1 (out of order, buffered) but never seq 0, or a single segment with endOfMessage: false. Each allocates a RecvGroup and none is ever removed, so recvGroups.count pins at maxActiveReceiveGroups (64, group 0 included). From then on every new one-shot group is refused at :369–375 with .tooManyReceiveGroups — and that path deliberately does not ackNeeded.insert(gid), so the honest sender gets no ACK and retransmits under PTO backoff (up to 8 s) forever. Concretely on the CTRL endpoint: IdleFrame (0x15) rides a fresh one-shot group per ratchet convergence, and its oneShotAcknowledged is the only input that drives SessionStateMachine's finalFrameAcknowledged → ACTIVE→IDLE (SessionStateMachine.swift:315–324). The session can therefore never reach IDLE again for its lifetime, while accumulating one permanently-retransmitting send group per attempt. ArqAdversarialTests.testHostileSegmentSprayIsBoundedAndDoesNotCorrupt asserts only that group 0 still delivers after a spray; it never asserts that a fresh one-shot is still admissible, which is the property that actually breaks.

2. [Medium — efficiency] poll() is O(all queued segments) with ~5 full scans, called once per datagram
Wire/Sources/LyteWire/ArqEndpoint.swift:557–582, 584–610, 659–690, 707–729

Every poll walks state.order (which holds all enqueued segments, sent or not, not just the in-flight window) about five times per group: groupDeadline's order.contains{} inside firePtoTimers, the probe loop, appendSegmentFrames' order.count{} for inFlight, the send loop itself, and groupDeadline again inside nextDeadline. Each pass is a dictionary lookup per element. enqueue caps a single message at maxMessageByteCount but places no bound on how many messages may be queued, so on chan 8 the depth is whatever the bulk credit window allows (~16 chunks × 60 segments ≈ 960 segments). Since the shell polls after every ingest/send, a 100 MB transfer pays ~96k polls × ~5k dictionary lookups — quadratic in queue depth for the same byte count. Secondary: firePtoTimers iterates sendGroups.keys while assigning back into sendGroups in the body (:585, :608); the live Keys view keeps the storage non-uniquely-referenced, so each assignment can copy the whole dictionary — appendSegmentFrames at :662 avoids this by iterating keys.sorted().

3. [Low-Medium — correctness] AudioDepacketizer derives its retention horizon from the incoming datagram's declared geometry
Wire/Sources/LyteWire/AudioDepacketizer.swift:143–156, 252–264

Both the staleness gate (age > Int32(horizonGroups * geometry.dataShards)) and evictBeyondHorizon(dataShards:) take k from whatever the arriving shard's FecField declares, not from the stream's established geometry. Failure scenario: a 4+2 stream whose group ids step by 4 normally retains 8 × 4 = 32 ids ≈ 8 groups. One datagram bearing a legal k = 1 geometry (a fresh group id, so the per-group geometry == check at :159 doesn't catch it) makes that call's horizon 8 × 1 = 8 ids ≈ 2 groups, and evictBeyondHorizon immediately drops every group more than two back — including groups still waiting for parity, which are then counted as groupsUnrecoverable and lose recoverable audio. The mirror case: a shard declaring k = 255 widens the admission window to 2040 ids, letting a peer keep ~1000× the intended number of Group records (each with a 255-entry slot array) alive. The horizon is a local resource-and-latency policy and should be pinned by the depacketizer's own configuration, not read off the wire.

4. [Low — correctness] VideoAssembler.makeRoom force-unwraps on an empty tracker when maxTrackedGroups <= 0
Wire/Sources/LyteWire/VideoAssembler.swift:368–381

guard groups.count >= config.maxTrackedGroups else { return nil } followed by groups.keys.min()!. With maxTrackedGroups = 0 (which VideoAssemblerConfig.init accepts without validation, :74–86), the very first shard on an empty assembler passes the guard (0 >= 0) and traps on the force-unwrap — a crash in the receive path, not a dropped shard. This is the same class as the documented inverted-threshold caveat but with a harder failure mode; VideoAssemblerConfig validates none of its five knobs.

5. [Low — clarity/correctness] CapabilityNegotiator doesn't enforce the ordering its header comment promises
Wire/Sources/LyteWire/CapabilityNegotiator.swift:100, 113–116, 121–136, 171–202

declarationSent is assigned at :114 and read nowhere in the module or the tests (verified by grep) — dead state. The file header says "any capability message before establishment's declaration … throws", but receive(_ declaration:) guards only on agreed == nil; a peer declaration processed before start() settles the session normally, so the promised precondition is unenforced and the variable that would enforce it is inert. Separately at :180–197: update.parameters.allSatisfy { … } is vacuously true for an empty parameter list, so a zero-parameter CapabilityUpdate yields .answerUpdate(status: .accepted, parameters: []) — an ack the shell then cannot encode (CapabilityMessages.swift:162–165 throws emptyUpdate). Not wire-reachable (CapabilityUpdate.decode rejects empty at :129), but it is a local-API trap with no guard.

6. [Low — efficiency] The video recovery path copies the frame twice and walks it twice more
Wire/Sources/LyteWire/NanorsBackend.swift:69–73, FecCoder.swift:95–101, VideoAssembler.swift:393–401 (via AnnexBCheck.swift:142–156)

recoverData materializes the full k·bs block into a fresh [UInt8] (:69), which FecDecoder.decode immediately re-copies via Array(rows.prefix(groupByteCount)) (:101) — two full copies of a frame up to 283 KB, on top of the C-side backing buffer. Then attemptDecode calls AnnexBCheck.isFrameShaped(bytes) and AnnexBCheck.containsIrap(bytes) back to back, and each independently re-runs nalUnits — two more full byte scans plus four array allocations (payloadStarts + units, twice). Returning a trimmed slice from the backend and walking the NALs once (shape + IRAP from one pass) removes both.

7. [Low — efficiency] ACK bitmap construction scans the whole receive window per group per poll
Wire/Sources/LyteWire/ArqEndpoint.swift:612–657

For every group owed an ACK, appendAckFrames allocates a 32-byte array and probes state.buffered[seq] receiveWindowSegments (256) times — even in the overwhelmingly common in-order case where buffered is empty and the bitmap ends up []. Under a segment spray, ackNeeded can hold up to 64 groups in one datagram's worth of frames, so a single hostile datagram costs ~16k dictionary lookups and 64 allocations at the next poll. Iterating state.buffered (bounded by the window and usually empty) and skipping the whole block when it is empty is equivalent and O(actual holes).

8. [Low — clarity] The reliable idle-frame path bypasses the integrity gate both other video paths enforce
Wire/Sources/LyteWire/IdleFrame.swift:107–130 vs. VideoPacketizer.swift:66–68 and VideoAssembler.swift:393–396

VideoAssembler's header states the W-G3 property as "under any injected fault the assembler emits correct bytes or nothing — recovered output that fails the Annex-B frame-shape check is suppressed, never delivered", and VideoPacketizer.packetize refuses non-frame-shaped input. IdleFrame.decode applies no shape check at all — it validates only the 13-byte header and a non-empty body — yet it carries the converged frame straight to the decoder. ARQ + Noise make byte corruption a non-issue, so this is not a live bug; but the "every path into the decoder is shape-gated" invariant is stated in one module and silently not held in the other, which is exactly the kind of gap the next carriage change (the planned move to a chan-4 endpoint) would inherit.

9. [Low — clarity] PathMessages is the one codec without the slice discipline the rest of the module follows
Wire/Sources/LyteWire/PathMessages.swift:47, 68, 91–102

Every other decoder in the module takes ArraySlice<UInt8> and offsets from payload.startIndex, with an [UInt8] convenience overload. decodePathMessage takes only [UInt8] and indexes absolute payload[0], payload[1], wireReadLE(payload[...], at: 2). Correct today (an Array's startIndex is 0), but the file is one "add an ArraySlice overload for symmetry" edit away from out-of-bounds reads on any non-zero-based slice — and every caller must currently pay an Array(...) copy to reach it.

Test-coverage assessment
Genuinely strong: the codec layer is pinned twice (hand-built byte tests + frozen vector files) with a malformed/hostile case per rejection reason, FecCoder sweeps every single/double erasure and asserts every triple fails honestly, ArqExhaustiveTests enumerates interleavings, and the adversarial suite covers forged ACKs, replayed ACKs, garbage floods, and the endless-message poison.

Honest gaps, in order of how much they'd have caught above:

ARQ receive-group lifecycle (finding 1). No test admits a one-shot group after the spray, and nothing exercises a partially-received one-shot group being abandoned. testHostileSegmentSprayIsBoundedAndDoesNotCorrupt checks boundedness and group-0 liveness, which is precisely the half that still works.
Config-validation boundaries. VideoAssemblerConfig, ArqConfig.packetThreshold, and AudioDepacketizer.horizonGroups accept degenerate values with no test asserting either rejection or safe behavior (finding 4).
Mixed-geometry adversity on the audio channel. AudioInteriorTests exercises a single fixed 4+2 geometry; nothing feeds a foreign k into an established stream (finding 3).
CapabilityNegotiator ordering preconditions. 14 tests, none covering receive(declaration:) before start() or an empty-parameter update (finding 5).
VideoAssembler capacity eviction of an already-decoded group. testEvictsLowestOnCapacity (VideoAssemblerTests.swift:338–352) evicts pending groups only; the case where makeRoom discards a decoded-but-held frame — which produces .evicted(.capacity) instead of .decoded, silently losing a frame the assembler had fully recovered — has no pin.
NoiseTransport rekey-grace × replay-window interaction. The grace path (openTryingEpochs, NoiseTransport.swift:266–294) and the shared, epoch-agnostic replay window are each covered, but not together across an epoch boundary.
Bash Check IDR demand consumption in shell
IN
grep -n "takeFreshKeyframeDemand\|takeFreshKeyframeRequest\|forceIdr\|forceKeyframe" Host/Sources/lyte-host/*.swift | head -20

OUT
Host/Sources/lyte-host/SessionWire.swift:525:        return session?.takeFreshKeyframeDemand() ?? []
Host/Sources/lyte-host/main.swift:901:    /// the takeFreshKeyframeRequest poll, consulted per encode).
Host/Sources/lyte-host/main.swift:910:        let forceIdr = framesIn == 0 || !demand.isEmpty
Host/Sources/lyte-host/main.swift:962:                                    forceIdr ? 1 : 0,
Host/Sources/lyte-host/main.swift:966:                                      forceIdr ? 1 : 0,
Host/Sources/lyte-host/main.swift:986:        // rode. A demanded IDR (forceIdr) coinciding with a no-reset
Host/Sources/lyte-host/main.swift:990:                ? (keyframes > keyframesBeforeSend && !forceIdr)
The app-shell agent is back with the strongest findings so far — two HIGH-severity, both verified with concrete failure paths:

Closing a stream window tears down nothing. There's no .onDisappear/deinit seam on the window-close verb — ⌘W mid-stream leaves the receive thread, machine beat, and feedback cadence running forever: the host keeps encoding full-rate video into a window nobody can see, the menu bar still says "streaming," and awdl0 stays forced down (AirDrop broken) until the app quits. Every other exit path is clean; it's specifically ⌘W that has no seam.

Mute doesn't survive reconnect. The roaming path pushes muted into a new session but the first-connect path doesn't — mute, disconnect, reconnect, and audio comes back at full volume while the strip still renders muted.

Also notable: held modifier keys are never flushed on app-switch (host left with Alt/Super latched), the helper client handles XPC invalidation but not interruption (a crashed daemon defeats the documented re-engage), and Keychain I/O on the main actor can beachball the app exactly when the signing prompt appears.

Four agents still working — full synthesis when they're all in.

I've read the full stack. Here are my findings.

Ranked findings
1. HIGH — Estimator soundness. One anomalously-low delay sample poisons the 10 s min-baseline and drives an uncorroborated geometric fall to the floor.
RateEstimator.swift:1248-1256 (baseline) + :1339-1345 / :1395-1398 (the fall).
The per-channel baseline is a plain min over the whole sampleWindowNS (10 s) with no outlier rejection, no minimum-sample requirement, and no re-baselining. Inflation is reportMin − baseline. The honesty law's execute condition is instant || (persisted && (queueGrew || honestLow || !selfExplaining)), and selfExplaining = backlogStanding && honestMedian == nil — so whenever the pacer's video backlog sits under 5 ms of wire time, !selfExplaining is true and the fall executes on persistence alone, with no honest evidence, no loss, and no queue growth. Failure scenario: a static/low-motion screen keeps the pacer backlog under backlogFloorBytes; the client's receive loop momentarily runs 15+ ms more responsive than usual (the code itself measures 7–13 ms of wake latency on that path at Session.swift:2399-2401), producing one low minDelayMicros. That sample pins the channel baseline for the next 10 s. Every subsequent report reads ≥15 ms inflated → 2 consecutive inflated reports → persisted → fall. With no honest median, demoted = belief ≈ rate, so the fall is a flat 0.85 × rate every 500 ms: ~20 beats over the 10 s the poison lives, i.e. 0.85^20 ≈ 4% of the starting rate — floor — on a path with zero loss. Recovery from the floor at 10 %/s then costs another ~40 s. Nothing in the belief machinery bounds this, because the belief tracks the rate down (censored samples raise it only to min(rate, pace)).

2. HIGH — VBV policy. exactTighten creates a rising-edge ratchet: the encoder can stay pinned up to 41 % below the live ceiling indefinitely.
EncoderVbv.swift:454-477 (tighten sets appliedMax = ceilingRate) vs. :485-490 (wantsLooser is judged purely on rung indices).
An exact tighten lands appliedMaxBitsPerSecond on ceilingRate, which can sit anywhere inside its rung's band, but the loosening test is clean || rungIndex(for: ceilingRate) < appliedIndex. Any recovery that stays inside the applied rung's band therefore never even arms looserWantedSince, and materialFall/bandCrossed are both false, so it is silently absorbed. Concrete (the shipped rungsPerOctave: 2, baselineMax 10 Mbps): a squeeze walks ceilingRate to 2 510 000 → rungIndex = 3 (band top 3 535 534), exact tighten pins appliedMax = 2 510 000. The path then recovers to ceilingRate = 3 500 000 (+39 %). margined = 3 850 000 → rungIndex 2, not > 3, so no tighten; rungIndex(3 500 000) = 3, not < 3, so wantsLooser is false. The encoder stays capped at 2.51 Mbps while the pacer runs at 3.5 Mbps — permanent 39 % under-fill until the ceiling crosses a rung boundary or goes clean (≥9 Mbps here). In pure-ladder mode this hole cannot exist (appliedMax == rungRate, so within-band absorption costs nothing); exact mode introduces it. The doc comment at :204-213 — "the last of the posture/pacer slack on the falling edge goes to zero … the rung ladder still names the bands for LOOSENING … untouched" — is true as written but omits that it creates new slack on the rising edge. Fix shape: judge wantsLooser against appliedMaxBitsPerSecond (with the deadband), not appliedIndex.

3. MEDIUM — Estimator. applyIdrPacing halves the rate on RECOVERY but leaves the capacity belief and the probe cadence untouched.
RateEstimator.swift:862-880.
This is the one place the estimator knows its evidence is stale — the doc on the same lines says "the stale estimate may be 10× the new path's capacity (resiliency §4)" — yet it moves only rateBitsPerSecond and lastAdjustAt. beliefBits (which by construction "falls only by invariant-2 demotion, never by aging"), cadenceHoldUntilNS, and cadenceBandFloorBits all survive the path change. Failure scenario: a session migrates from 90 Mbps Wi-Fi to a 5 Mbps tether. RECOVERY fires, rate → 45 Mbps, but probeCeiling = min(ceiling, belief × 1.10) is still ~99 Mbps, so HS-29's damping — the whole point of which was to stop slamming a wall the belief already located — is inert on the one transition where the wall definitely moved. The only brake is the fall machinery (2 inflated reports + 500 ms persistence + the 500 ms limiter). The symmetric problem: a stale cadenceBandFloorBits from a pre-migration failed probe can hold rises for up to 10 s on the new path for no reason.

4. MEDIUM — Repair lane / hostile client. An unknown-frame NACK arms the IDR latch with no throttle; a peer can force 100 % IDR encoding at report cadence.
Session.swift:2366-2367 (stale(.unavailable, armIdr: true)) → :1331/:1338 (staleNackKeyframePending) → lyte-host/main.swift:910 (forceIdr = framesIn == 0 || !demand.isEmpty, consulted per encode).
respondToNack arms the coalesced keyframe latch on every NACK naming a frame the repair store does not hold — including a frame number that never existed. Nothing rate-limits the arm. An authenticated client (buggy or malicious) putting one garbage FrameNumber in each 25–50 ms report keeps the latch permanently set, so every encoded frame at 60 fps becomes a forced IDR: an order-of-magnitude bitrate inflation, a guaranteed rate crash, and — under distro libavcodec — a full NVENC reset per frame. The other five demand sources are all host-armed and self-limiting (fallPurgeKeyframePending is bounded by the 500 ms fall limiter, unprotectableKeyframePending by the host's own drop). Only the NACK arm is driven at wire cadence by the peer. The parse itself is solid (bounds at FeedbackReport.swift:63-92 cap 6 NACKs / 112 samples / 8 channels per report), so the vector is the policy, not the codec. Worth a per-interval cap on .unavailable arms.

5. MEDIUM-LOW — Estimator. Delivery trains are segmented channel-blind while delay is deliberately per-channel; the two disagree on the header's own DSCP premise.
RateEstimator.swift:1084-1091 and :1216-1222 (segmentation by send gap only, across all channels) vs. :1228-1257 (per-channel delay minima).
The header at :26-36 argues at length that a global minimum is wrong precisely because "DSCP-aware bottlenecks (Wi-Fi EDCA, any prio qdisc) give audio a fast lane" — then closeTrain builds firstArrival/lastArrival from a train that mixes chan-1 (131 B, CS?) and chan-2 (1152 B, CS5) datagrams. A fast-lane audio arrival landing at either end of the span distorts the measured rate, and that rate is what drives the honest/censored/compressed trichotomy at :1138-1190. The stretched-train guard catches the single-dominating-gap shape, but not a systematic per-lane skew spread across several interleaved audio packets. This bites hardest at low rates, where gapNS = max(2 ms, 3 × wire time) widens to ~55 ms at the 500 kbps floor and audio's 5 ms cadence chains it into every train — i.e. the rate-scaled gap added for the floor-deadlock fix re-opened the door that minTrainPackets was introduced to close (the comment at :1107-1117 documents exactly that failure). Consider requiring a train to be single-channel, or classifying per channel.

6. LOW — Latent state divergence. RateEstimator.fecRegime is hard-coded .clean and never seeded from the session config.
RateEstimator.swift:602 vs. Session.swift:947 (regime: config.regime → VideoChannelConfig).
SessionConfig.regime flows to VideoChannel only. A session opened with regime: .lossy therefore starts with the channel on the lossy column and the estimator's ladder latch believing .clean; the estimator can then only ever emit a .lossy step (a no-op) and cannot emit the .clean step-down until after a rung-3 event has occurred. Unreachable today (nothing in lyte-host sets .lossy, default is .clean) — same shape as the caveats list: armed by a future config touch. RateEstimatorConfig should carry the opening regime.

7. LOW — Fall purge does not invalidate the repair store, so purged bytes are partially re-admitted.
Session.swift:2231-2246 + VideoChannel.swift:691-704.
purgeQueuedVideo settles the pacer, pending, and queuedShardsByFrame — but not store. The purged frames keep repaired == false on every shard, so the next report's NACKs against them pass repairAnchor/repairByteCount and are re-enqueued at .videoTail, at the crashed rate, on frames the pending fallPurge IDR is about to supersede (the nack.frame < lastKeyframeNumber guard cannot help — the IDR is only latched, minted a frame later). Bounded in practice: the serialization half of the budget gate at :2417-2423 refuses anything large at the fallen rate, and it is one attempt per shard. Still worth marking the purged frames repaired (or evicting them) so the purge's decision is honored end-to-end.

8. EFFICIENCY — recentNackShards is rebuilt wholesale on every feedback report.
RateEstimator.swift:950-952. recentNackShards = recentNackShards.filter { ... } allocates a fresh dictionary every ingest (20–40 Hz). Under a repair storm the dict holds up to ~1 500 entries/report × 1 s of window; every other window in expireWindows uses in-place removeAll(where:). Same treatment applies here (or an insertion-ordered ring, since entries expire FIFO).

9. EFFICIENCY — closeTrain makes four throwaway arrays per train.
RateEstimator.swift:1095-1097 (train.map(\.arrivalMicros).min() and .max() — two full array allocations to compute two scalars), :1135-1136 (.map(\.paceBitsPerSecond).max()), :1150 (.map(\.arrivalMicros).sorted(), when the max-gap and span could come from one pass over the already-send-ordered slice). Per train, per report. Also :920 / :931 (.sorted() on 3-element medians, up to twice per report).

10. EFFICIENCY — window-wide allocations on hot reads.
RateEstimator.swift:561-563: deliveryRateBitsPerSecond does deliveryWindow.map { Int($0.rate) }.max() — a full copy of the 10 s window on every read, and it is a public surface the session logs and applyIdrPacing both hit. A running max (or .lazy.map) is free. Same shape at Histogram.swift:43-49: percentile sorts the entire retained pool (up to 65 536 samples) on each call, and p50/p95/p99 are three separate calls.

11. EFFICIENCY — three allocations and two full payload copies per shard on the encode path.
VideoChannel.swift:771-780: encodeSealed builds a header array, then a sealed array, then a third array for the final datagram; retain at :480-483 copies every payload again (that one is load-bearing for repair). At 231 shards for a worst-case protected IDR that is ~700 allocations per keyframe on the capture thread, under the session lock. An in-place encode into a single pre-sized buffer is the obvious win.

12. CLARITY — stale doc comments on the rate seam, and Session.swift's split seams.
Pacer.swift:126-129 states the injected rate is "0.8 × btlRate capped at the negotiated session rate" and "until HS-16 lands, the negotiated ceiling itself is the default" — both retired: RateEstimator.swift:78-82 explicitly rules that the standing rate is deliberately allowed above btlRate × 0.8, and HS-16 landed. VideoChannelConfig.rateBitsPerSecond at :92-94 carries the same "until HS-16 negotiates" text. For the 2 974-line Session.swift, the natural seams, in order of independence: (a) the bulk/clipboard-image lane — sendBulk/absorbBulkArq/consumeBulkStreamMessage/processImageEvents/serviceBulkArq/sendBulkDatagram plus bulkArq/bulkSeq/imageRng, ~200 lines at :1618-1814 with its own ARQ endpoint and near-zero video coupling; (b) the repair lane — respondToNack, repairFreezeBudgetNS, clientGlassEvidence/openingIdrShardTotal/openingExemptAttempts/openingExemptBytes, ~180 lines at :2270-2447; (c) the congestion seam — noteSent, ingestFeedback, the fall purge, feedbackCadenceEwmaNS, and the estimator surfaces at :2600-2680; (d) the keyframe-demand latch — six independent *Pending bools whose arm sites are scattered across five methods and whose clear site is one block at :1336-1340, a natural 30-line value type; (e) the ~400 lines of pure declarations (SessionEvent, SessionCounters, SessionDropReason, NackStaleReason, …) at :235-650, which are a file of their own.

Control-loop behaviors with no dedicated gate test
Delay-baseline behavior over the window — nothing pins how the per-channel rolling min responds to an outlier, to baseline aging out, or to the haveBaseline == false reset at RateEstimator.swift:1258-1263 (which silently clears an in-progress inflation streak when a report's samples all land on a fresh channel). Finding 1 lives here.
Rising-edge behavior in exactTighten mode — EncoderVbvGateTests pins the falling edge (…LandsOnTheCeilingRate, …RetunesTheMaterialWithinBandFall, …StillParksInsideTheDeadband) and the clean restore, but never a within-band rise. Finding 2.
applyIdrPacing's effect on estimator state — testIdrPacingNumbers checks the returned rate only; nothing asserts what happens to beliefBits, cadenceHoldUntilNS, inflatedStreakSinceNS, or lastDownshiftAt across a WAKE/RECOVERY. Finding 3.
FEC regime step-DOWN in isolation — regimeStepDownHoldNS is exercised inside testEstimatorPostFecLossDownshiftsAndStepsRegime; there is no pin that a fresh NACK re-anchors lastPostFecEvidenceAt mid-hold, nor for the estimator/channel regime disagreement in finding 6.
NACK-driven IDR arming rate — testNackForEvictedFrameIsUnavailableAndArmsIdr proves one arm; nothing bounds arms per unit time. Finding 4.
Fall purge ↔ repair store interaction — FallPurgeGateTests has four tests, none covering a NACK arriving for a just-purged frame. Finding 7.
Pacer clock discipline — testNextWakeIsExactAndMonotonic exists, but nothing pins nextBatch's now - t.enqueuedAt (an unchecked UInt64 subtraction at Pacer.swift:309 that traps on a non-monotonic pair). I verified the shell is safe today — every now in SessionWire.swift is read under the session lock, so enqueue/pump times are totally ordered — but that invariant is held by convention alone.
Strengths
The send-ledger recycling at RateEstimator.swift:762-770 is subtly correct: the eviction guard ledgerIndex[evicted.key] == ledgerHead means a re-sent (channel, seq) overwrites the index without the stale slot later evicting the live entry, and matchDispersion re-checks record.key == key as a second barrier. The Pacer.ClassQueue.bytesQueued running total is coherent through every path I traced — push, both pop branches (including the array-reset when a head catches its tail), and dropClass's wholesale ClassQueue() reassignment — with no path that mutates the arrays behind its back. Pacer.setRate correctly preserves a negative balance across a rate fall (tokens = min(tokens, burstBytes)), which is exactly what makes the HS-31 audio exemption's repayment honest. The HS-30 belief cap sustainable = min(rate, pace) at :1205 is the load-bearing bound that keeps beliefBits inside the configured ceiling and makes every downstream Int(Double) conversion overflow-safe even against a hostile client's compressed arrival deltas — I looked for a division-by-zero or overflow in the bytes × 8 / span math and could not find one (spanSeconds is guarded by lastArrival > firstArrival, rateBitsPerSecond by the floor). absorbChannelLedgers's &- wrap-tolerant differencing with the < 1 << 31 regression guard, and absorbDelay's reportMin - min(baseline, reportMin) clamp, both handle hostile counters without trapping. And the recusedNackFrames argument is evaluated before estimator.ingest and therefore before the fall purge mutates the queue — the ordering that recusal correctness depends on — which is easy to get wrong and is right here.

The host-runtime agent is back — the toughest report yet, with three HIGH memory-safety findings, all verified against the code:

AudioWire can be freed while its PipeWire thread still runs — an encoder-flush error unwinds run() and deinit destroys the loop under the live audio thread (SIGSEGV instead of a clean error), and stop()'s 2 s timeout proceeds regardless.
Double-free on AudioWire's init error paths — Swift runs deinit when a class init throws after full initialization, so the explicit lyte_opus_enc_free runs twice; a host with no default sink aborts the process instead of degrading to video-only.
The encode path trusts frame-0 geometry forever — a mid-session resolution change (which PipeWire's negotiated 1×1–8192×8192 range explicitly allows) has the encoder reading megabytes past the mapped buffer.
Plus a MED-HIGH: --no-idle-floor in session mode swallows SIGINT/SIGTERM entirely (the tick is the only thing that polls the flag). Notably, finding 3 dovetails with the P-3 ruling's "residual belt" — the geometry-change teardown that was named-not-blocking is exactly the missing validation here.

Three agents still out (Wire core, client transport, host congestion stack). Full synthesis when they land.

The Wire-core agent is in — no HIGHs (the protocol core is the strongest territory, as its 486 tests suggest), but its top finding is a real one: ARQ receive groups are never reclaimed, so a hostile or buggy peer can pin the 64-group table forever, after which every new one-shot message is refused without an ACK — and since the idle-frame acknowledgment is what drives ACTIVE→IDLE, the session could permanently lose its idle flip. It also caught the audio depacketizer deriving its retention horizon from the incoming datagram's declared FEC geometry rather than its own config (a single hostile k=1 shard flushes recoverable audio), a poll() that's quadratic in ARQ queue depth during bulk transfers, and a crash-shaped config edge in VideoAssembler.makeRoom.

Two agents left — client transport and the host congestion stack.

The client-transport agent is in with one HIGH and a strong middle tier:

HIGH — channel-0 seq race: TransportSender.send() allocates the sequence number under its lock but seals outside it, and channel 0 has three senders on three threads (ARQ, beacon echo, IDR requester). A lost race makes the Noise counter reject the seal, and the ARQ catch then abandons the whole repacked pass — an occasional input-latency spike precisely during loss storms.
MED-HIGH — unauthenticated peer retarget: the client adopts any datagram's source address as the return destination before authentication; an off-path trickle can steal the entire return leg. Fix is nearly free: adopt only on .accepted.
Also: an unhandled EINTR can permanently deafen the receive loop; the jitter buffer sorts a 512-double window 200 times per second inside the receive-thread lock (the biggest remaining hot-path waste in the client); duplicates feed the skew window despite the doc claiming otherwise; and the Noise rekey machinery is verified dead code — no caller on either end.
One agent left — the host congestion stack — then I'll write the full synthesis.

Update Todos

Final comprehensive review — all 6 agents complete

Synthesize final analysis report
All six agents are in. Here is the final comprehensive analysis of the Lyte codebase.

Overall verdict
The architecture is sound, the disciplines are real, and nothing found threatens the product's design. Six independent deep reads (architecture, Wire core, client transport, host congestion, host runtime/C, app shell) produced zero architectural rework items — every finding is a localized fix inside a structure worth keeping. The distribution is telling: the most-tested territory (Wire, 486 pins) yielded no HIGHs at all, while the two territories that hardware and UI make hardest to test (the host's C/thread seams and the app's window lifecycle) yielded almost all of them. The codebase's known weaknesses are exactly where its test discipline couldn't reach — which is the profile of a healthy codebase, not a troubled one.

Tier 1 — real bugs a user can hit (fix-worthy now)
⌘W tears down nothing (ConnectionWindow.swift:5, ConnectionModel.swift:451). Closing a stream window — the most natural macOS verb — leaves the receive thread, machine beat, and feedback cadence alive forever: the host keeps encoding full-rate into the void, the menu bar still says "streaming," and awdl0 stays held down (AirDrop broken) until app quit. Every other exit path is clean; this one verb has no seam.

Mid-session resolution change reads past the capture buffer (main.swift:629, capture.c:160, encode.c:334). The encoder opens with frame-0 geometry and never revalidates size/stride, while PipeWire's negotiated format range explicitly permits renegotiation — a monitor-mode change mid-session has the encode memcpy reading megabytes past the mapped buffer. This is the concrete mechanism behind the P-3 ruling's "residual belt" (verify a geometry change produces a clean typed teardown) — it currently produces a SIGSEGV, not a teardown.

AudioWire thread-lifetime hazards (AudioWire.swift:83, :121-125, :198-204). Two related HIGHs: deinit frees the PipeWire loop without joining its thread (any throw after audio.start() → callback into a freed object), and the init error path double-frees the Opus encoder because Swift runs deinit after a fully-initialized class init throws — so a host with no default sink aborts instead of degrading to the intended video-only session.

Channel-0 seq/seal race (TransportSender.swift:62-87). The sequence number is allocated under one lock but sealed outside it, and chan 0 has three senders on three threads (ARQ, beacon echo, IDR requester). A lost race makes Noise reject the seal and the ARQ catch abandons the whole repacked pass — an input-latency spike that lands precisely during loss storms, when all three senders collide. Self-healing, which is why it's never been seen as anything but noise.

Estimator baseline poisoning (RateEstimator.swift:1248-1256, :1339-1345). The per-channel delay baseline is a raw 10 s min with no outlier rejection, and when video backlog is low the fall law executes on persistence alone. One anomalously-fast receive wake (the code itself measures 7–13 ms jitter on that path) pins the baseline, every later report reads inflated, and the rate takes an uncorroborated geometric walk to the floor on a clean path — then pays ~40 s climbing back. This is the most likely explanation yet for unexplained rate sags on clean air.

exactTighten rising-edge ratchet (EncoderVbv.swift:454-490) — a finding against sweep PR #7, mine. Exact mode lands appliedMax mid-band, but loosening is judged on rung indices, so a recovery that stays inside the band never arms: the worked example pins the encoder 39% below the live ceiling indefinitely. Pure-ladder mode can't have this hole; exact mode introduced it. Fix: judge wantsLooser against the applied rate, not the applied index.

Tier 2 — hostile-peer and edge-condition hardening
Unauthenticated peer retarget (UdpReceiveEndpoint.swift:202-233) — the client adopts any datagram's source as the return address before the AEAD sees it; an off-path trickle steals the return leg. Adopt only on .accepted (which also improves roaming).
NACK-driven IDR arming has no throttle (Session.swift:2366) — an authenticated client naming one garbage frame per report forces 100% IDR encoding at 60 fps. The only peer-driven, unbounded arm among six otherwise self-limiting sources.
ARQ receive groups never reclaimed (ArqEndpoint.swift:369-443) — 64 abandoned one-shot groups wedge admission permanently, and since idle-frame ACKs drive ACTIVE→IDLE, the session can lose its idle flip for life. The adversarial test covers exactly the half that still works.
Audio horizon read off the wire (AudioDepacketizer.swift:143-156) — retention policy derives from the arriving shard's declared FEC geometry; one k=1 shard flushes recoverable audio.
--no-idle-floor session mode swallows SIGINT/SIGTERM (main.swift:1828-1834) — the tick is the only poller of the termination flag, the session service, and the stats windows; without it the process is SIGKILL-only and buffers grow unbounded.
EINTR deafens the receive loop; fd closed unsynchronized (UdpReceiveEndpoint.swift:222-227); unbounded send-retry under the session lock (SessionWire.swift:1546-1562); post-handshake config published to the running drain thread unlocked (main.swift:1684-1723); helper XPC handles invalidation but not interruption (HelperClient.swift:114-119) — a crashed daemon defeats the documented re-engage; held keys never flushed on app-switch (LyteInputCapture.swift:203-231) — host left with modifiers latched; mute not applied on fresh connect (ConnectionModel.swift:280-305).
Tier 3 — performance and efficiency (ranked by payoff)
Jitter-buffer retarget sorts 512 doubles 200×/s inside the receive-thread lock (AudioJitterBuffer.swift:359-418) — ~1M comparisons/s ahead of the video demux for a target quantized to 5 ms packets; a 25 ms cadence is behaviorally identical and ~8× cheaper. The single biggest remaining hot-path waste.
ARQ poll() quadratic in queue depth during bulk transfers (~5 full scans per poll); ACK bitmap scans 256 slots even when empty (ArqEndpoint.swift:557-729).
Per-shard triple allocation on the host encode path (VideoChannel.swift:771-780) — ~700 allocations per protected IDR under the session lock; per-frame 300 KB copy in ratchet mode for a once-per-episode consumer (main.swift:1213-1217); FEC recovery double-copy + double NAL walk (Wire); three full-frame copies per delivered frame client-side (VideoRenderFactory.swift:55-69); estimator window allocations on hot reads.
Architecture & clarity
No structural rework needed. The themes: the ARQ repack + budget formula duplicated verbatim across packages (natural home: Wire); no test anywhere runs the real client core against the real host core — each end gates against a hand-built stand-in, and the seam to fix it (Host's libraries build on macOS) already exists; no mechanical guard forces a new wire message type to have a frozen vector; host AudioWire shadows Wire's AudioWire and the C leaf's 48000/2/240 constants are bound to the wire dialect by nothing; ~1,100 lines of corpus-harness code ship inside the production app binary; the Noise rekey machinery is dead code (no caller on either end — the header should say so); and the three giant files (Session.swift 2,974, main.swift 2,140, ConnectionModel.swift 1,252) have their natural split seams named precisely in the reports. A dozen stale doc comments were caught, the sharpest being lyte-cli's UI-command rule documented as the exact inverse of what the code does.

Strengths — what to protect
The sans-IO discipline is mechanically enforced (a lint that runs under swift test), not aspirational. Phantom-typed clock domains make cross-end time confusion a compile error. The vector contract has external oracles, hand-computed anchors, and a third-platform WASM attestation. Lock disciplines on both session cores are genuinely good — events fire strictly outside locks on both ends, making the re-entrant deadlock structurally impossible. The audio render callback is exemplary real-time code. audio.c's teardown (crash ledger written before the routing switch, next-start sweep) is the best C in the tree. Serial arithmetic is wrap-aware essentially everywhere it matters. And the doc comments are unusually honest — several pre-empt exactly the questions a reviewer arrives with.

Caveat on confidence: every finding was read-verified with a concrete failure scenario by its agent, but none have been adversarially re-verified or reproduced live — the Tier 1 items deserve a reproducing gate test alongside each fix, same as the sweep's discipline.

If you want these worked, my suggested shape is the proven one: commit the findings to a ledger and run the PR train — Tier 1 first (six PRs, each with its pin), then Tier 2's hostile-peer hardening, with Tier 3 and the architecture items as a follow-on sweep. Say the word and I'll set it up