import XCTest
@testable import HostCore

// Deterministic pacer tests on a simulated monotonic clock. All times are
// nanoseconds; the sim advances to exactly the pacer's `nextWake` or the
// next scheduled arrival, whichever is sooner — the sans-IO event loop the
// real host will run, minus the syscalls.
//
// THE GATE (build plan HS-6 row): at the test rate no emitted batch may
// exceed 1 ms of wire time; a forced IDR that conforms to frameByteCeiling
// drains within min(2 × frameInterval, 25 ms); audio never waits more than
// one quantum; strict class ordering holds.
//
// frameByteCeiling derivation for the test rate (20 Mbps, 60 fps):
//   drain budget  B = min(2 × 16.67 ms, 25 ms) = 25 ms
//   gross bytes     = rate × B / 8            = 20e6 × 0.025 / 8 = 62,500 B
//   higher-class traffic inside the window (paid first, strict priority):
//     audio    6 × 320 B (5 ms cadence)       =  1,920 B
//     control  3 × 64 B (10 ms cadence)       =    192 B
//   frameByteCeiling ≈ 62,500 − 1,920 − 192   = 60,388 → 60,000 B (margin)
// The gate IDR is 52 shards × 1,152 B = 59,904 B ≤ ceiling. The 90 KB
// (92,160 B) burst the plan also throws at the pacer is deliberately
// NON-conforming at 20 Mbps (it needs ≥ 29.5 Mbps to meet 25 ms) — it
// proves the batch bound and audio protection hold under abuse, and its
// measured drain matches rate math exactly; keeping frames under the
// ceiling is HS-16's upstream job, which is the point of the ruling.

private let ms: UInt64 = 1_000_000

private struct Arrival {
    let at: UInt64
    let cls: PacerClass
    let bytes: Int
    let frameID: UInt32?
    let urgent: Bool
}

private struct SimBatchCheck {
    /// Classes still queued immediately after the batch was emitted —
    /// used to prove no priority inversion ever occurred.
    let batch: PacerBatch
    let leftoverClasses: Set<PacerClass>
}

/// Runs the pacer against a sorted arrival schedule until everything
/// drains (or `deadline`), waking at exact `nextWake`/arrival instants.
private func drive(_ pacer: Pacer, arrivals: [Arrival],
                   deadline: UInt64) -> [SimBatchCheck] {
    let sorted = arrivals.sorted { $0.at < $1.at }
    var out: [SimBatchCheck] = []
    var now: UInt64 = sorted.first?.at ?? 0
    var i = 0
    while now <= deadline {
        while i < sorted.count, sorted[i].at <= now {
            let a = sorted[i]
            pacer.enqueue(a.cls, bytes: a.bytes, frameID: a.frameID,
                          urgent: a.urgent, now: a.at)
            i += 1
        }
        while let b = pacer.nextBatch(now: now) {
            var leftovers = Set<PacerClass>()
            for c in PacerClass.allCases where pacer.queuedCount(c) > 0 {
                leftovers.insert(c)
            }
            out.append(SimBatchCheck(batch: b, leftoverClasses: leftovers))
        }
        let nextArrival: UInt64? = i < sorted.count ? sorted[i].at : nil
        let wake = pacer.nextWake(now: now)
        switch (nextArrival, wake) {
        case (nil, nil):
            return out
        case let (a?, nil):
            now = max(now + 1, a)
        case let (nil, w?):
            now = max(now + 1, w)
        case let (a?, w?):
            now = max(now + 1, min(a, w))
        }
    }
    return out
}

