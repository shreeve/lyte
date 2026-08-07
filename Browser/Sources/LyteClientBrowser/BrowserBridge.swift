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
            "controlTick": tickControl.jsValue,
            "controlTeardown": teardownControl.jsValue,
            "classifyAnnexBHex": classifyAnnexB.jsValue,
        ].jsValue
    }

    /// Paints B-1 frozen-contract results. The page JS appends B-2/B-3/B-4
    /// lines and owns `lyteB2Passed` / `lyteB3Passed` / `lyteB4Passed`.
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
                LyteClientBrowser B-4 — WASM + WT control + one WebCodecs/WebGPU frame
                Contracts: \(FrozenEnvelopeContract.vectorName); \(FrozenNoiseContract.vectorName)
                Carrier: opaque WT datagrams via lyte-wt-sidecar (ciphertext only)
                Control: Noise IK + PIN PAKE + capabilities via LyteClientSession
                Frame: canned corpus IRAP → WebCodecs → WebGPU (not live Conductor)
                Bridge: control{Open,Begin,Ingest,Tick,Teardown}; classifyAnnexBHex
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

    private static func stepToJS(_ step: BrowserControlSession.Step) -> JSValue {
        stepToJS(
            outbound: step.outboundHex,
            events: step.events,
            status: step.status.rawValue,
            detail: step.detail,
            passed: step.passed
        )
    }

    private static func stepToJS(
        outbound: [String],
        events: [String],
        status: String,
        detail: String,
        passed: Bool
    ) -> JSValue {
        // Newline-joined hex keeps the bridge free of JSArray kit churn;
        // page JS splits on '\n' (empty string → zero datagrams).
        [
            "outboundHex": outbound.joined(separator: "\n").jsValue,
            "outboundCount": Double(outbound.count).jsValue,
            "events": events.joined(separator: "\n").jsValue,
            "status": status.jsValue,
            "detail": detail.jsValue,
            "passed": passed.jsValue,
            "ready": (status == "ready").jsValue,
            "closed": (status == "closed").jsValue,
            "failed": (status == "failed").jsValue,
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
