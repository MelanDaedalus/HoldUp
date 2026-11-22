import Foundation

@main struct OllamaLiveSmoke {
    static func main() async {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let engine = OllamaEngine(modelStore: fixture)
        do {
            let models = try await engine.start()
            guard let model = models.first(where: { $0.name == "claim-check-fixture:latest" }) else {
                throw OllamaError.noModels
            }
            let schema = Data(#"""
            {"type":"object","properties":{"outcome":{"type":"string","enum":["no_flags"]},"findings":{"type":"array","maxItems":0,"items":{"type":"string"}}},"required":["outcome","findings"],"additionalProperties":false}
            """#.utf8)
            let input = try PreparedCheck(excerpt: "The weather was wonderful.", context: "", rules: Rule.defaults)
            let text = try await engine.generate(system: PreparedCheck.systemMessage, user: input.userMessage,
                                                 schema: schema, model: model.name)
            let result = try input.result(from: text)
            guard result.outcome == .noFlags else { throw CheckError.invalidResponse }
            await engine.stop()
            print("Installed Ollama loaded a fixture and returned validated JSON in a separate cloud-disabled session")
        } catch {
            await engine.stop()
            print("Ollama live smoke: \(error.localizedDescription)")
            exit(1)
        }
    }
}
