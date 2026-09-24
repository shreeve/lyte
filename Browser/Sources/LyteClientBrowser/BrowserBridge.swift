import JavaScriptKit
import LyteClientBrowserCore
import LyteCore
import LyteWire

/// Publishes `globalThis.lyteBrowser`, the page's only door into the
/// sans-IO core; this file converts values and owns the single session.
/// Datagrams cross in one `Uint8Array` of `u16 big-endian length + bytes`
/// records, so a burst costs one call and one copy each way. A step with
/// nothing to act on returns `null`.
enum BrowserBridge {
    // The page's single-threaded pump owns this; JavaScriptKit calls are serial.
    nonisolated(unsafe) private static var session: BrowserControlSession?
    nonisolated(unsafe) private static var closures: [JSClosure] = []

    static func runFrozenContracts() -> [ContractResult] {
        [FrozenEnvelopeContract.verify(), FrozenNoiseContract.verify()]
    }

    static func install() {
        var api: [String: JSValue] = [
            "envelopeVectorHex": FrozenEnvelopeContract.datagramHex.jsValue,
            "noiseMsg1CiphertextHex": DatagramCarrierProof.noiseMsg1CiphertextHex.jsValue,
            "wireBudgetBytes": Double(DatagramCarrierProof.wireBudgetBytes).jsValue,
            "conductorBeatMicroseconds":
                Double(VideoBeatConductor.Config().beatPeriodMicroseconds).jsValue,
            "vectorNames": [FrozenEnvelopeContract.vectorName, FrozenNoiseContract.vectorName]
                .joined(separator: "; ").jsValue,
        ]
        func expose(_ name: String, _ body: @escaping ([JSValue]) -> JSValue) {
            let closure = JSClosure { body($0) }
            closures.append(closure)
            api[name] = closure.jsValue
        }

        // Frozen contracts and carrier proofs.
        expose("runFrozenContracts") { _ in resultsToJS(runFrozenContracts()) }
        expose("verifyEnvelopeHex") { args in
            verifyEnvelopeHex(string(args, 0) ?? FrozenEnvelopeContract.datagramHex)
        }
        expose("verifyCarrierEcho") { args in
            carrierResultToJS(DatagramCarrierProof.verifyEcho(
                kind: string(args, 0) ?? "opaque",
                sentHex: string(args, 1) ?? "",
                recvHex: string(args, 2) ?? ""
            ))
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
                guard let packed = bytes(args, 0), let datagrams = unpack(packed) else {
                    return .null
                }
                let now = micros(args, 1)
                let before = session.currentStatus
                var merged: BrowserControlSession.Step?
                for datagram in datagrams {
                    let step = session.ingest(datagram: datagram, nowMicros: now)
                    merged = merged.map { merge($0, step) } ?? step
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
        expose("mediaNotePresented") { args in
            if let frame = uint32(args, 0) { session?.notePresented(frameNumber: frame) }
            return .undefined
        }
        expose("mediaNoteDropped") { args in
            if let frame = uint32(args, 0) { session?.noteDropped(frameNumber: frame) }
            return .undefined
        }
        expose("mediaStats") { _ in
            let counters = session?.videoCounters ?? BrowserVideoPlayout.Counters()
            return [
                "assembled": Double(counters.framesAssembled).jsValue,
                "presented": Double(counters.framesPresented).jsValue,
                "skippedLate": Double(counters.framesSkippedLate).jsValue,
                "notPresentable": Double(counters.framesNotPresentable).jsValue,
                "decodeBacklogEvicted": Double(counters.decodeBacklogEvicted).jsValue,
                "fecImpossible": Double(counters.fecImpossible).jsValue,
                "shardsDropped": Double(counters.shardsDropped).jsValue,
            ].jsValue
        }
        expose("audioPopPacket") { _ in
            guard let packet = session?.popAudioPacket() else { return .null }
            return [
                "number": Double(packet.number).jsValue,
                "captureMicroseconds": Double(packet.captureMicroseconds).jsValue,
                "recovered": packet.recovered.jsValue,
                "bytes": JSTypedArray<UInt8>(packet.bytes).jsValue,
            ].jsValue
        }
        expose("interactionStats") { _ in
            var stats: [String: JSValue] = [:]
            stats["inputsSent"] = Double(session?.inputsSent ?? 0).jsValue
            stats["inputEchoes"] = Double(session?.inputEchoes ?? 0).jsValue
            stats["clipboardSent"] = Double(session?.clipboardSent ?? 0).jsValue
            stats["clipboardReceived"] = Double(session?.clipboardReceived ?? 0).jsValue
            stats["clipboardNegotiated"] = (session?.clipboardNegotiated ?? false).jsValue
            stats["audioAssembled"] = Double(session?.audioPacketsAssembled ?? 0).jsValue
            stats["audioPopped"] = Double(session?.audioPacketsPopped ?? 0).jsValue
            stats["audioDroppedStale"] = Double(session?.audioPacketsDroppedStale ?? 0).jsValue
            stats["lastClipboardText"] = session?.lastClipboardText.map(\.jsValue) ?? .null
            return stats.jsValue
        }

        JSObject.global["lyteBrowser"] = api.jsValue
    }

    /// Paints the frozen-contract results. Page JS owns the session proofs
    /// and `lyteSessionPassed`.
    static func paintProofPage(results: [ContractResult]) {
        let document = JSObject.global.document
        let passed = results.allSatisfy(\.passed)
        if let status = document.getElementById("status").object {
            status.textContent = .string(passed ? "PASS" : "FAIL")
            status.className = .string(passed ? "pass" : "fail")
        }
        if let log = document.getElementById("log").object {
            log.textContent = .string(results.map(\.line).joined(separator: "\n"))
        }
        if let meta = document.getElementById("meta").object {
            meta.textContent = .string(
                """
                LyteClientBrowser — proof harness over WebTransport
                Contracts: \(FrozenEnvelopeContract.vectorName); \(FrozenNoiseContract.vectorName)
                Carrier: opaque WT datagrams via lyte-wt-sidecar (ciphertext only)
                Control: Noise IK + PIN PAKE + capabilities via LyteClientSession
                Video: assemble → Conductor → WebCodecs → WebGPU
                Input/clipboard: sealed CTRL (InputEvent/echo, ClipboardSet/Announce)
                Audio: sealed Opus → AudioDepacketizer → WebCodecs → AudioWorklet
                """
            )
        }
        JSObject.global.lyteContractsPassed = .boolean(passed)
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

    private static func bytes(_ args: [JSValue], _ index: Int) -> [UInt8]? {
        guard index < args.count,
              let typed = JSTypedArray<UInt8>(from: args[index])
        else { return nil }
        return typed.withUnsafeBytes { Array($0) }
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
                "hostStaticPublicKeyHex": opened.hostStaticPublicKeyHex.jsValue,
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
            "closeReason": session.closeReason.map { String(describing: $0).jsValue } ?? .null,
            "undecodableDatagrams": Double(counters.undecodableDatagrams).jsValue,
            "unsealFailures": Double(counters.unsealFailures).jsValue,
            "message1Transmissions": Double(counters.message1Transmissions).jsValue,
            "idrRequestsSent": Double(counters.idrRequestsSent).jsValue,
        ].jsValue
    }

    private static func merge(
        _ into: BrowserControlSession.Step, _ next: BrowserControlSession.Step
    ) -> BrowserControlSession.Step {
        var merged = next
        merged.outbound = into.outbound + next.outbound
        merged.events = into.events + next.events
        merged.scheduled = into.scheduled + next.scheduled
        return merged
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
            "outboundCount": Double(step.outbound.count).jsValue,
            "events": step.events.joined(separator: "\n").jsValue,
            "status": step.status.rawValue.jsValue,
            "detail": step.detail.jsValue,
            "passed": step.passed.jsValue,
            "ready": (step.status == .ready).jsValue,
            "closed": (step.status == .closed).jsValue,
            "failed": (step.status == .failed).jsValue,
            "scheduled": step.scheduled.map(scheduledFrameToJS).jsValue,
        ].jsValue
    }

    private static func failureStep(_ detail: String) -> JSValue {
        [
            "outbound": JSValue.null,
            "outboundCount": 0.jsValue,
            "events": "FAIL  \(detail)".jsValue,
            "status": "failed".jsValue,
            "detail": detail.jsValue,
            "passed": false.jsValue,
            "ready": false.jsValue,
            "closed": false.jsValue,
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
            "cueMicroseconds": Double(frame.cueMicroseconds).jsValue,
            "pathDelayMicroseconds": Double(frame.pathDelayMicroseconds).jsValue,
            "reserveMicroseconds": Double(frame.reserveMicroseconds).jsValue,
            "latenessMicroseconds": Double(frame.latenessMicroseconds).jsValue,
            "isRandomAccess": frame.isRandomAccess.jsValue,
            "shouldPresent": frame.shouldPresent.jsValue,
            "annexBByteCount": Double(frame.annexBByteCount).jsValue,
            "sourceCaptureMicroseconds": Double(frame.sourceCaptureMicroseconds).jsValue,
            "arrivalMicroseconds": Double(frame.arrivalMicroseconds).jsValue,
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

    static func unpack(_ packed: [UInt8]) -> [[UInt8]]? {
        var datagrams: [[UInt8]] = []
        var offset = 0
        while offset < packed.count {
            guard offset + 2 <= packed.count else { return nil }
            let length = Int(packed[offset]) << 8 | Int(packed[offset + 1])
            offset += 2
            guard offset + length <= packed.count else { return nil }
            datagrams.append(Array(packed[offset..<offset + length]))
            offset += length
        }
        return datagrams
    }

    // MARK: Contracts

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

    private static func resultsToJS(_ results: [ContractResult]) -> JSValue {
        [
            "passed": results.allSatisfy(\.passed).jsValue,
            "lines": results.map(\.line).joined(separator: "\n").jsValue,
            "count": Double(results.count).jsValue,
        ].jsValue
    }

    private static func carrierResultToJS(_ result: ContractResult) -> JSValue {
        [
            "passed": result.passed.jsValue,
            "detail": result.detail.jsValue,
            "lines": result.line.jsValue,
            "name": result.name.jsValue,
        ].jsValue
    }

    private static func verifyEnvelopeHex(_ hex: String) -> JSValue {
        let name = "envelope-hex/js-supplied"
        if hex.filter({ !$0.isWhitespace }).lowercased() == FrozenEnvelopeContract.datagramHex {
            return resultsToJS([FrozenEnvelopeContract.verify()])
        }
        guard let datagram = Hex.bytes(hex) else {
            return resultsToJS([
                ContractResult(name: name, passed: false, detail: "malformed hex from JavaScript"),
            ])
        }
        do {
            let (envelope, payload) = try Envelope.decode(datagram)
            let matched = try envelope.encode(payload: Array(payload)) == datagram
            return resultsToJS([
                ContractResult(
                    name: name,
                    passed: matched,
                    detail: matched
                        ? "JS-supplied datagram round-tripped (\(datagram.count) B, chan=\(envelope.channel.rawValue))"
                        : "re-encode diverged from JS-supplied bytes"
                ),
            ])
        } catch {
            return resultsToJS([
                ContractResult(name: name, passed: false, detail: "codec threw: \(error)"),
            ])
        }
    }
}
