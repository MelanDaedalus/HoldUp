import Foundation

@main struct EvidenceLiveSmoke {
    static func main() async {
        let engine = OllamaEngine()
        do {
            let claim = "The example.com and example.org domains are available for registration."
            let page = try await EvidenceWeb.page("https://www.iana.org/help/example-domains")
            let passages = EvidenceReview.relevantPassages(in: page.text, for: claim, limit: PreparedCheck.excerptLimit)
            guard passages.contains("available for registration") else { throw CheckError.invalidResponse }
            if CommandLine.arguments.contains("--fetch-only") {
                print("Fetched IANA’s public page and selected the passage about registration.")
                return
            }
            let model = CommandLine.arguments.dropFirst().first ?? "qwen3.8:27b"
            let installed = try await engine.start()
            guard installed.contains(where: { $0.name == model }) else { throw OllamaError.noModels }
            let input = try EvidenceReview.request(source: page.text, claim: claim)
            let text = try await engine.generate(system: EvidenceReview.systemMessage, user: input.userMessage,
                                                 schema: EvidenceReview.schema, model: model)
            let result = try input.result(from: text)
            let citations = EvidenceReview.citations(from: result, original: page.text, claim: claim, url: page.url,
                                                     title: page.title, date: page.publishedDate)
            guard citations.contains(where: { $0.label == "Challenges" }) else { throw CheckError.invalidResponse }
            await engine.stop()
            print("Fetched the IANA example-domains page and validated an exact source quote challenging the sample claim")
        } catch {
            await engine.stop()
            print("Evidence smoke test: " + error.localizedDescription)
            exit(1)
        }
    }
}
