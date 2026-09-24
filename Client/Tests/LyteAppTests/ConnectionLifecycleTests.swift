import Foundation
import LyteClientCore
import LyteTransport
import LyteWire
import XCTest
@testable import Lyte

/// The connection window's lifecycle, driven through the production
/// `ConnectionModel` with its IO seams (`ConnectionServices`) replaced by
/// an in-process harness: session starts that can be held open and
/// resolved later, a scripted discovery browse, and books of every
/// session ended and every stream begun. Pins the fences that keep late
/// async results (dials, identity lookups, browses) from reaching a
/// window whose lifecycle has moved on.
@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    // MARK: - Connect fencing

    func testDisconnectWhileDialingClosesTheLateSessionInsteadOfStreaming() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.hold]
        let model = ConnectionModel(services: harness.services)

        let connect = Task { await model.connectLyte(harness.host) }
        try await harness.waitForStarts(1)
        model.disconnect()
        harness.resolveStart(0, with: .success(()))
        await connect.value

        guard case .pickHost = model.phase else {
            return XCTFail("a dial that finished after disconnect streamed: \(model.phase)")
        }
        XCTAssertNil(model.lyteSession)
        XCTAssertEqual(harness.streamsBegan, 0,
                       "the helper hold must not be taken for an orphan")
        XCTAssertTrue(harness.wasEnded(harness.started[0]),
                      "the orphaned session must be closed")
    }

    func testConnectingScreenCancelReturnsToThePicker() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.hold]
        let model = ConnectionModel(services: harness.services)

        let connect = Task { await model.connectLyte(harness.host) }
        try await harness.waitForStarts(1)
        model.disconnect()
        guard case .pickHost = model.phase else {
            return XCTFail("Cancel left the window at \(model.phase)")
        }
        harness.resolveStart(0, with: .failure(harness.silence))
        await connect.value
        guard case .pickHost = model.phase else {
            return XCTFail("a cancelled dial's failure resurfaced: \(model.phase)")
        }
    }

    func testCancelDuringIdentityLookupNeverDialsOverTheNextConnect() async throws {
        let harness = LifecycleHarness()
        harness.holdFirstIdentity = true
        harness.startPlan = [.succeed, .succeed]
        let model = ConnectionModel(services: harness.services)

        let stale = Task { await model.connectLyte(harness.host) }
        try await harness.waitUntil { harness.identityWaiting }
        model.disconnect()

        await model.connectLyte(harness.host)
        let live = try XCTUnwrap(model.lyteSession)
        XCTAssertEqual(harness.started.count, 1)

        harness.releaseIdentity()
        await stale.value
        XCTAssertEqual(harness.started.count, 1,
                       "a superseded connect dialed after its identity lookup")
        XCTAssertTrue(model.lyteSession === live)
        guard case .streaming = model.phase else {
            return XCTFail("the live session lost its window: \(model.phase)")
        }
    }

    func testRoamingStartsFromTheAddressTheConnectReached() async throws {
        let harness = LifecycleHarness()
        // The host restarted and re-registered elsewhere: the first dial
        // draws silence, the re-browse finds it at its new address.
        harness.startPlan = [
            .fail(TransportCryptoError.handshakeFailed("no response from host")),
            .succeed, .hold,
        ]
        harness.browseResult = [DiscoveredLyteHost(
            name: "pup", address: "10.9.9.10", port: 41_999, wireVersion: nil,
            publicKeyHash: harness.host.publicKeyHash)]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)
        XCTAssertEqual(model.hostAddress, "10.9.9.10")

        model.reconnectNow()
        XCTAssertEqual(model.roamingStatus,
                       .reconnecting(address: "10.9.9.10", discovered: false),
                       "the probe dial must target where the host was reached")
    }

    // MARK: - Roaming fencing

    func testCurrentRoamingDialIsAdopted() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed, .hold]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)

        model.reconnectNow()
        try await harness.waitForStarts(2)
        harness.resolveStart(1, with: .success(()))
        try await harness.waitUntil { model.lyteSession != nil }

        XCTAssertTrue(model.lyteSession === harness.started[1])
        XCTAssertEqual(model.roamingStatus, .attached)
    }

    func testStaleRoamingDialSuccessNeverReplacesAFreshSession() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed, .hold, .succeed]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)

        model.reconnectNow()
        try await harness.waitForStarts(2)
        model.disconnect()
        await model.connectLyte(harness.host)
        let fresh = try XCTUnwrap(model.lyteSession)
        XCTAssertTrue(fresh === harness.started[2])

        harness.resolveStart(1, with: .success(()))
        try await harness.waitUntil { harness.wasEnded(harness.started[1]) }

        XCTAssertTrue(model.lyteSession === fresh,
                      "a stale roaming dial replaced the live session")
        XCTAssertFalse(harness.wasEnded(fresh))
        XCTAssertEqual(model.roamingStatus, .attached)
    }

    func testStaleRoamingDialFailureLeavesTheFreshPolicyAttached() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed, .hold, .succeed]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)

        model.reconnectNow()
        try await harness.waitForStarts(2)
        model.disconnect()
        await model.connectLyte(harness.host)

        harness.resolveStart(1, with: .failure(harness.silence))
        try await harness.settle()

        XCTAssertEqual(model.roamingStatus, .attached,
                       "a stale dial failure set a healthy session hunting")
        XCTAssertTrue(model.lyteSession === harness.started[2])
    }

    // MARK: - Host goodbyes

    func testHostShutdownGoodbyeRoamsInsteadOfEndingTheWindow() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed, .hold]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)
        let first = try XCTUnwrap(model.lyteSession)

        model.handleLyteEvent(.closed(.peerTeardown(.shuttingDown)))

        guard case .streaming = model.phase else {
            return XCTFail("a host restart ended the window: \(model.phase)")
        }
        XCTAssertNil(model.lyteSession)
        XCTAssertEqual(harness.endings(of: first), [.silent],
                       "a closed session has nobody to say goodbye to")
        try await harness.waitForStarts(2)
        XCTAssertNotEqual(model.roamingStatus, .attached)
        XCTAssertEqual(harness.streamsEnded, 0)
    }

    func testHostTakeoverGoodbyeEndsTheWindow() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)

        model.handleLyteEvent(.closed(.peerTeardown(.takenOver)))

        guard case .failed = model.phase else {
            return XCTFail("a takeover must end the window: \(model.phase)")
        }
        XCTAssertNil(model.lyteSession)
        XCTAssertEqual(harness.streamsEnded, 1)
        XCTAssertFalse(model.canReconnect)
    }

    func testSessionCloseVerdicts() {
        XCTAssertEqual(ConnectionModel.closeVerdict(.localTeardown(.shuttingDown)),
                       .ignore)
        XCTAssertEqual(ConnectionModel.closeVerdict(.livenessTimeout), .roam)
        XCTAssertEqual(ConnectionModel.closeVerdict(.peerTeardown(.shuttingDown)),
                       .roam)
        XCTAssertEqual(ConnectionModel.closeVerdict(.peerTeardown(.takenOver)),
                       .end("session taken over by another client"))
    }

    // MARK: - File transfer

    /// A chan-8 message the session refuses to queue never reaches the
    /// host; the pill names why instead of the transfer stalling silently.
    func testRefusedBulkSendNoticeNamesTheCause() {
        XCTAssertEqual(
            ConnectionModel.bulkSendRefusalNotice(ArqSendError.queueFull),
            "File transfer stalled — the send queue is full")
        XCTAssertEqual(
            ConnectionModel.bulkSendRefusalNotice(ArqSendError.emptyMessage),
            "File transfer stalled — send refused (emptyMessage)")
        XCTAssertEqual(
            ConnectionModel.bulkSendRefusalNotice(BulkChannelError.notNegotiated),
            "File transfer stopped — the host no longer accepts files")
    }
}

