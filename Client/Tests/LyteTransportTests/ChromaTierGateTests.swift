import XCTest
import Foundation
import LyteTransport
import LyteWire

// THE GATE (H4 V-5): the client half of owner decision 1 — the
// three-tier Chroma control's mechanics, pinned:
//
//   1. DECLARATION-AS-CHOICE: each tier declares exactly ONE chroma
//      mode (Good → [yuv420], Best → [yuv444]); the agreed
//      intersection against a V-4 host ([420, 444]) is the singleton,
//      and the singleton IS the choice. Better is DORMANT — no yuv422
//      wire id exists (that append is a Wire/ slice) — so it declares
//      nothing and cannot be selected.
//   2. THE FALLBACK VERDICT: a non-Good declaration meeting a host
//      without the tier draws the typed `noCommonChromaMode`; the
//      policy's verdict is re-dial at Good (banner alongside), and
//      ONLY that failure on ONLY a non-Good tier — a codec mismatch
//      is not a chroma problem and Good has nowhere lower to go.
//   3. PER-HOST PERSISTENCE: the tier rides PinnedHost like the CL-13
//      "start muted" and CL-15 clipboard preferences — optional field
//      (old files decode unchanged), raw-string stored (a future
//      tier's file reads as the default here), Good stored as nil
//      (clean files), preserved across a pin refresh.
//   4. THE STREAM AUDIT: SPS `chroma_format_idc` parsed off real
//      encoder output — the committed 4:2:0 corpus IDR and a frozen
//      Rext 4:4:4 SPS from pup's production leaf (EPBs included) —
//      and the audit's one-confirmation / doctor-on-mismatch
//      discipline.

final class ChromaTierGateTests: XCTestCase {

    // MARK: - 1. Declaration-as-choice

    func testTiersDeclareExactlyOneModeAndBetterIsDormant() {
        XCTAssertEqual(ChromaTier.good.declaredChromaModes,
                       [CapabilityChroma.yuv420])
        XCTAssertEqual(ChromaTier.best.declaredChromaModes,
                       [CapabilityChroma.yuv444])
        XCTAssertNil(ChromaTier.better.declaredChromaModes,
                     "no yuv422 wire id exists — Better declares nothing")
        XCTAssertTrue(ChromaTier.good.isSelectable)
        XCTAssertFalse(ChromaTier.better.isSelectable)
        XCTAssertTrue(ChromaTier.best.isSelectable)
        // The three-tier shape ships whole: the control renders all
        // three rungs even though one is dormant.
        XCTAssertEqual(ChromaTier.allCases, [.good, .better, .best])
    }

    func testDeclaringChromaSetsTheSingletonAndEncodesCanonically() throws {
        let base = Capabilities.wireDefault
        let best = base.declaringChroma(tier: .best)
        XCTAssertEqual(best.chromaModes, [CapabilityChroma.yuv444])
        let good = base.declaringChroma(tier: .good)
        XCTAssertEqual(good.chromaModes, [CapabilityChroma.yuv420])
        // Better has nothing to declare: the set rides unchanged
        // (belt-and-suspenders — the control never lets it through).
        XCTAssertEqual(base.declaringChroma(tier: .better), base)
        // The singleton encodes/decodes through the frozen CBOR shape.
        let decoded = try Capabilities.decodeCbor(try best.encodeCbor())
        XCTAssertEqual(decoded.chromaModes, [CapabilityChroma.yuv444])
    }

    func testBestAgainstV4HostAgreesTheSingleton() throws {
        // The V-4 host declares [420, 444] (self-probe passed); the
        // client's Best singleton intersects to exactly [444] — the
        // host's ChromaPosture maps that singleton to the Rext
        // encoder. The choice travels as the declaration.
        var negotiator = CapabilityNegotiator(
            role: .client,
            local: Capabilities.wireDefault.declaringChroma(tier: .best))
        _ = negotiator.start()
        var hostCaps = Capabilities.wireDefault
        hostCaps.chromaModes = [
            CapabilityChroma.yuv420, CapabilityChroma.yuv444,
        ]
        let event = try negotiator.receive(
            CapabilityDeclaration(capabilities: hostCaps))
        guard case .agreed(let agreed) = event else {
            return XCTFail("expected agreement, got \(event)")
        }
        XCTAssertEqual(agreed.chromaModes, [CapabilityChroma.yuv444])
    }