/// 5 ms audio + 10 ms control + 60 fps video shards over [from, to).
private func steadyTraffic(from: UInt64, to: UInt64,
                           frameIDBase: UInt32) -> [Arrival] {
    var a: [Arrival] = []
    var t = from
    while t < to {
        a.append(Arrival(at: t, cls: .audio, bytes: 320, frameID: nil,
                         urgent: false))
        t += 5 * ms
    }
    t = from
    while t < to {
        a.append(Arrival(at: t, cls: .control, bytes: 64, frameID: nil,
                         urgent: false))
        t += 10 * ms
    }
    t = from
    var frame = frameIDBase
    while t < to {
        // A typical damage P-frame: 5 shards of the universal 1,152 B
        // datagram budget.
        for _ in 0..<5 {
            a.append(Arrival(at: t, cls: .freshVideo, bytes: 1152,
                             frameID: frame, urgent: false))
        }
        frame += 1
        t += 16_666_667 // 60 fps
    }
    return a
}

private func idrBurst(at: UInt64, shards: Int, frameID: UInt32) -> [Arrival] {
    (0..<shards).map { _ in
        Arrival(at: at, cls: .freshVideo, bytes: 1152, frameID: frameID,
                urgent: true)
    }
}

/// Emission-complete time of the last batch containing `frameID`,
/// including that batch's own wire time.
private func drainNS(_ checks: [SimBatchCheck], frameID: UInt32,
                     enqueuedAt: UInt64) -> UInt64 {
    var done: UInt64 = 0
    for c in checks where c.batch.tokens.contains(where: { $0.frameID == frameID }) {
        done = max(done, c.batch.emittedAt + c.batch.wireTimeNS)
    }
    return done - enqueuedAt
}

final class PacerTests: XCTestCase {

    // MARK: - THE GATE

    func testGateMixedTrafficAtTwentyMbps() {
        let rate = 20_000_000
        let pacer = Pacer(rateBitsPerSecond: rate, now: 0)

        let conformingIdrAt = 200 * ms
        let abuseIdrAt = 600 * ms
        var arrivals = steadyTraffic(from: 0, to: 1000 * ms, frameIDBase: 1)
        // Conforming forced IDR: 52 × 1,152 = 59,904 B ≤ 60,000 B ceiling.
        arrivals += idrBurst(at: conformingIdrAt, shards: 52, frameID: 9001)
        // Non-conforming 90 KB burst: 80 × 1,152 = 92,160 B.
        arrivals += idrBurst(at: abuseIdrAt, shards: 80, frameID: 9002)

        let checks = drive(pacer, arrivals: arrivals, deadline: 1100 * ms)

        // 1. No batch ever exceeds 1 ms of wire time — including under
        //    the 90 KB abuse burst.
        for c in checks {
            XCTAssertLessThanOrEqual(c.batch.wireTimeNS, pacer.quantumNS,
                "batch of \(c.batch.bytes) B exceeds the 1 ms quantum")
        }
        XCTAssertLessThanOrEqual(pacer.telemetry.maxBatchWireTimeNS,
                                 pacer.quantumNS)

        // 2. The conforming IDR drains within min(2 × 16.67, 25) = 25 ms.
        let conformingDrain = drainNS(checks, frameID: 9001,
                                      enqueuedAt: conformingIdrAt)
        XCTAssertLessThanOrEqual(conformingDrain, 25 * ms,
            "conforming IDR drained in \(Double(conformingDrain) / 1e6) ms")
        // Sanity: it cannot beat the wire — 59,904 B at 20 Mbps is
        // ≥ 23.96 ms minus the one-quantum bucket head start.
        XCTAssertGreaterThan(conformingDrain, 20 * ms)

        // 3. The 90 KB burst drains at exactly rate math (~37 ms) — the
        //    pacer never bursts faster to "help", and the overshoot is
        //    why frameByteCeiling exists upstream.
        let abuseDrain = drainNS(checks, frameID: 9002, enqueuedAt: abuseIdrAt)
        XCTAssertGreaterThan(abuseDrain, 25 * ms)
        XCTAssertLessThan(abuseDrain, 40 * ms)

        // 4. Audio never waits more than one quantum (+ scheduling ε).
        let audioWait = pacer.telemetry[.audio].maxQueueDelayNS
        XCTAssertLessThanOrEqual(audioWait, pacer.quantumNS + pacer.quantumNS / 20,
            "audio waited \(Double(audioWait) / 1e6) ms")
        // Control is even stricter — highest class.
        let controlWait = pacer.telemetry[.control].maxQueueDelayNS
        XCTAssertLessThanOrEqual(controlWait, pacer.quantumNS + pacer.quantumNS / 20)

        // 5. No priority inversion anywhere in the run: a batch may not
        //    contain a class lower than one still queued when it left.
        for c in checks {
            guard let highestLeftover = c.leftoverClasses.min() else { continue }
            for t in c.batch.tokens {
                XCTAssertLessThanOrEqual(t.priorityClass, highestLeftover,
                    "class \(t.priorityClass.name) sent while "
                    + "\(highestLeftover.name) was queued")
            }
        }

        // Evidence for the record (visible with `swift test -v`).
        print("HS-6 gate @20 Mbps: max batch wire time "
            + "\(Double(pacer.telemetry.maxBatchWireTimeNS) / 1e6) ms; "
            + "conforming-IDR (59,904 B) drain "
            + "\(Double(conformingDrain) / 1e6) ms (budget 25); 90 KB abuse "
            + "drain \(Double(abuseDrain) / 1e6) ms; max audio wait "
            + "\(Double(audioWait) / 1e6) ms; max control wait "
            + "\(Double(controlWait) / 1e6) ms")

        // 6. Everything offered was eventually sent (no starvation, no loss).
        XCTAssertTrue(pacer.isEmpty)
        for c in PacerClass.allCases {
            XCTAssertEqual(pacer.telemetry[c].tokensSent,
                           pacer.telemetry[c].tokensEnqueued,
                           "\(c.name) lost tokens")
        }
    }

