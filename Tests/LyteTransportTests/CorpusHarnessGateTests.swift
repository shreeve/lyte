import XCTest
import LyteTransport

// THE V-3 GATES (H4 plan: the §7 corpus harness). Three contracts,
// pinned in code:
//
//   1. the corpus is FROZEN — every frame's bytes hash-pinned, like a
//      wire vector: a changed pin is a measurement-contract change to
//      discuss, never drift to absorb (regenerating shifts every
//      banked baseline number);
//   2. the gate thresholds are the image-quality pillar's §7 numbers,
//      pinned here so no harness edit can quietly relax them;
//   3. the gate math detects what it claims to detect — PSNR/SSIM
//      degrade under damage, the grating gate trips at ±3 codes and
//      holds at ±2, the patch gate is byte-exact through the PNG
//      golden round trip, the convergence detector reads the
//      encoder's size books correctly.

final class CorpusHarnessGateTests: XCTestCase {

    /// One shared generation — the corpus is a pure function, and
    /// generating 7 frames of 2048×1280 once per suite keeps the gate
    /// honest without paying pixel math per test.
    private static let corpus = CorpusFrames.generate()
    private static let manifest = CorpusFrames.manifest(frames: corpus)

    private var corpus: [CorpusFrames.GeneratedFrame] { Self.corpus }
    private var manifest: CorpusManifest { Self.manifest }
    private var w: Int { manifest.width }
    private var h: Int { manifest.height }

    /// FNV-1a 64 — dependency-free fingerprint for the freeze pins.
    private func fnv1a(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - 1. The freeze

    func testCorpusIsFrozen() {
        // Names, order, and geometry are part of the contract.
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.width, 2048)
        XCTAssertEqual(manifest.height, 1280)
        XCTAssertEqual(
            corpus.map(\.spec.name),
            ["text-100", "text-125", "text-200", "gratings", "gradients",
             "patches", "photo"])

        // The pins. Regenerate ONLY with a corpus-version discussion —
        // every banked baseline number is measured against these bytes.
        let pins: [String: String] = [
            "text-100": "a5d9bab5dc01f4b4",
            "text-125": "51a28625f35de69c",
            "text-200": "709625ce53d0c5fd",
            "gratings": "71705183e0633825",
            "gradients": "a42ec153900b12a5",
            "patches": "706c6c750ac0ed25",
            "photo": "58cc878bff7e7776",
        ]
        for frame in corpus {
            XCTAssertEqual(fnv1a(frame.bgrx), pins[frame.spec.name],
                           "\(frame.spec.name): corpus bytes drifted from the pin")
        }
    }

    // MARK: - 2. The thresholds (§7 verbatim)

    func testGateThresholdsArePinned() {
        XCTAssertEqual(CorpusGates.textActiveMinDB, 40.0)
        XCTAssertEqual(CorpusGates.textConvergedMinDB, 50.0)
        XCTAssertEqual(CorpusGates.ssimConvergedMin, 0.995)
        XCTAssertEqual(CorpusGates.gratingMaxCodes, 2)
        XCTAssertEqual(CorpusGates.convergenceMaxFrames, 180)
        // Owner decision 2's shipped posture: one code for the
        // 601-limited round trip, byte-exact named-and-queued.
        XCTAssertEqual(CorpusGates.limited601PatchAllowance, 1)
    }

    // MARK: - Manifest ↔ pixels coherence