/// In-process stand-ins for everything `ConnectionModel` reaches outside
/// the process. Session objects are real `LyteUdpSession`s that are never
/// started (construction does no IO); their `start` is scripted per call.
final class LifecycleHarness: @unchecked Sendable {
    enum StartStep {
        case succeed
        case hold
        case fail(any Error)
    }

    let host: DiscoveredLyteHost
    let silence = TransportCryptoError.handshakeFailed("refused (harness)")
    var startPlan: [StartStep] = []
    var holdFirstIdentity = false
    var browseResult: [DiscoveredLyteHost] = []

    private let lock = NSLock()
    private let clientIdentity = NoiseKeyPair.generate()
    private var pins = PinnedHostStore()
    private var _started: [LyteUdpSession] = []
    private var heldStarts: [Int: CheckedContinuation<Void, Error>] = [:]
    private var earlyResults: [Int: Result<Void, Error>] = [:]
    private var _ended: [(ObjectIdentifier, ConnectionServices.SessionEnd)] = []
    private var identityCalls = 0
    private var heldIdentity: CheckedContinuation<Void, Never>?
    private var _streamsBegan = 0
    private var _streamsEnded = 0
    private var _pinLoads = 0
    private var _pinSaves = 0

    init() {
        let key = (0..<32).map { UInt8($0 &* 7 &+ 3) }
        pins.pin(staticPublicKey: key, name: "pup", address: "10.9.9.9",
                 port: 41_999, pairedAt: "2026-09-01T00:00:00Z")
        host = DiscoveredLyteHost(
            name: "pup", address: "10.9.9.9", port: 41_999, wireVersion: nil,
            publicKeyHash: LyteDiscovery.publicKeyHash(ofStaticPublicKey: key))
    }