    // MARK: - Ordering

    func testControlPreemptsAudioPreemptsVideo() {
        let pacer = Pacer(rateBitsPerSecond: 20_000_000, now: 0)
        // Enqueue in reverse priority order at the same instant; the
        // first batch must still come out control, audio, video.
        pacer.enqueue(.freshVideo, bytes: 1152, now: 0)
        pacer.enqueue(.audio, bytes: 320, now: 0)
        pacer.enqueue(.control, bytes: 64, now: 0)

        let batch = pacer.nextBatch(now: 0)!
        XCTAssertEqual(batch.tokens.map(\.priorityClass),
                       [.control, .audio, .freshVideo])
    }

    func testUrgentIdrJumpsQueuedVideoButNotAudio() {
        // 50 Mbps → 6,250 B quantum, so the whole scenario fits one batch.
        let pacer = Pacer(rateBitsPerSecond: 50_000_000, now: 0)
        // A stale frame's shards are already queued...
        for _ in 0..<4 {
            pacer.enqueue(.freshVideo, bytes: 1152, frameID: 7, now: 0)
        }
        // ...then audio and an urgent IDR arrive.
        pacer.enqueue(.audio, bytes: 320, now: 0)
        pacer.enqueue(.freshVideo, bytes: 1152, frameID: 8, urgent: true, now: 0)

        let batch = pacer.nextBatch(now: 0)!
        // Audio first (higher class), then the urgent IDR shard, then the
        // stale frame resumes.
        XCTAssertEqual(batch.tokens[0].priorityClass, .audio)
        XCTAssertEqual(batch.tokens[1].frameID, 8)
        XCTAssertEqual(batch.tokens[2].frameID, 7)
    }

    func testFifoWithinClass() {
        let pacer = Pacer(rateBitsPerSecond: 50_000_000, now: 0)
        for tag in 0..<5 {
            pacer.enqueue(.telemetry, bytes: 100, tag: UInt64(tag), now: 0)
        }
        let batch = pacer.nextBatch(now: 0)!
        XCTAssertEqual(batch.tokens.map(\.tag), [0, 1, 2, 3, 4])
    }

    // MARK: - Token bucket

