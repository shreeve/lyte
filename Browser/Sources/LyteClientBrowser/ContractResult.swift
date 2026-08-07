/// One frozen-contract check result for the B-1 Chrome proof page.
struct ContractResult: Sendable {
    var name: String
    var passed: Bool
    var detail: String

    var line: String {
        "\(passed ? "PASS" : "FAIL")  \(name) — \(detail)"
    }
}