    func testBestAgainst420OnlyHostDrawsNoCommonChromaMode() {
        // The fallback trigger, at the negotiator: Best against a
        // pre-V-4 (or probe-failed) host whose list is [420] only.
        var negotiator = CapabilityNegotiator(
            role: .client,
            local: Capabilities.wireDefault.declaringChroma(tier: .best))
        _ = negotiator.start()
        XCTAssertThrowsError(try negotiator.receive(
            CapabilityDeclaration(capabilities: .wireDefault))
        ) { error in
            XCTAssertEqual(error as? CapabilityNegotiationError,
                           .noCommonChromaMode)
        }
    }

    // MARK: - 2. The fallback verdict

    func testFallbackPolicyRedialsAtGoodOnlyForChromaFailures() {
        XCTAssertEqual(
            ChromaFallbackPolicy.verdict(
                declaredTier: .best, failure: .noCommonChromaMode),
            .redialAtGood)
        // Good has nowhere lower to go — a chroma failure at Good is
        // a real failure (and cannot loop the re-dial).
        XCTAssertEqual(
            ChromaFallbackPolicy.verdict(
                declaredTier: .good, failure: .noCommonChromaMode),
            .fail)
        // A codec mismatch is not a chroma problem.
        XCTAssertEqual(
            ChromaFallbackPolicy.verdict(
                declaredTier: .best, failure: .noCommonVideoCodec),
            .fail)
    }

    // MARK: - 3. Per-host persistence

    private func makePinnedStore() -> (PinnedHostStore, pkh: String) {
        var store = PinnedHostStore()
        let key: [UInt8] = (0..<32).map { UInt8($0) }
        store.pin(staticPublicKey: key, name: "pup",
                  address: "10.0.0.249", port: 41_151,
                  pairedAt: "2026-07-22T00:00:00Z")
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
        return (store, pkh)
    }

