import JavaScriptKit
import LyteClientBrowserCore
import LyteCore
import LyteWire

/// Publishes `globalThis.lyteBrowser`, the page's only door into the
/// sans-IO core; this file converts values and owns the single session.
/// A burst crosses as one `Uint8Array` each way, copied once into WASM
/// memory and sliced there: received datagrams as `u16 big-endian length +
/// u32 big-endian age µs + bytes` records, datagrams to send as `u16
/// length + bytes`. A step with nothing to act on returns `null`.
enum BrowserBridge {
    // The page's single-threaded pump owns this; JavaScriptKit calls are serial.
    nonisolated(unsafe) private static var session: BrowserControlSession?
    nonisolated(unsafe) private static var closures: [JSClosure] = []

    static func install() {
        var api: [String: JSValue] = [
            "conductorBeatMicroseconds":
                Double(VideoBeatConductor.Config().beatPeriodMicroseconds).jsValue,
            "audioRingCeilingFrames": Double(BrowserAudioPlayout.ringCeilingFrames).jsValue,
        ]
        func expose(_ name: String, _ body: @escaping ([JSValue]) -> JSValue) {
            let closure = JSClosure { body($0) }
            closures.append(closure)
            api[name] = closure.jsValue
        }

        expose("classifyAnnexBBytes") { args in
            guard let bytes = bytes(args, 0) else {
                return ["ok": false.jsValue, "detail": "not Uint8Array".jsValue].jsValue
            }
            return classifyFrameBytes(bytes)
        }

        // Session drive.
        expose("controlOpen") { args in
            controlOpen(hostStaticHex: string(args, 0) ?? "", pin: string(args, 1) ?? "")
        }
        expose("controlBegin") { args in
            withSession { session in
                do {
                    return stepToJS(try session.begin(nowMicros: micros(args, 0)))
                } catch {
                    return failureStep("begin: \(error)")
                }
            }
        }
        expose("controlIngestBatch") { args in
            withSession { session in
                // A malformed batch is a page bug, not session evidence.
                guard let packed = bytes(args, 0), let records = received(packed) else {
                    return .null
                }
                let now = micros(args, 1)
                let before = session.currentStatus
                var merged: BrowserControlSession.Step?
                for record in records {
                    let step = session.ingest(
                        datagram: packed[record.bytes],
                        arrivalMicros: now &- min(record.ageMicros, now),
                        nowMicros: now)
                    if merged == nil { merged = step } else { merged!.append(step) }
                }
                guard let merged else { return .null }
                return quietOrStep(merged, statusBefore: before)
            }
        }
        expose("controlTick") { args in
            withSession { session in
                let before = session.currentStatus
                return quietOrStep(session.tick(nowMicros: micros(args, 0)), statusBefore: before)
            }
        }
        expose("controlTeardown") { args in
            withSession { stepToJS($0.teardown(nowMicros: micros(args, 0))) }
        }
        expose("controlSendInput") { args in
            withSession { session in
                guard let body = inputBody(args) else { return .null }
                return stepToJS(session.sendInput(body: body, nowMicros: micros(args, 1)))
            }
        }
        expose("controlClipboardSet") { args in
            withSession { session in
                stepToJS(session.shareClipboard(
                    text: string(args, 0) ?? "", nowMicros: micros(args, 1)
                ))
            }
        }
        expose("controlFacts") { _ in facts() }

        // Media hand-off.
        expose("mediaTakeAnnexB") { args in
            guard let frame = uint32(args, 0),
                  let bytes = session?.takeAnnexB(frameNumber: frame)
            else { return .null }
            return JSTypedArray<UInt8>(bytes).jsValue
        }
        expose("mediaPopDue") { args in
            guard let frame = session?.popDueFrame(nowMicros: micros(args, 0)) else {
                return .null
            }
            return scheduledFrameToJS(frame)
        }
        expose("mediaNotePresented") { _ in
            session?.notePresented()
            return .undefined
        }
        expose("mediaTakeAbandoned") { _ in
            guard let frames = session?.takeAbandonedFrames(), !frames.isEmpty else {
                return .null
            }
            return frames.map { Double($0).jsValue }.jsValue
        }
        expose("mediaNoteDropped") { args in
            if let frame = uint32(args, 0) { session?.noteDropped(frameNumber: frame) }
            return .undefined
        }
        expose("mediaStats") { _ in
            let counters = session?.videoCounters ?? BrowserVideoPlayout.Counters()
            return [
                "assembled": Double(counters.framesAssembled).jsValue,
                "skippedLate": Double(counters.framesSkippedLate).jsValue,
            ].jsValue
        }
        expose("audioPopPacket") { _ in
            guard let packet = session?.popAudioPacket() else { return .null }
            return [
                "captureMicroseconds": Double(packet.captureMicroseconds).jsValue,
                "bytes": JSTypedArray<UInt8>(packet.bytes).jsValue,
            ].jsValue
        }
        expose("interactionStats") { _ in
            var stats: [String: JSValue] = [:]
            stats["inputsSent"] = Double(session?.inputsSent ?? 0).jsValue
            stats["inputEchoes"] = Double(session?.inputEchoes ?? 0).jsValue
            stats["clipboardSent"] = Double(session?.clipboardSent ?? 0).jsValue
            stats["clipboardReceived"] = Double(session?.clipboardReceived ?? 0).jsValue
            stats["audioAssembled"] = Double(session?.audioPacketsAssembled ?? 0).jsValue
            stats["audioDroppedStale"] = Double(session?.audioPacketsDroppedStale ?? 0).jsValue
            stats["lastClipboardText"] = session?.lastClipboardText.map(\.jsValue) ?? .null
            return stats.jsValue
        }

        JSObject.global["lyteBrowser"] = api.jsValue
    }

