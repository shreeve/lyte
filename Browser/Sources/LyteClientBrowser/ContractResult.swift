/// One frozen-contract or carrier-proof check result for the Chrome page.
struct ContractResult: Sendable {
    var name: String
    var passed: Bool
    var detail: String

    var line: String {
        "\(passed ? "PASS" : "FAIL")  \(name) — \(detail)"
    }
}
