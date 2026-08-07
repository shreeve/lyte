import JavaScriptKit
import LyteCore
import LyteWire

enum BrowserBridge {
    // Single-threaded JS↔WASM pump owns this; JavaScriptKit calls are serial.
    nonisolated(unsafe) private static var controlSession: BrowserControlSession?

    static func runFrozenContracts() -> [ContractResult] {
        [
            FrozenEnvelopeContract.verify(),
            FrozenNoiseContract.verify(),
        ]
    }

    /// Installs `globalThis.lyteBrowser` so page JavaScript can call into
    /// Swift/WASM and drive B-1/B-2 proofs plus the B-3 control session.
    static func install() {
        let runContracts = JSClosure { _ in
            resultsToJS(runFrozenContracts())
        }
        let verifyEnvelope = JSClosure { arguments in
            let hex = arguments.first?.string ?? FrozenEnvelopeContract.datagramHex
            return verifyEnvelopeHex(hex)
        }
        let verifyCarrier = JSClosure { arguments in
            let kind = arguments[0].string ?? "opaque"
            let sent = arguments[1].string ?? ""
            let recv = arguments[2].string ?? ""
            return carrierResultToJS(DatagramCarrierProof.verifyEcho(
                kind: kind,
                sentHex: sent,
                recvHex: recv
            ))
        }
        let openControl = JSClosure { arguments in
            controlOpen(
                hostStaticHex: arguments[0].string ?? "",
                pin: arguments[1].string ?? ""
            )
        }
        let beginControl = JSClosure { arguments in
            let now = UInt64(arguments[0].number ?? 0)
            return controlBegin(nowMicros: now)
        }
        let ingestControl = JSClosure { arguments in
            let hex = arguments[0].string ?? ""
            let now = UInt64(arguments[1].number ?? 0)
            return controlIngest(datagramHex: hex, nowMicros: now)
        }
        let ingestControlBytes = JSClosure { arguments in
            let now = UInt64(arguments[1].number ?? 0)
            guard let typed = JSTypedArray<UInt8>(from: arguments[0]) else {
                return stepToJS(
                    outbound: [], events: ["FAIL  ingest: not Uint8Array"],
                    status: "failed", detail: "not Uint8Array", passed: false
                )
            }
            let bytes = typed.withUnsafeBytes { Array($0) }
            return controlIngest(datagram: bytes, nowMicros: now)
        }
        let tickControl = JSClosure { arguments in
            let now = UInt64(arguments[0].number ?? 0)
            return controlTick(nowMicros: now)
        }
        let teardownControl = JSClosure { arguments in
            let now = UInt64(arguments[0].number ?? 0)
            return controlTeardown(nowMicros: now)
        }
        let classifyAnnexB = JSClosure { arguments in
            classifyAnnexBHex(arguments[0].string ?? "")
        }
        let classifyAnnexBTyped = JSClosure { arguments in
            guard let typed = JSTypedArray<UInt8>(from: arguments[0]) else {
                return [
                    "ok": false.jsValue,
                    "frameShaped": false.jsValue,
                    "containsIrap": false.jsValue,
                    "byteCount": 0.jsValue,
                    "summary": "".jsValue,
                    "detail": "not Uint8Array".jsValue,
                ].jsValue
            }
            let bytes = typed.withUnsafeBytes { Array($0) }
            return classifyFrameBytes(bytes)
        }
        let mediaAnnexB = JSClosure { arguments in
            let frame = UInt32(arguments[0].number ?? -1)
            guard let session = controlSession,
                  let hex = session.annexBHex(frameNumber: frame)
            else {
                return JSValue.null
            }
            return hex.jsValue
        }
        let mediaAnnexBBytes = JSClosure { arguments in
            let frame = UInt32(arguments[0].number ?? -1)
            guard let session = controlSession,
                  let bytes = session.annexBBytes(frameNumber: frame)
            else {
                return JSValue.null
            }
            return JSTypedArray<UInt8>(bytes).jsValue
        }
        let mediaPopDue = JSClosure { arguments in
            let now = UInt64(arguments[0].number ?? 0)
            guard let session = controlSession,
                  let frame = session.popDueFrame(nowMicros: now)
            else {
                return JSValue.null
            }
            return scheduledFrameToJS(frame)
        }
        let mediaNotePresented = JSClosure { arguments in
            let frame = UInt32(arguments[0].number ?? -1)
            controlSession?.notePresented(frameNumber: frame)
            return JSValue.undefined
        }
        let mediaNoteDropped = JSClosure { arguments in
            let frame = UInt32(arguments[0].number ?? -1)
            controlSession?.noteDropped(frameNumber: frame)
            return JSValue.undefined
        }
        let mediaStats = JSClosure { _ in
            guard let session = controlSession else {
                return [
                    "assembled": 0.jsValue,
                    "presented": 0.jsValue,
                ].jsValue
            }
            return [
                "assembled": Double(session.framesAssembled).jsValue,
                "presented": Double(session.framesPresented).jsValue,
            ].jsValue
        }
        let sendInput = JSClosure { arguments in
            controlSendInput(arguments)
        }
        let shareClipboard = JSClosure { arguments in
            let text = arguments[0].string ?? ""
            let now = UInt64(arguments[1].number ?? 0)
            return controlClipboardSet(text: text, nowMicros: now)
        }
        let audioPop = JSClosure { _ in
            guard let packet = controlSession?.popAudioPacket() else {
                return JSValue.null
            }
            return [
                "number": Double(packet.number).jsValue,
                "captureMicroseconds": Double(packet.captureMicroseconds)
                    .jsValue,
                "recovered": packet.recovered.jsValue,
                "byteCount": Double(packet.bytes.count).jsValue,
                "bytes": JSTypedArray<UInt8>(packet.bytes).jsValue,
            ].jsValue
        }
        let interactionStats = JSClosure { _ in
            guard let session = controlSession else {
                return [
                    "inputsSent": 0.jsValue,
                    "inputEchoes": 0.jsValue,
                    "clipboardSent": 0.jsValue,
                    "clipboardReceived": 0.jsValue,
                    "clipboardNegotiated": false.jsValue,
                    "audioAssembled": 0.jsValue,
                    "audioPopped": 0.jsValue,
                    "lastClipboardText": JSValue.null,
                ].jsValue
            }
            return [
                "inputsSent": Double(session.inputsSent).jsValue,
                "inputEchoes": Double(session.inputEchoes).jsValue,
                "clipboardSent": Double(session.clipboardSent).jsValue,
                "clipboardReceived": Double(session.clipboardReceived).jsValue,
                "clipboardNegotiated": session.clipboardNegotiated.jsValue,
                "audioAssembled": Double(session.audioPacketsAssembled)
                    .jsValue,
                "audioPopped": Double(session.audioPacketsPopped).jsValue,
                "lastClipboardText":
                    (session.lastClipboardText.map { $0.jsValue }
                        ?? JSValue.null),
            ].jsValue
        }

        JSObject.global["lyteBrowser"] = [
            "runFrozenContracts": runContracts.jsValue,
            "verifyEnvelopeHex": verifyEnvelope.jsValue,
            "verifyCarrierEcho": verifyCarrier.jsValue,
            "envelopeVectorHex": FrozenEnvelopeContract.datagramHex.jsValue,
            "noiseMsg1CiphertextHex": DatagramCarrierProof.noiseMsg1CiphertextHex.jsValue,
            "wireBudgetBytes": Double(DatagramCarrierProof.wireBudgetBytes).jsValue,
            "vectorNames": [
                FrozenEnvelopeContract.vectorName,
                FrozenNoiseContract.vectorName,
            ].joined(separator: "; ").jsValue,
            "controlOpen": openControl.jsValue,
            "controlBegin": beginControl.jsValue,
            "controlIngest": ingestControl.jsValue,
            "controlIngestBytes": ingestControlBytes.jsValue,
            "controlTick": tickControl.jsValue,
            "controlTeardown": teardownControl.jsValue,
            "classifyAnnexBHex": classifyAnnexB.jsValue,
            "classifyAnnexBBytes": classifyAnnexBTyped.jsValue,
            "mediaAnnexBHex": mediaAnnexB.jsValue,
            "mediaAnnexBBytes": mediaAnnexBBytes.jsValue,
            "mediaPopDue": mediaPopDue.jsValue,
            "mediaNotePresented": mediaNotePresented.jsValue,
            "mediaNoteDropped": mediaNoteDropped.jsValue,
            "mediaStats": mediaStats.jsValue,
            "controlSendInput": sendInput.jsValue,
            "controlClipboardSet": shareClipboard.jsValue,
            "audioPopPacket": audioPop.jsValue,
            "interactionStats": interactionStats.jsValue,
        ].jsValue
    }

