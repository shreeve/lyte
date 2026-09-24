import Foundation
import Security
import XCTest
@testable import LyteTransport
import LyteWire

final class ClientNoiseIdentityProviderTests: XCTestCase {
    func testConcurrentCallersCoalesceAndCacheOneIdentity() async throws {
        let state = LoaderState()
        let expected = NoiseKeyPair.generate()
        let provider = ClientNoiseIdentityProvider { policy in
            XCTAssertEqual(policy, .allow)
            state.noteCall()
            Thread.sleep(forTimeInterval: 0.02)
            return expected
        }

        async let first = provider.identity()
        async let second = provider.identity()
        let identities = try await [first, second]

        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(identities[0].publicKey, expected.publicKey)
        XCTAssertEqual(identities[1].publicKey, expected.publicKey)
        XCTAssertEqual(provider.cachedIdentity?.publicKey, expected.publicKey)

        let third = try await provider.identity(authenticationUI: .fail)
        XCTAssertEqual(third.publicKey, expected.publicKey)
        XCTAssertEqual(state.calls, 1, "the cached roaming path never re-queries")
    }

    func testFailureDoesNotPoisonCacheAndPolicyIsForwarded() async {
        let state = LoaderState()
        let provider = ClientNoiseIdentityProvider { policy in
            state.noteCall(policy)
            throw ClientNoiseIdentityError.keychain(errSecInteractionNotAllowed)
        }

        do {
            _ = try await provider.identity(authenticationUI: .fail)
            XCTFail("expected Keychain failure")
        } catch {
            XCTAssertNil(provider.cachedIdentity)
            XCTAssertEqual(state.policies, [.fail])
        }
    }

    func testNoninteractiveLookupForwardsFailPolicyAndCaches() async throws {
        let state = LoaderState()
        let expected = NoiseKeyPair.generate()
        let provider = ClientNoiseIdentityProvider { policy in
            state.noteCall(policy)
            XCTAssertEqual(policy, .fail)
            return expected
        }

        let identity = try await provider.identity(authenticationUI: .fail)

        XCTAssertEqual(identity.publicKey, expected.publicKey)
        XCTAssertEqual(state.policies, [.fail])
        XCTAssertEqual(provider.cachedIdentity?.publicKey, expected.publicKey)
    }

    private final class LoaderState: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var seen: [ClientNoiseIdentityProvider.AuthenticationUI] = []

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        var policies: [ClientNoiseIdentityProvider.AuthenticationUI] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func noteCall(
            _ policy: ClientNoiseIdentityProvider.AuthenticationUI = .allow
        ) {
            lock.lock()
            count += 1
            seen.append(policy)
            lock.unlock()
        }
    }

    /// A lost first-mint race re-reads the winner's key under the SAME
    /// authentication-UI policy: automatic roaming never raises UI.
    func testDuplicateItemReloadKeepsTheCallersUIPolicy() throws {
        let winner = NoiseKeyPair.generate()
        var loads: [Bool] = []
        let identity = try ClientNoiseIdentity.loadOrCreate(
            allowAuthenticationUI: false,
            load: { allowUI in
                loads.append(allowUI)
                return loads.count == 1 ? nil : winner
            },
            add: { _ in errSecDuplicateItem })
        XCTAssertEqual(identity.privateKey, winner.privateKey)
        XCTAssertEqual(loads, [false, false])
    }
}