    func testBucketStartsFullAndCapsAtOneQuantum() {
        // 20 Mbps → 2,500 B per 1 ms quantum. After long quiet the bucket
        // holds exactly one quantum, no more (aperiodicity is free, bursts
        // are still bounded).
        let pacer = Pacer(rateBitsPerSecond: 20_000_000, now: 0)
        for _ in 0..<10 { pacer.enqueue(.freshVideo, bytes: 500, now: 1_000 * ms) }
        let batch = pacer.nextBatch(now: 1_000 * ms)!
        XCTAssertEqual(batch.bytes, 2500)
        XCTAssertEqual(batch.wireTimeNS, 1 * ms)
        // Bucket is now empty; the next 500 B token needs 200 µs of credit.
        XCTAssertNil(pacer.nextBatch(now: 1_000 * ms))
        XCTAssertEqual(pacer.nextWake(now: 1_000 * ms), 1_000 * ms + 200_000)
    }

    func testConservationOverEveryWindow() {
        // Cumulative bytes between any two emissions never beat
        // rate × Δt + one burst.
        let rate = 12_000_000
        let pacer = Pacer(rateBitsPerSecond: rate, now: 0)
        var arrivals = steadyTraffic(from: 0, to: 300 * ms, frameIDBase: 1)
        arrivals += idrBurst(at: 50 * ms, shards: 30, frameID: 500)
        let checks = drive(pacer, arrivals: arrivals, deadline: 400 * ms)

        let events = checks.map { ($0.batch.emittedAt, $0.batch.bytes) }
        var cumulative: [Int] = []
        var run = 0
        for e in events { run += e.1; cumulative.append(run) }
        let burst = Double(rate) / 8e9 * 1e6 // bytes per quantum
        for i in 0..<events.count {
            for j in (i + 1)..<events.count {
                let sent = Double(cumulative[j] - cumulative[i])
                let dt = Double(events[j].0 - events[i].0)
                let allowance = dt * Double(rate) / 8e9 + burst + 1
                XCTAssertLessThanOrEqual(sent, allowance,
                    "window [\(i),\(j)] sent \(sent) B > allowance \(allowance)")
            }
        }
    }

    // MARK: - Property tests (seeded random arrivals)

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    func testPropertiesUnderSeededRandomArrivals() {
        let rate = 12_000_000 // burst = 1,500 B per quantum
        let classes = PacerClass.allCases
        for seed: UInt64 in [1, 7, 42, 20260720, 0xDEADBEEF] {
            var rng = SplitMix64(state: seed)
            let pacer = Pacer(rateBitsPerSecond: rate, now: 0)

            // ~55% offered load over 400 ms so the lowest class must not
            // starve: capacity is 600,000 B, offer ≤ 330,000 B.
            var arrivals: [Arrival] = []
            var offered = 0
            while offered < 320_000 {
                let bytes = 1 + rng.below(1400)
                arrivals.append(Arrival(
                    at: UInt64(rng.below(400)) * ms + UInt64(rng.below(1_000_000)),
                    cls: classes[rng.below(classes.count)],
                    bytes: bytes,
                    frameID: UInt32(rng.below(100)),
                    urgent: rng.below(10) == 0))
                offered += bytes
            }

            let checks = drive(pacer, arrivals: arrivals, deadline: 2_000 * ms)

            // Priority inversion never occurs.
            for c in checks {
                guard let highestLeftover = c.leftoverClasses.min() else { continue }
                for t in c.batch.tokens {
                    XCTAssertLessThanOrEqual(t.priorityClass, highestLeftover,
                                             "seed \(seed): inversion")
                }
            }
            // Batch bound holds.
            XCTAssertLessThanOrEqual(pacer.telemetry.maxBatchWireTimeNS,
                                     pacer.quantumNS, "seed \(seed)")
            // Conservation holds end-to-end.
            let last = checks.last!.batch
            let elapsed = Double(last.emittedAt)
            let allowance = elapsed * Double(rate) / 8e9
                + Double(rate) / 8e9 * 1e6 + 1
            XCTAssertLessThanOrEqual(Double(pacer.telemetry.bytesSent),
                                     allowance, "seed \(seed)")
            // No starvation: with capacity to spare, everything drains.
            XCTAssertTrue(pacer.isEmpty, "seed \(seed): tokens stranded")
            for c in classes {
                XCTAssertEqual(pacer.telemetry[c].tokensSent,
                               pacer.telemetry[c].tokensEnqueued,
                               "seed \(seed): \(c.name) starved")
            }
        }
    }