    var started: [LyteUdpSession] { locked { _started } }
    var streamsBegan: Int { locked { _streamsBegan } }
    var streamsEnded: Int { locked { _streamsEnded } }
    var pinLoads: Int { locked { _pinLoads } }
    var pinSaves: Int { locked { _pinSaves } }
    var savedPins: PinnedHostStore { locked { pins } }
    var identityWaiting: Bool { locked { heldIdentity != nil } }

    func wasEnded(_ session: LyteUdpSession) -> Bool {
        !endings(of: session).isEmpty
    }

    func endings(of session: LyteUdpSession) -> [ConnectionServices.SessionEnd] {
        locked { _ended.filter { $0.0 == ObjectIdentifier(session) }.map(\.1) }
    }

    func resolveStart(_ index: Int, with result: Result<Void, Error>) {
        let held = locked { () -> CheckedContinuation<Void, Error>? in
            guard let held = heldStarts.removeValue(forKey: index) else {
                earlyResults[index] = result
                return nil
            }
            return held
        }
        held?.resume(with: result)
    }

    func releaseIdentity() {
        let held = locked { () -> CheckedContinuation<Void, Never>? in
            defer { heldIdentity = nil }
            return heldIdentity
        }
        held?.resume()
    }

    var services: ConnectionServices {
        ConnectionServices(
            loadPins: { [self] in locked { _pinLoads += 1; return pins } },
            savePins: { [self] store in locked { _pinSaves += 1; pins = store } },
            identity: { [self] _ in
                let hold = locked { () -> Bool in
                    identityCalls += 1
                    return holdFirstIdentity && identityCalls == 1
                }
                if hold {
                    await withCheckedContinuation { continuation in
                        locked { heldIdentity = continuation }
                    }
                }
                return clientIdentity
            },
            cachedIdentity: { [self] in clientIdentity },
            browse: { [self] _ in locked { browseResult } },
            startSession: { [self] session in
                let (index, step) = locked { () -> (Int, StartStep) in
                    _started.append(session)
                    let index = _started.count - 1
                    return (index, index < startPlan.count
                        ? startPlan[index] : .succeed)
                }
                switch step {
                case .succeed:
                    return
                case .fail(let error):
                    throw error
                case .hold:
                    try await withCheckedThrowingContinuation { continuation in
                        let early = locked { () -> Result<Void, Error>? in
                            if let early = earlyResults.removeValue(forKey: index) {
                                return early
                            }
                            heldStarts[index] = continuation
                            return nil
                        }
                        if let early { continuation.resume(with: early) }
                    }
                }
            },
            endSession: { [self] session, end in
                locked { _ended.append((ObjectIdentifier(session), end)) }
            },
            watchPath: { _ in {} },
            streamBegan: { [self] in locked { _streamsBegan += 1 } },
            streamEnded: { [self] in locked { _streamsEnded += 1 } },
            now: { SystemClockForTests.nowMicroseconds })
    }

    func waitForStarts(_ count: Int) async throws {
        try await waitUntil { self.started.count >= count }
    }

    /// Polls a MainActor condition, yielding to the tasks under test.
    @MainActor
    func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw HarnessTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Lets every queued MainActor hop run.
    @MainActor
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

struct HarnessTimeout: Error, CustomStringConvertible {
    var description: String { "harness condition never held" }
}

private enum SystemClockForTests {
    static var nowMicroseconds: UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000)
    }
}
