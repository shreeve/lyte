import AVFoundation
import LyteWire
import XCTest
@testable import LyteTransport

// THE GATE (HS-31 fix 3 — squeeze review §1): the render callback's
// ring underrun used to hard zero-pad, and every boundary was an
// audible crack (worst live leg: 1.58 s of zero-fill). Pinned here by
// driving the REAL render path — AudioPcmRing.render into hand-built
// deinterleaved buffers, the exact shape AVAudioSourceNode hands it:
//
//   • entering starvation: the pad DECAYS the boundary sample to true
//     zero over ~2 ms — no adjacent-sample jump anywhere, wherever
//     inside a callback the shortfall lands;
//   • the tail reaches exact silence (zeros, no DC) once the decay
//     window passes, however long the drought;
//   • recovery CROSSFADES from the tail's current value back into the
//     real samples — including the nasty case where recovery lands
//     mid-decay, under 2 ms after the cut;
//   • steady state is BYTE-IDENTICAL to the ring content — the
//     declick adds nothing until a boundary actually happens — and
//     the underrun/framesRendered books are unchanged.

final class AudioDeclickGateTests: XCTestCase {

    /// A hard cut of a loud low-frequency tone jumps ~0.9 between
    /// adjacent samples; the tone's own slope is ~0.028 and the 2 ms
    /// declick ramps add ≤ ~0.03 on top. 0.1 cleanly separates the
    /// two regimes.
    private static let clickThreshold: Float = 0.1
    private static let fade = AudioPcmRing.declickFrames

    /// Interleaved stereo sine: 240 Hz (period 200), amplitude 0.9 —
    /// loud and slow, so a hard cut is unmissable and the natural
    /// slope is small.
    private func sine(_ range: Range<Int>) -> [Float] {
        var pcm: [Float] = []
        pcm.reserveCapacity(range.count * AudioWire.channels)
        for n in range {
            let s = Float(0.9 * sin(2 * Double.pi * Double(n) / 200))
            for _ in 0..<AudioWire.channels { pcm.append(s) }
        }
        return pcm
    }

    /// Renders one callback of `wanted` frames through the production
    /// path and returns channel 0's output.
    private func render(_ ring: AudioPcmRing, wanted: Int) -> [Float] {
        let abl = AudioBufferList.allocate(
            maximumBuffers: AudioWire.channels)
        var storage: [UnsafeMutablePointer<Float>] = []
        for channel in 0..<AudioWire.channels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: wanted)
            p.initialize(repeating: .nan, count: wanted)
            abl[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(wanted * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(p))
            storage.append(p)
        }
        defer {
            for p in storage { p.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        ring.render(into: abl, wanted: wanted)
        return (0..<wanted).map { storage[0][$0] }
    }

    private func maxAdjacentDelta(_ samples: [Float]) -> Float {
        var worst: Float = 0
        for i in 1..<samples.count {
            worst = max(worst, abs(samples[i] - samples[i - 1]))
        }
        return worst
    }

    // MARK: Leg 1 — the cut is faded, the drought is exact silence

    func testUnderrunBoundaryFadesInsteadOfHardCutting() {
        let ring = AudioPcmRing()
        // 1,050 frames of tone: the ring dries 26 frames into the 9th
        // 128-frame callback, at a near-peak sample (~0.9) — the exact
        // shape that used to crack.
        ring.write(sine(0..<1_050))

        var out: [Float] = []
        for _ in 0..<12 { out += render(ring, wanted: 128) }
        XCTAssertEqual(out.count, 12 * 128)

        // No click anywhere: real → decay tail → silence, continuous.
        let worst = maxAdjacentDelta(out)
        XCTAssertLessThan(worst, Self.clickThreshold,
            "adjacent-sample jump \(worst) across the underrun "
            + "boundary — the hard cut is back")

        // The tail hits TRUE zero once the decay window passes, and
        // the rest of the drought is exact silence, not DC.
        for i in (1_050 + Self.fade)..<out.count {
            XCTAssertEqual(out[i], 0, "pad frame \(i) leaked signal")
        }

        // The books are untouched by the declick: every missing frame
        // still counted (the write just happened, so the stream is
        // "flowing"), every real frame still tallied.
        XCTAssertEqual(ring.underrunFrames.load(ordering: .relaxed),
                       UInt64(12 * 128 - 1_050))
        XCTAssertEqual(ring.framesRendered.load(ordering: .relaxed),
                       UInt64(1_050))
    }

    // MARK: Leg 2 — recovery crossfades in, then passes through exact

    func testRecoveryFadesInThenPassesThroughByteExact() {
        let ring = AudioPcmRing()
        ring.write(sine(0..<1_050))
        var out: [Float] = []
        for _ in 0..<12 { out += render(ring, wanted: 128) }

        // The pump refills; the next callback must not slam from
        // silence to a loud tone.
        let resumed = sine(1_050..<2_050)
        ring.write(resumed)
        let first = render(ring, wanted: 128)
        out += first

        XCTAssertLessThan(abs(first[0]), 0.05,
            "recovery must ramp from the tail's level, not jump")
        let worst = maxAdjacentDelta(Array(out.suffix(256)))
        XCTAssertLessThan(worst, Self.clickThreshold)

        // Past the crossfade the path is EXACTLY the ring content —
        // the declick never colors steady-state audio.
        for frame in Self.fade..<128 {
            XCTAssertEqual(first[frame],
                           resumed[frame * AudioWire.channels],
                           "steady-state sample \(frame) was altered")
        }
    }

    // MARK: Leg 3 — recovery landing mid-decay (inside the 2 ms tail)

    func testRecoveryInsideTheDecayTailStaysContinuous() {
        let ring = AudioPcmRing()
        // 250 frames: the cut lands at a near-peak sample (~0.9), so
        // a recovery that ignored the tail's standing level (~0.8
        // after 10 decay frames) would slam by ~0.8 — unmissable.
        ring.write(sine(0..<250))
        let cut = render(ring, wanted: 260)
        ring.write(sine(250..<650))
        let resumed = render(ring, wanted: 128)

        let worst = maxAdjacentDelta(cut + resumed)
        XCTAssertLessThan(worst, Self.clickThreshold,
            "recovery inside the decay tail must crossfade from the "
            + "tail's current value, not restart at zero")
    }

    // MARK: Leg 4 — steady state is byte-identical (no standing color)

    func testSteadyStateIsByteIdenticalToRingContent() {
        let ring = AudioPcmRing()
        let pcm = sine(0..<512)
        ring.write(pcm)
        let out = render(ring, wanted: 256) + render(ring, wanted: 256)
        for frame in 0..<512 {
            XCTAssertEqual(out[frame], pcm[frame * AudioWire.channels],
                           "steady-state sample \(frame) was altered")
        }
        XCTAssertEqual(ring.underrunFrames.load(ordering: .relaxed), 0)
    }
}