    /// Paints B-1 frozen-contract results. The page JS appends B-2…B-6
    /// lines and owns `lyteB1Passed` … `lyteB6Passed`.
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
                LyteClientBrowser B-6 — interaction shell over B-3…B-5
                Contracts: \(FrozenEnvelopeContract.vectorName); \(FrozenNoiseContract.vectorName)
                Carrier: opaque WT datagrams via lyte-wt-sidecar (ciphertext only)
                Control: Noise IK + PIN PAKE + capabilities via LyteClientSession
                Video: corpus → assemble → Conductor → WebCodecs → WebGPU
                Input/clipboard: sealed CTRL (InputEvent/echo, ClipboardSet/Announce)
                Audio: sealed Opus → AudioDepacketizer → WebCodecs → AudioWorklet
                Gap: not live Direct Eye / not daily-driver remote desktop
                """
            )
        }

        JSObject.global.lyteB1Passed = .boolean(passed)
    }

    /// LyteCore Annex-B classification for a JS-supplied access unit (B-4).
    private static func classifyAnnexBHex(_ hex: String) -> JSValue {
        guard let bytes = Hex.bytes(hex) else {
            return [
                "ok": false.jsValue,
                "frameShaped": false.jsValue,
                "containsIrap": false.jsValue,
                "byteCount": 0.jsValue,
                "summary": "".jsValue,
                "detail": "malformed hex".jsValue,
            ].jsValue
        }
        return classifyFrameBytes(bytes)
    }

    private static func classifyFrameBytes(_ bytes: [UInt8]) -> JSValue {
        let classification = AnnexBCheck.classifyFrame(bytes)
        let summary = AnnexBCheck.summary(of: bytes)
        return [
            "ok": true.jsValue,
            "frameShaped": classification.isFrameShaped.jsValue,
            "containsIrap": classification.containsIrap.jsValue,
            "byteCount": Double(bytes.count).jsValue,
            "summary": summary.jsValue,
            "detail": (
                classification.isFrameShaped && classification.containsIrap
                    ? "IRAP-shaped Annex-B access unit"
                    : "not an IRAP-shaped Annex-B frame"
            ).jsValue,
        ].jsValue
    }

    // MARK: Control session bridge

    private static func controlOpen(
        hostStaticHex: String, pin: String
    ) -> JSValue {
        do {
            let session = try BrowserControlSession(
                hostStaticPublicKeyHex: hostStaticHex, pin: pin
            )
            controlSession = session
            return [
                "ok": true.jsValue,
                "clientStaticPublicKeyHex": session.clientStaticPublicKeyHex.jsValue,
                "hostStaticPublicKeyHex": session.hostStaticPublicKeyHex.jsValue,
            ].jsValue
        } catch {
            controlSession = nil
            return [
                "ok": false.jsValue,
                "error": String(describing: error).jsValue,
            ].jsValue
        }
    }

    private static func controlBegin(nowMicros: UInt64) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "controlOpen first", passed: false
            )
        }
        do {
            return stepToJS(try session.begin(nowMicros: nowMicros))
        } catch {
            return stepToJS(
                outbound: [], events: ["FAIL  begin: \(error)"],
                status: "failed", detail: String(describing: error),
                passed: false
            )
        }
    }

    private static func controlIngest(
        datagramHex: String, nowMicros: UInt64
    ) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "no session", passed: false
            )
        }
        return stepToJS(session.ingest(
            datagramHex: datagramHex, nowMicros: nowMicros
        ))
    }

    private static func controlIngest(
        datagram: [UInt8], nowMicros: UInt64
    ) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "no session", passed: false
            )
        }
        return stepToJS(session.ingest(
            datagram: datagram, nowMicros: nowMicros
        ))
    }

    private static func controlTick(nowMicros: UInt64) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "no session", passed: false
            )
        }
        return stepToJS(session.tick(nowMicros: nowMicros))
    }

    private static func controlTeardown(nowMicros: UInt64) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "no session", passed: false
            )
        }
        return stepToJS(session.teardown(nowMicros: nowMicros))
    }

    private static func controlSendInput(_ arguments: [JSValue]) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "no session", passed: false
            )
        }
        let kind = arguments[0].string ?? ""
        let now = UInt64(arguments[1].number ?? 0)
        let body: InputEvent.Body?
        switch kind {
        case "pointerMotionAbsolute":
            let x = arguments[2].number ?? 0
            let y = arguments[3].number ?? 0
            body = .pointerMotionAbsolute(x: x, y: y)
        case "pointerMotionRelative":
            let dx = arguments[2].number ?? 0
            let dy = arguments[3].number ?? 0
            body = .pointerMotionRelative(dx: dx, dy: dy)
        case "pointerButton":
            let button = UInt32(arguments[2].number ?? 0)
            let pressed = (arguments[3].boolean ?? false)
                || (arguments[3].number ?? 0) != 0
            body = .pointerButton(button: button, pressed: pressed)
        case "pointerAxis":
            let dx = arguments[2].number ?? 0
            let dy = arguments[3].number ?? 0
            let finish = (arguments[4].boolean ?? false)
                || (arguments[4].number ?? 0) != 0
            body = .pointerAxis(dx: dx, dy: dy, finish: finish)
        case "keyKeycode":
            let keycode = UInt32(arguments[2].number ?? 0)
            let pressed = (arguments[3].boolean ?? false)
                || (arguments[3].number ?? 0) != 0
            body = .keyKeycode(keycode: keycode, pressed: pressed)
        default:
            body = nil
        }
        guard let body else {
            return stepToJS(
                outbound: [], events: ["FAIL  input: unknown kind \(kind)"],
                status: "failed", detail: "unknown input kind", passed: false
            )
        }
        return stepToJS(session.sendInput(body: body, nowMicros: now))
    }

    private static func controlClipboardSet(
        text: String, nowMicros: UInt64
    ) -> JSValue {
        guard let session = controlSession else {
            return stepToJS(
                outbound: [], events: [], status: "failed",
                detail: "no session", passed: false
            )
        }
        return stepToJS(session.shareClipboard(
            text: text, nowMicros: nowMicros
        ))
    }

    private static func stepToJS(_ step: BrowserControlSession.Step) -> JSValue {
        stepToJS(
            outbound: step.outboundHex,
            events: step.events,
            status: step.status.rawValue,
            detail: step.detail,
            passed: step.passed,
            scheduled: step.scheduled
        )
    }

    private static func stepToJS(
        outbound: [String],
        events: [String],
        status: String,
        detail: String,
        passed: Bool,
        scheduled: [BrowserVideoPlayout.ScheduledFrame] = []
    ) -> JSValue {
        // Newline-joined hex keeps the bridge free of JSArray kit churn;
        // page JS splits on '\n' (empty string → zero datagrams).
        // Scheduled frames: one CSV line each for the media pump.
        let scheduledLines = scheduled.map(scheduledLine)
        return [
            "outboundHex": outbound.joined(separator: "\n").jsValue,
            "outboundCount": Double(outbound.count).jsValue,
            "events": events.joined(separator: "\n").jsValue,
            "status": status.jsValue,
            "detail": detail.jsValue,
            "passed": passed.jsValue,
            "ready": (status == "ready").jsValue,
            "closed": (status == "closed").jsValue,
            "failed": (status == "failed").jsValue,
            "scheduledLines": scheduledLines.joined(separator: "\n").jsValue,
            "scheduledCount": Double(scheduled.count).jsValue,
        ].jsValue
    }

    private static func scheduledLine(
        _ frame: BrowserVideoPlayout.ScheduledFrame
    ) -> String {
        [
            "\(frame.frameNumber)",
            "\(frame.presentationMicroseconds)",
            "\(frame.cueMicroseconds)",
            "\(frame.pathDelayMicroseconds)",
            "\(frame.reserveMicroseconds)",
            "\(frame.latenessMicroseconds)",
            frame.isRandomAccess ? "1" : "0",
            frame.shouldPresent ? "1" : "0",
            "\(frame.annexBByteCount)",
            "\(frame.sourceCaptureMicroseconds)",
            "\(frame.arrivalMicroseconds)",
        ].joined(separator: ",")
    }

    private static func scheduledFrameToJS(
        _ frame: BrowserVideoPlayout.ScheduledFrame
    ) -> JSValue {
        [
            "frameNumber": Double(frame.frameNumber).jsValue,
            "presentationMicroseconds": Double(frame.presentationMicroseconds)
                .jsValue,
            "cueMicroseconds": Double(frame.cueMicroseconds).jsValue,
            "pathDelayMicroseconds": Double(frame.pathDelayMicroseconds).jsValue,
            "reserveMicroseconds": Double(frame.reserveMicroseconds).jsValue,
            "latenessMicroseconds": Double(frame.latenessMicroseconds).jsValue,
            "isRandomAccess": frame.isRandomAccess.jsValue,
            "shouldPresent": frame.shouldPresent.jsValue,
            "annexBByteCount": Double(frame.annexBByteCount).jsValue,
            "sourceCaptureMicroseconds": Double(frame.sourceCaptureMicroseconds)
                .jsValue,
            "arrivalMicroseconds": Double(frame.arrivalMicroseconds).jsValue,
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
        if hex.filter({ !$0.isWhitespace }).lowercased()
            == FrozenEnvelopeContract.datagramHex
        {
            return resultsToJS([FrozenEnvelopeContract.verify()])
        }
        guard let datagram = Hex.bytes(hex) else {
            return resultsToJS([
                ContractResult(
                    name: "envelope-hex/js-supplied",
                    passed: false,
                    detail: "malformed hex from JavaScript"
                ),
            ])
        }
        do {
            let (envelope, payload) = try Envelope.decode(datagram)
            let reencoded = try envelope.encode(payload: Array(payload))
            let matched = reencoded == datagram
            return resultsToJS([
                ContractResult(
                    name: "envelope-hex/js-supplied",
                    passed: matched,
                    detail: matched
                        ? "JS-supplied datagram round-tripped (\(datagram.count) B, chan=\(envelope.channel.rawValue))"
                        : "re-encode diverged from JS-supplied bytes"
                ),
            ])
        } catch {
            return resultsToJS([
                ContractResult(
                    name: "envelope-hex/js-supplied",
                    passed: false,
                    detail: "codec threw: \(error)"
                ),
            ])
        }
    }
}