    func testManifestRegionsMatchAuthoredPixels() {
        func pixel(_ frame: CorpusFrames.GeneratedFrame, _ x: Int, _ y: Int)
            -> (r: Int, g: Int, b: Int) {
            let i = (y * w + x) * 4
            return (Int(frame.bgrx[i + 2]), Int(frame.bgrx[i + 1]), Int(frame.bgrx[i]))
        }

        for frame in corpus {
            let spec = frame.spec
            for rect in spec.textRegions + spec.gratings.map(\.rect)
                + spec.patches.map(\.rect) {
                XCTAssertTrue(rect.x >= 0 && rect.y >= 0
                    && rect.x + rect.width <= w && rect.y + rect.height <= h,
                    "\(spec.name): region out of bounds")
                XCTAssertTrue(rect.width > 64 && rect.height > 64,
                              "\(spec.name): degenerate region")
            }
            // Patch centers carry exactly the authored color.
            for patch in spec.patches {
                let c = pixel(frame, patch.rect.x + patch.rect.width / 2,
                              patch.rect.y + patch.rect.height / 2)
                XCTAssertEqual(c.r, patch.red, "\(patch.name)")
                XCTAssertEqual(c.g, patch.green, "\(patch.name)")
                XCTAssertEqual(c.b, patch.blue, "\(patch.name)")
            }
            // Text regions hold real single-pixel ink: background AND
            // stroke pixels, and the syntax block is saturated.
            if spec.kind == .text {
                XCTAssertEqual(spec.textRegions.count, 2)
                var colors = Set<UInt32>()
                let rect = spec.textRegions[1] // the syntax block
                for y in stride(from: rect.y, to: rect.y + rect.height, by: 3) {
                    for x in stride(from: rect.x, to: rect.x + rect.width, by: 3) {
                        let c = pixel(frame, x, y)
                        colors.insert(UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b))
                    }
                }
                XCTAssertTrue(colors.contains(0), "\(spec.name): no background")
                XCTAssertGreaterThanOrEqual(
                    colors.count, 5,
                    "\(spec.name): syntax block lost its saturated palette")
            }
            // Gratings alternate at single-pixel pitch (adjacent texels
            // differ) — the property 4:2:0 cannot survive.
            for grating in spec.gratings {
                let x = grating.rect.x + grating.rect.width / 2
                let y = grating.rect.y + grating.rect.height / 2
                let a = pixel(frame, x, y)
                let bRight = pixel(frame, x + 1, y)
                let bDown = pixel(frame, x, y + 1)
                XCTAssertTrue(a != bRight || a != bDown,
                              "\(grating.name): not a 1-px structure")
            }
        }
    }

    // MARK: - 3. The gate math detects damage

    func testPSNRAndSSIMDetectDamage() {
        let frame = corpus.first { $0.spec.name == "text-100" }!
        let clean = frame.bgrx

        // Identical → infinite PSNR, SSIM 1.
        let perfect = CorpusGates.rgbPSNR(reference: clean, decoded: clean,
                                          width: w, height: h,
                                          regions: frame.spec.textRegions)
        XCTAssertTrue(perfect.minChannel.isInfinite)
        XCTAssertEqual(CorpusGates.ssim(reference: clean, decoded: clean,
                                        width: w, height: h), 1.0, accuracy: 1e-9)

        // Deterministic damage inside the text region → both metrics
        // move, and the per-channel min tracks the damaged channel.
        var damaged = clean
        let rect = frame.spec.textRegions[0]
        var rng: UInt64 = 0x5EED
        for _ in 0..<20_000 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let x = rect.x + Int((rng >> 33) % UInt64(rect.width))
            let y = rect.y + Int((rng >> 13) % UInt64(rect.height))
            let i = (y * w + x) * 4 + 2 // red channel only
            damaged[i] = damaged[i] &+ 40
        }
        let hurt = CorpusGates.rgbPSNR(reference: clean, decoded: damaged,
                                       width: w, height: h,
                                       regions: frame.spec.textRegions)
        XCTAssertLessThan(hurt.r, 60)
        XCTAssertTrue(hurt.g.isInfinite) // untouched channels stay perfect
        XCTAssertEqual(hurt.minChannel, hurt.r)
        XCTAssertLessThan(
            CorpusGates.ssim(reference: clean, decoded: damaged,
                             width: w, height: h), 1.0)
    }

    func testGratingGateTripsAtThreeCodes() {
        let frame = corpus.first { $0.spec.name == "gratings" }!
        let grating = frame.spec.gratings[0]
        let cx = grating.rect.x + grating.rect.width / 2
        let cy = grating.rect.y + grating.rect.height / 2

        // ±2 codes on an interior pixel: at the bar, not over it.
        var atBar = frame.bgrx
        atBar[(cy * w + cx) * 4 + 1] = atBar[(cy * w + cx) * 4 + 1] &+ 2
        let ok = CorpusGates.gratingError(reference: frame.bgrx, decoded: atBar,
                                          width: w, height: h, rect: grating.rect)
        XCTAssertEqual(ok.maxChannel, 2)
        XCTAssertEqual(ok.offendersBeyondGate, 0)

        // ±3 codes: over.
        var over = frame.bgrx
        over[(cy * w + cx) * 4 + 1] = over[(cy * w + cx) * 4 + 1] &+ 3
        let bad = CorpusGates.gratingError(reference: frame.bgrx, decoded: over,
                                           width: w, height: h, rect: grating.rect)
        XCTAssertEqual(bad.maxChannel, 3)
        XCTAssertEqual(bad.offendersBeyondGate, 1)

        // Damage inside the inset margin is the neighbor seam's
        // business, not the grating gate's.
        var edge = frame.bgrx
        edge[(grating.rect.y * w + grating.rect.x) * 4] &+= 50
        let seam = CorpusGates.gratingError(reference: frame.bgrx, decoded: edge,
                                            width: w, height: h, rect: grating.rect)
        XCTAssertEqual(seam.maxChannel, 0)
    }

    func testPatchGateIsByteExact() {
        let frame = corpus.first { $0.spec.name == "patches" }!
        let black = frame.spec.patches.first { $0.name == "black" }!
        XCTAssertEqual(black.tolerance, 0)
        XCTAssertTrue(black.gated)

        // Authored pixels → zero error.
        let clean = CorpusGates.patchError(decoded: frame.bgrx, width: w,
                                           height: h, patch: black)
        XCTAssertEqual(clean.maxChannel, 0)

        // One code of drift in the interior → the byte-exact gate sees it.
        var drifted = frame.bgrx
        let cx = black.rect.x + black.rect.width / 2
        let cy = black.rect.y + black.rect.height / 2
        drifted[(cy * w + cx) * 4] = 1
        let dirty = CorpusGates.patchError(decoded: drifted, width: w,
                                           height: h, patch: black)
        XCTAssertEqual(dirty.maxChannel, 1)
        XCTAssertEqual(dirty.offendersBeyondGate, 1)

        // Ringing at the patch EDGE (inside the inset) is not a range
        // failure.
        var ringing = frame.bgrx
        ringing[(black.rect.y * w + black.rect.x) * 4] = 200
        let edge = CorpusGates.patchError(decoded: ringing, width: w,
                                          height: h, patch: black)
        XCTAssertEqual(edge.maxChannel, 0)
    }

    func testConvergenceDetectorReadsTheBooks() {
        func book(_ entries: [(Int, Int)]) -> [CorpusGates.SizeBookEntry] {
            entries.map { CorpusGates.SizeBookEntry(bytes: $0.0, qp: $0.1) }
        }
        // QP walk then a 220-frame keepalive plateau from frame 20.
        var walk = (0..<20).map { (100_000 - $0 * 4_000, 30 - $0) }
        walk += Array(repeating: (208, 12), count: 220)
        XCTAssertEqual(CorpusGates.convergenceFrame(sizes: book(walk)), 20)

        // A stable tail shorter than 1 s is not convergence.
        var lateWalk = (0..<230).map { (100_000 - $0 * 100, 30) }
        lateWalk += Array(repeating: (208, 12), count: 10)
        XCTAssertNil(CorpusGates.convergenceFrame(sizes: book(lateWalk)))

        // A QP wiggle breaks byte-size-only stability.
        var qpWiggle = Array(repeating: (208, 12), count: 140)
        qpWiggle[60] = (208, 13)
        XCTAssertEqual(CorpusGates.convergenceFrame(sizes: book(qpWiggle)), 61)

        // Natural-content hover: keepalives wiggling within ±⅛ at
        // converged QP are the plateau (the photo frame's shape); a
        // 2× excursion is not.
        var hover = (0..<15).map { (50_000 - $0 * 3_000, 25 - $0) }
        hover += (0..<225).map { i in (925 + (i * 7) % 12, 12) }
        XCTAssertEqual(CorpusGates.convergenceFrame(sizes: book(hover)), 15)
        var burst = hover
        burst[100] = (2_500, 12)
        XCTAssertEqual(CorpusGates.convergenceFrame(sizes: book(burst)), 101)

        // The parser reads lyte-encode-check's "idx key bytes qp" rows.
        let parsed = CorpusGates.parseSizeBook("0 1 254331 24\n1 0 1500 18\n2 0 208 12\n")
        XCTAssertEqual(parsed.map(\.bytes), [254_331, 1_500, 208])
        XCTAssertEqual(parsed.map(\.qp), [24, 18, 12])
    }

    func testGoldenPNGRoundTripAndDiff() throws {
        let frame = corpus.first { $0.spec.name == "gratings" }!
        let path = NSTemporaryDirectory() + "corpus-gate-golden-test.png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try CorpusPNG.write(bgrx: frame.bgrx, width: w, height: h, to: path)
        let (readBack, rw, rh) = try CorpusPNG.read(from: path,
                                                    expectedWidth: w,
                                                    expectedHeight: h)
        XCTAssertEqual(rw, w)
        XCTAssertEqual(rh, h)

        // Byte-exact round trip on B/G/R — the golden diff of a frame
        // against its own golden is EMPTY, the whole premise of the
        // "human looks only when the diff is non-empty" doctrine.
        let clean = CorpusGates.goldenDiff(candidate: frame.bgrx, golden: readBack)
        XCTAssertNotNil(clean)
        XCTAssertTrue(clean!.isEmpty,
                      "PNG round trip not byte-exact: max \(clean!.maxAbs), "
                          + "\(clean!.differingPixels) px")

        // A perturbed candidate reports honestly.
        var dirty = frame.bgrx
        dirty[0] = dirty[0] &+ 7
        let diff = CorpusGates.goldenDiff(candidate: dirty, golden: readBack)!
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.maxAbs, 7)
        XCTAssertEqual(diff.differingPixels, 1)
    }
}
