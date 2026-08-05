import LyteClientSession
import LyteWire
import XCTest

final class ClientClipboardSessionTests: XCTestCase {
    private let text = Capabilities.wireDefault.declaringClipboardText()
    private var images: Capabilities {
        text.declaringClipboardImages()
    }

    private struct CountingRng: RandomNumberGenerator {
        var nextValue: UInt64

        mutating func next() -> UInt64 {
            defer { nextValue &+= 1 }
            return nextValue
        }
    }

    func testLocalTextRequiresAgreementAndConsentThenPinsBytes() {
        var session = ClientClipboardSession(
            textSharingAtStart: false,
            imageSharingAtStart: false)

        XCTAssertEqual(
            session.shareLocalText("secret", agreed: nil).shareOutcome,
            .notNegotiated)
        XCTAssertEqual(
            session.shareLocalText("secret", agreed: text).shareOutcome,
            .sharingDisabled)

        session.setTextSharing(true)
        let admitted = session.shareLocalText("hello", agreed: text)
        XCTAssertEqual(admitted.shareOutcome, .shared)
        XCTAssertEqual(admitted.outboundReliable, [[
            CtrlMessageType.clipboardSet,
            0x68, 0x65, 0x6C, 0x6C, 0x6F,
        ]])

        session.noteLocalTextSent("hello")
        XCTAssertEqual(
            session.shareLocalText("hello", agreed: text).shareOutcome,
            .suppressedDuplicate)
    }

    func testAcceptedRemoteTextArmsOneEchoSuppression() throws {
        var session = ClientClipboardSession(
            textSharingAtStart: true,
            imageSharingAtStart: false)
        let announce = try ClipboardAnnounce(text: "from host").encode()

        XCTAssertEqual(
            session.receiveReliable(announce, agreed: text),
            .textChanged("from host"))
        XCTAssertEqual(
            session.shareLocalText("from host", agreed: text).shareOutcome,
            .suppressedEcho)
        XCTAssertEqual(
            session.shareLocalText("from host", agreed: text).shareOutcome,
            .shared,
            "the remote-apply echo entry is consume-once")
    }

    func testInboundTextFailuresStayTypedAndCannotApplyContent() throws {
        var disabled = ClientClipboardSession(
            textSharingAtStart: false,
            imageSharingAtStart: false)
        let announce = try ClipboardAnnounce(text: "host").encode()

        XCTAssertEqual(
            disabled.receiveReliable(announce, agreed: text),
            .textIgnoredDisabled(byteCount: 4))
        disabled.setTextSharing(true)
        XCTAssertEqual(
            disabled.receiveReliable(announce, agreed: .wireDefault),
            .unnegotiatedTextAnnounce)
        XCTAssertEqual(
            disabled.receiveReliable(
                [CtrlMessageType.clipboardAnnounce], agreed: text),
            .malformedTextAnnounce)
        XCTAssertEqual(
            disabled.receiveReliable(
                [CtrlMessageType.clipboardSet], agreed: text),
            .roleConfusedTextSet,
            "direction is invalid even when the body is malformed")
        XCTAssertNil(disabled.receiveReliable(
            [CtrlMessageType.idleFrame], agreed: text))
    }

    func testLocalImagePolicyOwnsGatesLaneAndWireSeparation() {
        var rng = CountingRng(nextValue: 7)
        let digest = [UInt8](repeating: 0xA5, count: 32)
        let data = [UInt8](repeating: 0x3C, count: 12)
        var session = ClientClipboardSession(
            textSharingAtStart: true,
            imageSharingAtStart: false,
            imageByteCeiling: 16)

        XCTAssertEqual(
            session.shareLocalImage(
                data, sha256: digest, rng: &rng, agreed: images
            ).shareOutcome,
            .sharingDisabled)
        session.setImageSharing(true)
        XCTAssertEqual(
            session.shareLocalImage(
                data, sha256: digest, rng: &rng, agreed: text
            ).shareOutcome,
            .notNegotiated)

        let admitted = session.shareLocalImage(
            data, sha256: digest, rng: &rng, agreed: images)
        XCTAssertEqual(admitted.shareOutcome, .shared)
        XCTAssertGreaterThanOrEqual(admitted.outboundBulk.count, 2)
        XCTAssertEqual(
            admitted.outboundBulk.first?.first,
            CtrlMessageType.clipboardImageCargo)
        XCTAssertFalse(admitted.events.contains { event in
            if case .image(.send) = event { return true }
            return false
        }, "send actions are separated from observable events")
        XCTAssertEqual(session.imageCounters.sharesStarted, 1)

        var secondRng = CountingRng(nextValue: 9)
        XCTAssertEqual(
            session.shareLocalImage(
                [UInt8](repeating: 1, count: 17),
                sha256: digest,
                rng: &secondRng,
                agreed: images
            ).shareOutcome,
            .suppressedBusy,
            "the active clipboard-image lane is single-transfer")

        var fresh = ClientClipboardSession(
            textSharingAtStart: true,
            imageSharingAtStart: true,
            imageByteCeiling: 16)
        XCTAssertEqual(
            fresh.shareLocalImage(
                [UInt8](repeating: 1, count: 17),
                sha256: [UInt8](repeating: 2, count: 32),
                rng: &secondRng,
                agreed: images
            ).shareOutcome,
            .overBudget(17))
    }

    func testInboundImageMarkerOwnsCapabilityAndConsentJudgment() throws {
        let cargo = try ClipboardImageCargo(
            transferId: 42,
            mime: ClipboardImageWire.pngMime).encode()
        var session = ClientClipboardSession(
            textSharingAtStart: false,
            imageSharingAtStart: false)

        XCTAssertEqual(
            session.receiveImageCargo(cargo, agreed: text).events,
            [.unnegotiatedImageCargo])

        let declined = session.receiveImageCargo(cargo, agreed: images)
        XCTAssertTrue(declined.events.contains { event in
            guard case .image(.refused) = event else { return false }
            return true
        })
        XCTAssertEqual(
            try BulkMessage.decode(try XCTUnwrap(
                declined.outboundBulk.first)).transferId,
            42)
        XCTAssertEqual(session.imageCounters.receivesRefused, 1)

        XCTAssertEqual(
            session.receiveImageCargo(
                [CtrlMessageType.clipboardImageCargo], agreed: images
            ).events,
            [.malformedImageCargo(byteCount: 1)])
    }

    func testEnabledImageMarkerClaimsItsFollowingOffer() throws {
        let digest = [UInt8](repeating: 0x44, count: 32)
        let cargo = try ClipboardImageCargo(
            transferId: 51,
            mime: ClipboardImageWire.pngMime)
        let offer = try BulkOffer(
            transferId: 51,
            totalByteCount: 4,
            chunkByteCount: UInt32(BulkWire.defaultChunkByteCount),
            sha256: digest,
            name: ClipboardImageWire.wireName,
            mimeHint: ClipboardImageWire.pngMime)
        let message = BulkMessage.offer(offer)
        var session = ClientClipboardSession(
            textSharingAtStart: true,
            imageSharingAtStart: true)

        XCTAssertEqual(
            session.receiveImageCargo(cargo.encode(), agreed: images),
            ClientClipboardSessionDecision())
        XCTAssertTrue(session.claimsBulk(message))
        let decision = session.receiveBulk(message) { _ in digest }
        XCTAssertFalse(decision.outboundBulk.isEmpty)
        XCTAssertTrue(session.claimsBulk(message))
    }
}
