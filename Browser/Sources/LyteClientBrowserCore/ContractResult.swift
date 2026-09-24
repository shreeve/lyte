/// One frozen-contract or carrier-proof check result for the Chrome page.
public struct ContractResult: Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }

    public var line: String {
        "\(passed ? "PASS" : "FAIL")  \(name) — \(detail)"
    }
}
