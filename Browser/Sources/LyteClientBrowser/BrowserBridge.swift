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
    /// Swift/WASM and re-run the frozen contracts without a reload.
    static func install() {
        let runContracts = JSClosure { _ in
            resultsToJS(runFrozenContracts())
        }
        let verifyEnvelope = JSClosure { arguments in
            let hex = arguments.first?.string ?? FrozenEnvelopeContract.datagramHex
            return verifyEnvelopeHex(hex)
        }

        JSObject.global["lyteBrowser"] = [
            "runFrozenContracts": runContracts.jsValue,
            "verifyEnvelopeHex": verifyEnvelope.jsValue,
            "envelopeVectorHex": FrozenEnvelopeContract.datagramHex.jsValue,
            "vectorNames": [
                FrozenEnvelopeContract.vectorName,
                FrozenNoiseContract.vectorName,
            ].joined(separator: "; ").jsValue,
        ].jsValue
    }

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
                LyteClientBrowser B-1 — Swift WASM + JavaScriptKit in Chrome
                Contracts: \(FrozenEnvelopeContract.vectorName); \(FrozenNoiseContract.vectorName)
                Bridge: globalThis.lyteBrowser.runFrozenContracts()
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
