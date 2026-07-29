// corpus-gen / corpus-gate (H4 V-3): the §7 corpus harness's two CLI
// halves, composing what V-1/V-2 built rather than duplicating it:
//
//   corpus-gen   writes the deterministic in-repo corpus
//                (LyteTransport.CorpusFrames) as raw BGRX frames +
//                manifest.json (+ PNG previews) for the host encode
//                leg (pup's lyte-encode-check, the production C leaf);
//   corpus-gate  runs the pillar's acceptance math
//                (LyteTransport.CorpusGates — thresholds pinned in
//                code) over decode-probe's VideoToolbox BGRA readback:
//                text-region RGB PSNR, SSIM, range round-trip,
//                grating fidelity, ratchet convergence from the
//                encoder's size books, and the visual-golden diff.
//
// Orchestration (which encode leg, which chroma, pup transport) lives
// in Host/Scripts/corpus-harness.sh — these commands are the
// measurement seams it cannot get wrong.

import ArgumentParser
import Foundation
import LyteTransport

// MARK: - corpus-gen

struct CorpusGen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus-gen",
        abstract: "Write the §7 verification corpus (deterministic, versioned in code) as raw BGRX frames + manifest.")

    @Option(name: .long, help: "Output directory (created if missing)")
    var out: String

    @Option(name: .long, help: "Frame width")
    var width: Int = CorpusFrames.defaultWidth

    @Option(name: .long, help: "Frame height")
    var height: Int = CorpusFrames.defaultHeight

    @Flag(name: .long, help: "Also write PNG previews next to the raws")
    var png = false

    func run() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        let frames = CorpusFrames.generate(width: width, height: height)
        for frame in frames {
            let rawPath = out + "/" + frame.spec.file
            try Data(frame.bgrx).write(to: URL(fileURLWithPath: rawPath))
            print("corpus: \(frame.spec.name) → \(rawPath) (\(frame.bgrx.count) B)")
            if png {
                try CorpusPNG.write(bgrx: frame.bgrx, width: width,
                                    height: height,
                                    to: out + "/" + frame.spec.name + ".png")
            }
        }
        let manifest = CorpusFrames.manifest(width: width, height: height,
                                             frames: frames)
        try manifest.encoded().write(to: URL(fileURLWithPath: out + "/manifest.json"))
        print("corpus: manifest.json — version \(manifest.version), "
            + "\(manifest.frames.count) frames at \(width)x\(height)")
    }
}

// MARK: - corpus-gate