    func testChromaTierPersistsPerHostAndDefaultsToGood() throws {
        let made = makePinnedStore()
        var store = made.0
        let pkh = made.pkh
        // Unset = Good (the shipped posture).
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .good)
        XCTAssertTrue(store.setChromaTier(publicKeyHash: pkh, tier: .best))
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .best)
        // Round-trips through the JSON shelf shape.
        let decoded = try JSONDecoder().decode(
            PinnedHostStore.self, from: try JSONEncoder().encode(store))
        XCTAssertEqual(decoded.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .best)
        // Good writes nil — the default keeps the file clean (the
        // setShareClipboard precedent).
        XCTAssertTrue(store.setChromaTier(publicKeyHash: pkh, tier: .good))
        XCTAssertNil(store.host(publicKeyHash: pkh)?.chromaTier)
        // An unpinned hash has nothing to hang the preference on.
        XCTAssertFalse(store.setChromaTier(
            publicKeyHash: String(repeating: "ab", count: 32),
            tier: .best))
    }

    func testUnknownAndUnselectableStoredTiersReadAsGood() {
        let made = makePinnedStore()
        var store = made.0
        let pkh = made.pkh
        // A future build's tier this build doesn't know: decode fine,
        // read as the default — the connect must always have a
        // declarable tier in hand.
        store.hosts[pkh]?.chromaTier = "ultra"
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .good)
        // The dormant Better can land in a file only by hand-editing;
        // it is not declarable, so it reads as Good too.
        store.hosts[pkh]?.chromaTier = "better"
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .good)
    }

    func testPinRefreshPreservesTheChromaTier() {
        let made = makePinnedStore()
        var store = made.0
        let pkh = made.pkh
        _ = store.setChromaTier(publicKeyHash: pkh, tier: .best)
        // A re-pair is a trust event, not a settings reset (the
        // CL-13/CL-15 preference rule, third verse).
        let key: [UInt8] = (0..<32).map { UInt8($0) }
        store.pin(staticPublicKey: key, name: "pup",
                  address: "10.0.0.7", port: 41_151,
                  pairedAt: "2026-07-29T00:00:00Z")
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .best)
    }

    // MARK: - 4. The SPS chroma read, on real encoder output

    /// The frozen Rext 4:4:4 SPS — pup's production leaf
    /// (lyte-encode-check, EncoderRecipe.best444: p4/ull/qres +
    /// rext/rgb_mode yuv444, cq4) encoding 1920×1080, captured
    /// 2026-07-29. Carries emulation-prevention bytes (00 00 03 runs
    /// in the compat flags and VUI), so this vector exercises the RBSP
    /// strip too.
    private static let rext444SpsHex = "4201010408000003009e08000003"
        + "00007b900078100220f89cb2e94842322ffc602d4043414100000300010"
        + "00003003c6005de5100002625a000002625a010"

    private static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    func testRext444SpsParsesAsChromaFormatIdc3() {
        let nal = Self.bytes(fromHex: Self.rext444SpsHex)
        XCTAssertEqual(HevcSpsChroma.chromaFormatIdc(inSpsNal: nal), 3)
        // The same read through the Annex-B entry (start code + NAL).
        let annexB = [0, 0, 0, 1] + nal
        XCTAssertEqual(HevcSpsChroma.chromaFormatIdc(inAnnexB: annexB), 3)
    }

    func testCommittedCorpusIdrParsesAsChromaFormatIdc1() throws {
        // The frozen video corpus is the shipped 4:2:0 path — its IDR
        // carries in-band parameter sets, exactly what the session's
        // audit reads.
        let idrPath = ClientTestPaths.videoCorpus
            + "/frame-000-idr.annexb"
        let annexB = [UInt8](try Data(
            contentsOf: URL(fileURLWithPath: idrPath)))
        XCTAssertEqual(HevcSpsChroma.chromaFormatIdc(inAnnexB: annexB), 1)
    }

    func testHostileSpsBytesAnswerNilNeverTrap() {
        // No SPS at all.
        XCTAssertNil(HevcSpsChroma.chromaFormatIdc(inAnnexB: [0, 0, 1, 0x26, 0x01, 0xAB]))
        // Truncations of the real SPS at every length: the walk runs
        // out of bits and says nothing, or — once the prefix through
        // chroma_format_idc survives — answers 3. Never a trap, never
        // a wrong value.
        let nal = Self.bytes(fromHex: Self.rext444SpsHex)
        for length in 0..<nal.count {
            let idc = HevcSpsChroma.chromaFormatIdc(
                inSpsNal: Array(nal.prefix(length)))
            XCTAssertTrue(idc == nil || idc == 3,
                          "truncation at \(length) answered \(idc.map(String.init) ?? "nil")")
        }
        // Garbage of SPS shape.
        XCTAssertNil(HevcSpsChroma.chromaFormatIdc(
            inSpsNal: [0x42, 0x01] + [UInt8](repeating: 0, count: 4)))
    }

    // MARK: - 5. The stream audit's discipline

    func testAuditConfirmsOnceAndDoctorsOnMismatchEdges() {
        var audit = ChromaStreamAudit()
        XCTAssertNil(audit.observedDescription)

        // First sighting, matching the agreed Best singleton: one
        // confirmation line, then silence on repeats.
        let confirm = audit.observe(
            chromaFormatIdc: 3,
            agreedChromaModes: [CapabilityChroma.yuv444])
        XCTAssertEqual(confirm,
                       "stream chroma 4:4:4 — matches the negotiated posture")
        XCTAssertNil(audit.observe(
            chromaFormatIdc: 3,
            agreedChromaModes: [CapabilityChroma.yuv444]))
        XCTAssertEqual(audit.observedDescription, "4:4:4")

        // A mid-session flip to 4:2:0 is an EDGE: the doctor line
        // fires once, then silence on repeats of the same wrongness.
        let doctor = audit.observe(
            chromaFormatIdc: 1,
            agreedChromaModes: [CapabilityChroma.yuv444])
        XCTAssertEqual(doctor,
                       "DOCTOR: stream chroma 4:2:0 but the negotiated "
                       + "posture is 4:4:4 — the host is not serving "
                       + "what it agreed")
        XCTAssertNil(audit.observe(
            chromaFormatIdc: 1,
            agreedChromaModes: [CapabilityChroma.yuv444]))
        XCTAssertEqual(audit.observedDescription, "4:2:0")
    }

    func testAuditWithoutAnAgreedSingletonReportsWithoutJudging() {
        var audit = ChromaStreamAudit()
        // A never-declaring peer (the grandfathered posture): the
        // sighting is reported, nothing is judged.
        XCTAssertEqual(audit.observe(
            chromaFormatIdc: 1, agreedChromaModes: nil),
            "stream chroma 4:2:0 (no agreed singleton)")
        XCTAssertNil(audit.observe(
            chromaFormatIdc: 1, agreedChromaModes: nil))
    }
}