    // MARK: - Rate change mid-stream (the HS-16 seam)

    func testHalvingRateMidIdrStretchesDrain() {
        // 16 Mbps → 2,000 B/ms. A 40,000 B IDR alone: bucket head start
        // 2,000 B + 19 ms of wire + the last batch's 0.5 ms serialization
        // = 19.5 ms drain. Halve the rate at 10 ms: 22,000 B have left
        // (burst + 10 ms × 2,000); the remaining 18,000 B drain at
        // 1,000 B/ms with 1 ms final serialization → 29 ms total.
        let makeArrivals: () -> [Arrival] = {
            (0..<40).map { _ in
                Arrival(at: 0, cls: .freshVideo, bytes: 1000, frameID: 1,
                        urgent: true)
            }
        }

        // Baseline: constant 16 Mbps.
        let base = Pacer(rateBitsPerSecond: 16_000_000, now: 0)
        let baseChecks = drive(base, arrivals: makeArrivals(),
                               deadline: 100 * ms)
        let baseDrain = drainNS(baseChecks, frameID: 1, enqueuedAt: 0)
        XCTAssertEqual(Double(baseDrain) / 1e6, 19.5, accuracy: 0.6)

        // Halved at 10 ms: drive manually so the rate change lands
        // mid-drain.
        let pacer = Pacer(rateBitsPerSecond: 16_000_000, now: 0)
        for _ in 0..<40 {
            pacer.enqueue(.freshVideo, bytes: 1000, frameID: 1, urgent: true,
                          now: 0)
        }
        var now: UInt64 = 0
        var rateChanged = false
        var drainedAt: UInt64 = 0
        while now < 100 * ms {
            if !rateChanged, now >= 10 * ms {
                pacer.setRate(bitsPerSecond: 8_000_000, now: now)
                rateChanged = true
            }
            while let b = pacer.nextBatch(now: now) {
                // After the change, batches respect the NEW quantum size
                // (1,000 B) — the ≤1 ms bound holds at the rate in force.
                if rateChanged {
                    XCTAssertLessThanOrEqual(b.bytes, 1000)
                }
                XCTAssertLessThanOrEqual(b.wireTimeNS, pacer.quantumNS)
                if pacer.isEmpty { drainedAt = b.emittedAt + b.wireTimeNS }
            }
            guard let wake = pacer.nextWake(now: now) else { break }
            now = max(now + 1, min(wake, rateChanged ? wake : 10 * ms))
        }
        XCTAssertEqual(Double(drainedAt) / 1e6, 29.0, accuracy: 0.6)
        XCTAssertGreaterThan(drainedAt, baseDrain + 8 * ms)
    }

    // MARK: - Wake computation

    func testNextWakeIsExactAndMonotonic() {
        let pacer = Pacer(rateBitsPerSecond: 20_000_000, now: 0)
        XCTAssertNil(pacer.nextWake(now: 0), "empty pacer never wakes")
        // Drain the full bucket, then a 2,500 B backlog needs exactly one
        // quantum of credit.
        pacer.enqueue(.freshVideo, bytes: 2500, now: 0)
        XCTAssertNotNil(pacer.nextBatch(now: 0))
        pacer.enqueue(.freshVideo, bytes: 2500, now: 0)
        XCTAssertEqual(pacer.nextWake(now: 0), 1 * ms)
        XCTAssertNil(pacer.nextBatch(now: 500_000), "half a quantum is not enough")
        XCTAssertNotNil(pacer.nextBatch(now: 1 * ms))
    }
}