    // MARK: Arguments (a page mistake never traps the WASM instance)

    private static func number(_ args: [JSValue], _ index: Int) -> Double? {
        guard index < args.count, let value = args[index].number, value.isFinite else {
            return nil
        }
        return value
    }

    private static func string(_ args: [JSValue], _ index: Int) -> String? {
        index < args.count ? args[index].string : nil
    }

    private static func bool(_ args: [JSValue], _ index: Int) -> Bool {
        guard index < args.count else { return false }
        return args[index].boolean ?? ((args[index].number ?? 0) != 0)
    }

    private static func micros(_ args: [JSValue], _ index: Int) -> UInt64 {
        guard let value = number(args, index), value >= 0,
              value < 9_007_199_254_740_992
        else { return 0 }
        return UInt64(value)
    }

    private static func uint32(_ args: [JSValue], _ index: Int) -> UInt32? {
        guard let value = number(args, index), value >= 0,
              value <= Double(UInt32.max), value == value.rounded()
        else { return nil }
        return UInt32(value)
    }

    /// One copy, straight from the JS buffer into the array's storage.
    private static func bytes(_ args: [JSValue], _ index: Int) -> [UInt8]? {
        guard index < args.count,
              let typed = JSTypedArray<UInt8>(from: args[index])
        else { return nil }
        let count = typed.length
        guard count > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            typed.copyMemory(to: buffer)
            initialized = count
        }
    }

    private static func inputBody(_ args: [JSValue]) -> InputEvent.Body? {
        switch string(args, 0) {
        case "pointerMotionAbsolute":
            guard let x = number(args, 2), let y = number(args, 3) else { return nil }
            return .pointerMotionAbsolute(x: x, y: y)
        case "pointerMotionRelative":
            guard let dx = number(args, 2), let dy = number(args, 3) else { return nil }
            return .pointerMotionRelative(dx: dx, dy: dy)
        case "pointerButton":
            guard let button = uint32(args, 2) else { return nil }
            return .pointerButton(button: button, pressed: bool(args, 3))
        case "pointerAxis":
            guard let dx = number(args, 2), let dy = number(args, 3) else { return nil }
            return .pointerAxis(dx: dx, dy: dy, finish: bool(args, 4))
        case "keyKeycode":
            guard let keycode = uint32(args, 2) else { return nil }
            return .keyKeycode(keycode: keycode, pressed: bool(args, 3))
        default:
            return nil
        }
    }

    // MARK: Session

    private static func controlOpen(hostStaticHex: String, pin: String) -> JSValue {
        do {
            let opened = try BrowserControlSession(
                hostStaticPublicKeyHex: hostStaticHex, pin: pin
            )
            session = opened
            return [
                "ok": true.jsValue,
                "clientStaticPublicKeyHex": opened.clientStaticPublicKeyHex.jsValue,
            ].jsValue
        } catch {
            session = nil
            return ["ok": false.jsValue, "error": String(describing: error).jsValue].jsValue
        }
    }

    private static func withSession(
        _ body: (BrowserControlSession) -> JSValue
    ) -> JSValue {
        guard let session else { return failureStep("controlOpen first") }
        return body(session)
    }

    private static func facts() -> JSValue {
        guard let session else { return ["status": "none".jsValue].jsValue }
        let counters = session.counters
        return [
            "status": session.currentStatus.rawValue.jsValue,
            "handshakeCompleted": session.handshakeCompleted.jsValue,
            "paired": session.paired.jsValue,
            "capabilitiesAgreed": session.capabilitiesAgreed.jsValue,
            "clipboardNegotiated": session.clipboardNegotiated.jsValue,
            "reliableQuiescent": session.isReliableQuiescent.jsValue,
            "unsealFailures": Double(counters.unsealFailures).jsValue,
            "idrRequestsSent": Double(counters.idrRequestsSent).jsValue,
            "feedbackReportsSent": Double(counters.feedbackReportsSent).jsValue,
        ].jsValue
    }

    private static func quietOrStep(
        _ step: BrowserControlSession.Step, statusBefore: BrowserControlSession.Status
    ) -> JSValue {
        step.isQuiet && step.status == statusBefore ? .null : stepToJS(step)
    }

    private static func stepToJS(_ step: BrowserControlSession.Step) -> JSValue {
        [
            "outbound": step.outbound.isEmpty
                ? JSValue.null : JSTypedArray<UInt8>(pack(step.outbound)).jsValue,
            "events": step.events.joined(separator: "\n").jsValue,
            "status": step.status.rawValue.jsValue,
            "detail": step.detail.jsValue,
            "failed": (step.status == .failed).jsValue,
            "scheduled": step.scheduled.map(scheduledFrameToJS).jsValue,
        ].jsValue
    }

    private static func failureStep(_ detail: String) -> JSValue {
        [
            "outbound": JSValue.null,
            "events": "FAIL  \(detail)".jsValue,
            "status": "failed".jsValue,
            "detail": detail.jsValue,
            "failed": true.jsValue,
            "scheduled": [JSValue]().jsValue,
        ].jsValue
    }

    private static func scheduledFrameToJS(
        _ frame: BrowserVideoPlayout.ScheduledFrame
    ) -> JSValue {
        [
            "frameNumber": Double(frame.frameNumber).jsValue,
            "presentationMicroseconds": Double(frame.presentationMicroseconds).jsValue,
            "isRandomAccess": frame.isRandomAccess.jsValue,
            "shouldPresent": frame.shouldPresent.jsValue,
        ].jsValue
    }

    // MARK: Packed datagrams

    static func pack(_ datagrams: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(datagrams.reduce(0) { $0 + 2 + $1.count })
        for datagram in datagrams {
            out.append(UInt8(truncatingIfNeeded: datagram.count >> 8))
            out.append(UInt8(truncatingIfNeeded: datagram.count))
            out += datagram
        }
        return out
    }

    /// The received batch's records, or nil when it is malformed.
    static func received(
        _ packed: [UInt8]
    ) -> [(bytes: Range<Int>, ageMicros: UInt64)]? {
        var records: [(bytes: Range<Int>, ageMicros: UInt64)] = []
        var offset = 0
        while offset < packed.count {
            guard offset + 6 <= packed.count else { return nil }
            let length = Int(packed[offset]) << 8 | Int(packed[offset + 1])
            var age: UInt64 = 0
            for byte in packed[(offset + 2)..<(offset + 6)] {
                age = age << 8 | UInt64(byte)
            }
            offset += 6
            guard offset + length <= packed.count else { return nil }
            records.append((offset..<(offset + length), age))
            offset += length
        }
        return records
    }

    // MARK: Frames

    private static func classifyFrameBytes(_ bytes: [UInt8]) -> JSValue {
        let classification = AnnexBCheck.classifyFrame(bytes)
        return [
            "ok": true.jsValue,
            "frameShaped": classification.isFrameShaped.jsValue,
            "containsIrap": classification.containsIrap.jsValue,
            "byteCount": Double(bytes.count).jsValue,
            "summary": AnnexBCheck.summary(of: bytes).jsValue,
        ].jsValue
    }
}

extension BrowserControlSession.Step {
    /// Folds a later step of the same burst into this one, in place.
    fileprivate mutating func append(_ next: Self) {
        outbound.append(contentsOf: next.outbound)
        events.append(contentsOf: next.events)
        scheduled.append(contentsOf: next.scheduled)
        status = next.status
        detail = next.detail
        passed = next.passed
    }
}
