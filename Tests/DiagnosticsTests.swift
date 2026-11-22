import Foundation

@main struct DiagnosticsTests {
    static func main() {
        let os = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        let failedCheck = BetaDiagnostics.Issue(area: .check, message: "Ollama could not load this model. Try a smaller local model or free up memory.")
        let diagnostics = BetaDiagnostics(version: "0.4.9", osVersion: os,
                                          model: .ollama("qwen3.8:27b"), issue: failedCheck)
        let report = diagnostics.report
        precondition(report.contains("Hold UP 0.4.9") && report.contains("macOS 26.1.0"))
        precondition(report.contains("Ollama · qwen3.8:27b"))
        precondition(report.contains("The selected model could not load."))

        let privateText = "private claim from https://example.test/secret at /Users/person/review.pdf"
        let opaqueIssue = BetaDiagnostics.Issue(area: .sources, message: privateText)
        let redacted = BetaDiagnostics(version: "1.0", osVersion: os,
                                       model: .ollama("https://example.test/private:model"), issue: opaqueIssue).text
        precondition(redacted.contains("Source review failed."))
        precondition(redacted.contains("Model name unavailable"))
        precondition(!redacted.contains("https://") && !redacted.contains("/Users/") && !redacted.contains("private"))
        precondition(BetaDiagnostics.Model.ollama("namespace/example:latest").description == "Ollama · example:latest")
        precondition(BetaDiagnostics(version: "1.0", osVersion: os, model: .builtIn("Qwen3 1.7B"), issue: nil)
            .text.contains("Built-in · Qwen3 1.7B"))
        print("Beta diagnostics preserve safe release, model, and failure details.")
    }
}
