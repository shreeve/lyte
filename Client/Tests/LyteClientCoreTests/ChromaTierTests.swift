import Foundation
import LyteClientCore
import LyteTestKit
import LyteWire
import XCTest

// The three-tier Chroma control's mechanics:
//
//   1. DECLARATION-AS-CHOICE: each tier declares exactly ONE chroma
//      mode (Good → [yuv420], Best → [yuv444]); the agreed
//      intersection against a 4:4:4-capable host ([420, 444]) is the
//      singleton, and the singleton IS the choice. Better is dormant —
//      no yuv422 wire id exists — so it declares nothing and cannot be
//      selected.
//   2. THE FALLBACK VERDICT: a non-Good declaration meeting a host
//      without the tier draws the typed `noCommonChromaMode`; the
//      policy's verdict is re-dial at Good (banner alongside), and
//      ONLY that failure on ONLY a non-Good tier — a codec mismatch
//      is not a chroma problem and Good has nowhere lower to go.
//   3. THE SPS READ: `chroma_format_idc` parsed off real encoder
//      output — the committed 4:2:0 corpus IDR and a frozen Rext 4:4:4
//      SPS (emulation-prevention bytes included).
//   4. THE STREAM AUDIT: one confirmation, a doctor line on each
//      mismatch edge.
//
// Per-host persistence of the tier is LyteTransport's
// (ChromaTierPersistenceTests).

final class ChromaTierTests: XCTestCase {

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

    // MARK: - 3. The SPS chroma read, on real encoder output

    /// A frozen Rext 4:4:4 SPS from the host's NVENC leaf (p4/ull/qres,
    /// rext yuv444, cq4) encoding 1920×1080. It carries
    /// emulation-prevention bytes (00 00 03 runs in the compat flags and
    /// VUI), so this vector exercises the RBSP strip too.
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
        let idrPath = RepositorySourceTree().repositoryRoot.path
            + "/Wire/Vectors/video-corpus-v1/frame-000-idr.annexb"
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

    // MARK: - 4. The stream audit's discipline

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
        XCTAssertNil(audit.observe(
            chromaFormatIdc: 3,
            agreedChromaModes: [CapabilityChroma.yuv420]),
            "agreement changes do not re-report an unchanged stream")
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

        // Returning to a previously observed idc is a fresh edge too;
        // the observation itself, not a parallel latch, re-arms it.
        XCTAssertEqual(audit.observe(
            chromaFormatIdc: 3,
            agreedChromaModes: [CapabilityChroma.yuv444]),
            "stream chroma 4:4:4 — matches the negotiated posture")
        XCTAssertNil(audit.observe(
            chromaFormatIdc: 3,
            agreedChromaModes: [CapabilityChroma.yuv444]))
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
