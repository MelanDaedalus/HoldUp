import Foundation

@main struct EvidenceBenchmark {
    private struct Case: Decodable {
        struct Source: Decodable {
            let url: URL
            let title: String
            let text: String
        }

        struct Expectation: Decodable {
            let dimension: String
            let relation: String
        }

        let id: String
        let claim: String
        let note: String
        let sources: [Source]
        let expectations: [Expectation]
        let expectedConflict: Bool?
    }

    private struct Backend {
        let name: String
        let generate: @Sendable (PreparedCheck, String, Data) async throws -> String
        let stop: @Sendable () async -> Void

        static func open(_ selection: String?) async throws -> Backend {
            #if BUILT_IN_EVIDENCE_BENCHMARK
            guard let selection else { throw CocoaError(.fileNoSuchFile) }
            let file = URL(fileURLWithPath: selection)
            let engine = BuiltInEngine()
            return Backend(name: file.lastPathComponent, generate: { request, system, _ in
                try await engine.generate(system: system, user: request.userMessage, modelURL: file,
                                          evidenceOnly: request.evidenceOnly)
            }, stop: { await engine.unload() })
            #else
            let engine = OllamaEngine()
            let installed = try await engine.start()
            guard let model = (selection.flatMap { name in installed.first(where: { $0.name == name }) }
                               ?? (selection == nil ? installed.first : nil))?.name else {
                await engine.stop()
                throw OllamaError.noModels
            }
            return Backend(name: model, generate: { request, system, schema in
                try await engine.generate(system: system, user: request.userMessage, schema: schema, model: model)
            }, stop: { await engine.stop() })
            #endif
        }
    }

    static func main() async {
        do {
            let arguments = CommandLine.arguments.dropFirst()
            let path = arguments.first ?? "Tests/evidence-benchmark.json"
            let requestedModel = arguments.dropFirst().first(where: { !$0.hasPrefix("--") })
            let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let backend = try await Backend.open(requestedModel)
            #if BUILT_IN_EVIDENCE_BENCHMARK
            let coldCheckPassed = await checkColdStart(using: backend)
            #else
            let coldCheckPassed = true
            #endif
            print("Evaluating \(cases.count) cases with \(backend.name)")
            var passed = 0
            var expectationsMatched = 0
            var expectationsCount = 0
            var unsupportedOutcomes = 0
            var falseFlags = 0
            var controls = 0
            for fixture in cases {
                let citations = await review(fixture, with: backend)
                let actual = Set(citations.compactMap { citation in
                    citation.assessment.map { "\($0.dimension.rawValue): \(citation.label)" }
                })
                let expected = Set(fixture.expectations.map { "\($0.dimension): \($0.relation)" })
                let missed = expected.subtracting(actual)
                expectationsCount += expected.count
                expectationsMatched += expected.intersection(actual).count
                let isAccurate = fixture.expectations.allSatisfy { $0.relation == "Supports" }
                let falseFlag = isAccurate && citations.contains { ["Challenges", "Narrower scope"].contains($0.label) }
                let summary = EvidenceSynthesis.make(from: citations, reviewedSources: fixture.sources.count, failedSources: 0)
                let wrongConflict = fixture.expectedConflict.map { $0 != summary.hasConflict } ?? false
                if isAccurate { controls += 1 }
                if falseFlag { falseFlags += 1 }
                if citations.isEmpty { unsupportedOutcomes += 1 }
                if missed.isEmpty && !falseFlag && !wrongConflict {
                    passed += 1
                    print("PASS \(fixture.id)")
                } else {
                    print("MISS \(fixture.id) | expected \(expected.sorted().joined(separator: ", ")) | observed \(actual.sorted().joined(separator: ", "))\(falseFlag ? " | false flag on accurate claim" : "")\(wrongConflict ? " | incorrect conflict classification" : "")")
                }
            }
            await backend.stop()
            print("Cases matched: \(passed)/\(cases.count). Expected part judgments matched: \(expectationsMatched)/\(expectationsCount). Accurate controls flagged: \(falseFlags)/\(controls). No anchored evidence: \(unsupportedOutcomes).")
            if arguments.contains("--strict"), !coldCheckPassed || passed != cases.count { exit(1) }
        } catch {
            print("Evidence benchmark: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func checkColdStart(using backend: Backend) async -> Bool {
        let start = Date()
        do {
            let request = try PreparedCheck(excerpt: PreparedCheck.sampleExcerpt, context: PreparedCheck.sampleContext,
                                            rules: Rule.defaults)
            let response = try await backend.generate(request, PreparedCheck.systemMessage, PreparedCheck.schema)
            let result = try request.result(from: response)
            let seconds = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(2)))
            print("First local check finished in \(seconds) s (\(result.outcome.rawValue), \(result.findings.count) findings).")
            return true
        } catch {
            let seconds = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(2)))
            print("First local check failed after \(seconds) s. \(error.localizedDescription)")
            return false
        }
    }

    private static func review(_ fixture: Case, with backend: Backend) async -> [EvidenceCitation] {
        var citations: [EvidenceCitation] = []
        for source in fixture.sources {
            do {
                let request = try EvidenceReview.request(source: source.text, claim: fixture.claim)
                let response = try await backend.generate(request, EvidenceReview.systemMessage, EvidenceReview.schema)
                let result = try request.result(from: response)
                citations += EvidenceReview.citations(from: result, original: source.text, claim: fixture.claim, url: source.url,
                                                      title: source.title, date: nil)
            } catch {
                print("Source error \(fixture.id) | \(error.localizedDescription)")
            }
        }
        return citations
    }
}
