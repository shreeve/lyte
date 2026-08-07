import JavaScriptKit
import LyteCore
import LyteWire

enum BrowserBridge {
    static func runFrozenContracts() -> [ContractResult] {
        [
            FrozenEnvelopeContract.verify(),
            FrozenNoiseContract.verify(),
        ]
    }

    /// Installs `globalThis.lyteBrowser` so page JavaScript can call into
    /// Swift/WASM and re-run frozen contracts / carrier checks without a reload.
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
        ].jsValue
    }

    /// Paints B-1 frozen-contract results. The page JS appends B-2 WebTransport
    /// carrier lines and owns `lyteB2Passed`.
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
                LyteClientBrowser B-2 — WASM contracts + WebTransport datagram carrier
                Contracts: \(FrozenEnvelopeContract.vectorName); \(FrozenNoiseContract.vectorName)
                Carrier: opaque WT datagrams via lyte-wt-sidecar (ciphertext only)
                Bridge: globalThis.lyteBrowser.{runFrozenContracts,verifyCarrierEcho}
                """
            )
        }

        JSObject.global.lyteB1Passed = .boolean(passed)
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