struct CorpusGate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus-gate",
        abstract: "Run the §7 gates (pinned thresholds) on a decoded BGRA dump against the corpus reference.")

    @Option(name: .long, help: "Corpus manifest.json (reference raws are its siblings)")
    var manifest: String

    @Option(name: .long, help: "Corpus frame name (e.g. text-100)")
    var frame: String

    @Option(name: .long, help: "Decoded BGRA dump from decode-probe --pixel-format bgra. 3+ frames = [cold IDR, active (the harness dumps frame 59 — 1 s into the walk), …, post-ratchet]; 2 frames = [active, post-ratchet]")
    var decoded: String

    @Option(name: .long, help: "Chroma label for the report (420|444)")
    var chroma: String

    @Option(name: .long, help: "work = gates enforce (non-zero exit on failure); baseline = same math, reference row, always exit 0")
    var mode: String = "work"

    @Option(name: .long, help: "Range posture: full = pillar byte-exact patch bars; limited601 = owner decision 2's shipped posture (+1 code allowance, byte-exact named-and-queued)")
    var rangePosture: String = "limited601"

    @Option(name: .long, help: "lyte-encode-check --sizes book for the ratchet-convergence gate")
    var sizes: String?

    @Option(name: .long, help: "Golden PNG to diff the post-ratchet frame against (non-empty diff = human looks, reported not failed)")
    var golden: String?

    @Option(name: .long, help: "Write the post-ratchet decoded frame as a golden PNG here")
    var writeGolden: String?

    func validate() throws {
        guard ["work", "baseline"].contains(mode) else {
            throw ValidationError("--mode wants work|baseline, got '\(mode)'")
        }
        guard ["420", "444"].contains(chroma) else {
            throw ValidationError("--chroma wants 420|444, got '\(chroma)'")
        }
        guard ["full", "limited601"].contains(rangePosture) else {
            throw ValidationError("--range-posture wants full|limited601, got '\(rangePosture)'")
        }
    }

    func run() throws {
        let manifestURL = URL(fileURLWithPath: manifest)
        let corpus = try CorpusManifest.decoded(from: Data(contentsOf: manifestURL))
        guard let spec = corpus.frames.first(where: { $0.name == frame }) else {
            throw ValidationError("frame '\(frame)' not in manifest "
                + "(\(corpus.frames.map(\.name).joined(separator: ", ")))")
        }
        let w = corpus.width
        let h = corpus.height
        let frameBytes = w * h * 4

        let refURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent(spec.file)
        let reference = [UInt8](try Data(contentsOf: refURL))
        guard reference.count == frameBytes else {
            throw ValidationError("\(spec.file): \(reference.count) B ≠ "
                + "one \(w)x\(h) BGRX frame (\(frameBytes) B)")
        }
        let dump = [UInt8](try Data(contentsOf: URL(fileURLWithPath: decoded)))
        guard dump.count >= frameBytes, dump.count % frameBytes == 0 else {
            throw ValidationError("\(decoded): \(dump.count) B is not whole "
                + "\(w)x\(h) BGRA frames (\(frameBytes) B each)")
        }
        let dumpFrames = dump.count / frameBytes
        func dumpFrame(_ i: Int) -> [UInt8] {
            Array(dump[i * frameBytes..<(i + 1) * frameBytes])
        }
        // Cold IDR (frame 0, VBV-constrained — reported, not gated),
        // active phase (1 s into the walk when the dump carries it),
        // post-ratchet (last).
        let coldIDR = dumpFrame(0)
        let active = dumpFrames >= 3 ? dumpFrame(1) : coldIDR
        let converged = dumpFrame(dumpFrames - 1)

        let enforcing = mode == "work"
        let tag = enforcing ? "" : " [ref]"
        var failures = 0
        func gate(_ name: String, _ detail: String, pass: Bool) {
            if enforcing && !pass { failures += 1 }
            print("GATE \(frame)/\(chroma) \(name): \(detail)  "
                + (pass ? "PASS" : "FAIL") + tag)
        }
        func fmt(_ v: Double) -> String {
            v.isInfinite ? "inf" : String(format: "%.2f", v)
        }

        // Full-frame per-channel PSNR, every phase — every row reports it.
        let fullActive = CorpusGates.rgbPSNR(
            reference: reference, decoded: active, width: w, height: h)
        let fullConverged = CorpusGates.rgbPSNR(
            reference: reference, decoded: converged, width: w, height: h)

        var resultFields = [
            "frame=\(frame)", "chroma=\(chroma)", "mode=\(mode)",
            "dump_frames=\(dumpFrames)",
            "full_active_db=\(fmt(fullActive.minChannel))",
            "full_conv_db=\(fmt(fullConverged.minChannel))",
        ]
        if dumpFrames >= 3 {
            let idr = CorpusGates.rgbPSNR(
                reference: reference, decoded: coldIDR, width: w, height: h)
            print("info \(frame)/\(chroma) cold-idr: full-frame min-ch "
                + "\(fmt(idr.minChannel)) dB (VBV-constrained opening IDR — "
                + "reported, the ratchet's job to heal)")
            resultFields.append("idr_db=\(fmt(idr.minChannel))")
        }

        // (a) Text: region-scoped per-channel-min PSNR, active + converged.
        if spec.kind == .text {
            let textActive = CorpusGates.rgbPSNR(
                reference: reference, decoded: active, width: w, height: h,
                regions: spec.textRegions)
            let textConverged = CorpusGates.rgbPSNR(
                reference: reference, decoded: converged, width: w, height: h,
                regions: spec.textRegions)
            gate("text-psnr-active",
                 "min-ch \(fmt(textActive.minChannel)) dB "
                     + "(r \(fmt(textActive.r)) g \(fmt(textActive.g)) "
                     + "b \(fmt(textActive.b)))"
                     + (dumpFrames >= 3 ? " @1 s into the walk" : "")
                     + " [bar ≥\(Int(CorpusGates.textActiveMinDB))]",
                 pass: textActive.minChannel >= CorpusGates.textActiveMinDB)
            gate("text-psnr-converged",
                 "min-ch \(fmt(textConverged.minChannel)) dB "
                     + "(r \(fmt(textConverged.r)) g \(fmt(textConverged.g)) "
                     + "b \(fmt(textConverged.b))) [bar ≥\(Int(CorpusGates.textConvergedMinDB))]",
                 pass: textConverged.minChannel >= CorpusGates.textConvergedMinDB)
            resultFields.append("text_active_db=\(fmt(textActive.minChannel))")
            resultFields.append("text_conv_db=\(fmt(textConverged.minChannel))")
            // Diagnostics: the white-on-black block survives 4:2:0 in
            // luma; the saturated syntax block is what chroma
            // subsampling kills — split them so the story is visible.
            if spec.textRegions.count == 2 {
                for (label, region) in [("white", spec.textRegions[0]),
                                        ("syntax", spec.textRegions[1])] {
                    let p = CorpusGates.rgbPSNR(
                        reference: reference, decoded: converged,
                        width: w, height: h, regions: [region])
                    print("info \(frame)/\(chroma) text-\(label)-converged: "
                        + "min-ch \(fmt(p.minChannel)) dB (r \(fmt(p.r)) "
                        + "g \(fmt(p.g)) b \(fmt(p.b)))")
                    resultFields.append("text_\(label)_db=\(fmt(p.minChannel))")
                }
            }
        }

        // (a)–(c): full-frame SSIM post-ratchet.
        if [.text, .gratings, .gradients].contains(spec.kind) {
            let ssim = CorpusGates.ssim(reference: reference, decoded: converged,
                                        width: w, height: h)
            gate("ssim-converged",
                 String(format: "%.5f [bar ≥%.3f]", ssim, CorpusGates.ssimConvergedMin),
                 pass: ssim >= CorpusGates.ssimConvergedMin)
            resultFields.append(String(format: "ssim=%.5f", ssim))
        }

        // (b) Gratings: per-channel error ≤ ±2 codes, post-ratchet.
        if !spec.gratings.isEmpty {
            var worst = 0
            for grating in spec.gratings {
                let err = CorpusGates.gratingError(
                    reference: reference, decoded: converged, width: w,
                    height: h, rect: grating.rect)
                worst = max(worst, err.maxChannel)
                gate("grating-\(grating.name)",
                     "max |err| r \(err.maxR) g \(err.maxG) b \(err.maxB) codes, "
                         + "\(err.offendersBeyondGate) px beyond "
                         + "[bar ≤±\(CorpusGates.gratingMaxCodes)]",
                     pass: err.maxChannel <= CorpusGates.gratingMaxCodes)
            }
            resultFields.append("grating_max=\(worst)")
        }

        // (d) Patches: the range round-trip, post-ratchet. The bar is
        // the pillar's byte-exact one under --range-posture full; the
        // shipped limited601 posture (owner decision 2) allows the
        // quantization round trip's one code and queues exactness.
        if !spec.patches.isEmpty {
            let allowance = rangePosture == "limited601"
                ? CorpusGates.limited601PatchAllowance : 0
            var worst = 0
            for patch in spec.patches {
                let bar = patch.tolerance + allowance
                let err = CorpusGates.patchError(decoded: converged, width: w,
                                                 height: h, patch: patch,
                                                 tolerance: bar)
                let detail = "\(patch.name) max |err| r \(err.maxR) g \(err.maxG) "
                    + "b \(err.maxB) codes [bar ≤\(bar)"
                    + (allowance > 0 ? " = \(patch.tolerance)+\(allowance) limited601" : "")
                    + "]"
                if patch.gated {
                    worst = max(worst, err.maxChannel)
                    gate("patch-\(patch.name)", detail,
                         pass: err.maxChannel <= bar)
                } else {
                    print("info \(frame)/\(chroma) patch-\(patch.name): \(detail) (ungated)")
                }
            }
            resultFields.append("patch_max=\(worst)")
            if allowance > 0 {
                print("info \(frame)/\(chroma) range-posture: limited601 — "
                    + "byte-exact round-trip NAMED-AND-QUEUED per owner decision 2")
            }
        }

        // Ratchet convergence from the encoder's size books, plus the
        // shape numbers V-4 compares recipes on (IDR mass, keepalive).
        if let sizes {
            let book = CorpusGates.parseSizeBook(
                try String(contentsOfFile: sizes, encoding: .utf8))
            let converge = CorpusGates.convergenceFrame(sizes: book)
            gate("ratchet-convergence",
                 "\(converge.map { "plateau from frame \($0)" } ?? "NOT CONVERGED") "
                     + "of \(book.count) [bar ≤\(CorpusGates.convergenceMaxFrames) fr = 3 s]",
                 pass: converge.map { $0 <= CorpusGates.convergenceMaxFrames } ?? false)
            resultFields.append("converge_frame=\(converge.map(String.init) ?? "never")")
            if let first = book.first, let last = book.last {
                resultFields.append("idr_b=\(first.bytes)")
                resultFields.append("keepalive_b=\(last.bytes)")
            }
        }

        // Visual goldens: write and/or diff (diff reports, never fails —
        // a non-empty diff is the "human looks" trigger).
        if let writeGolden {
            try CorpusPNG.write(bgrx: converged, width: w, height: h, to: writeGolden)
            print("golden \(frame)/\(chroma): wrote \(writeGolden)")
        }
        if let golden {
            let (goldenPixels, _, _) = try CorpusPNG.read(
                from: golden, expectedWidth: w, expectedHeight: h)
            guard let diff = CorpusGates.goldenDiff(candidate: converged,
                                                    golden: goldenPixels) else {
                throw ValidationError("golden \(golden): size mismatch against dump")
            }
            let verdict = diff.isEmpty
                ? "clean" : "DIRTY max \(diff.maxAbs) codes / \(diff.differingPixels) px — human looks"
            print("golden \(frame)/\(chroma): \(verdict)")
            resultFields.append("golden=\(diff.isEmpty ? "clean" : "dirty")")
        }

        resultFields.append("verdict=\(enforcing ? (failures == 0 ? "PASS" : "FAIL") : "REF")")
        print("RESULT " + resultFields.joined(separator: " "))
        if enforcing && failures > 0 {
            throw ExitCode(1)
        }
    }
}
