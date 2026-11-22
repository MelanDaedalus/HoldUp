import Foundation

actor BuiltInEngine {
    private var active = false
    private(set) var started = 0

    func generate(system: String, user: String, modelURL: URL, evidenceOnly: Bool = false) async throws -> String {
        guard !active else { throw CocoaError(.executableLoad) }
        active = true
        started += 1
        defer { active = false }
        if user.contains("Late") {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { resume.resume() }
            }
        }
        if system == EvidenceReview.systemMessage, user.contains("Route 6 only") {
            return #"""
            {"outcome":"findings","findings":[{"ruleID":"r2","quote":"Route 6 only","reason":"The result applies to one route. The citywide effect remains uncertain.","verify":"Narrower scope","evidence":{"claimQuote":"citywide","measure":"","group":"Route 6 only","period":""}}]}
            """#
        }
        return #"{"outcome":"no_flags","findings":[]}"#
    }
    func unload() {}
}

struct OllamaModel: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let size: Int64?
}

actor OllamaEngine {
    static let applicationURL: URL? = nil
    private(set) var requests: [(model: String, text: String)] = []
    func start() async throws -> [OllamaModel] { [OllamaModel(name: "fixture:latest", size: nil)] }
    func generate(system: String, user: String, schema: Data, model: String) async throws -> String {
        requests.append((model, user))
        if model == "bad:latest" { return "a response the app cannot read" }
        return #"{"outcome":"no_flags","findings":[]}"#
    }
    func stop() {}
}

@main struct StateTests {
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "local.claimcheck.test.\(UUID().uuidString)")!
        let asset = ModelAsset(name: "Test", filename: "fixture.gguf", bytes: 5,
                               sha256: "unused", downloadURL: URL(string: "https://example.com/fixture")!)
        let store = ModelStore(folder: folder, asset: asset)
        try Data("hello".utf8).write(to: store.fileURL)
        let engine = BuiltInEngine()
        let state = AppState(defaults: defaults, store: store, builtIn: engine)
        precondition(state.isReady)
        state.present(text: "Late answer.", source: "Fixture")
        for _ in 0..<50 {
            if await engine.started > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        state.closePanel()
        try await Task.sleep(for: .milliseconds(60))
        precondition(state.excerpt.isEmpty && state.context.isEmpty)
        precondition(state.checkStatus == .idle)
        state.present(text: "New answer.", source: "Fixture")
        for _ in 0..<50 where state.checkStatus == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard state.checkStatus == .noFlags && state.excerpt == "New answer." else {
            print("The replacement check collided with a previous inference that was cancelling.")
            exit(1)
        }
        let cancelledPassage = "Late answer to cancel and retry."
        let savedContext = "Keep this context for the retry."
        state.present(text: cancelledPassage, source: "Fixture", extraContext: savedContext)
        state.cancelCheck()
        precondition(state.checkStatus == .cancelled && state.excerpt == cancelledPassage && state.context == savedContext)
        state.checkAgain()
        for _ in 0..<100 where state.checkStatus == .checking { try await Task.sleep(for: .milliseconds(10)) }
        precondition(state.checkStatus == .noFlags && state.excerpt == cancelledPassage && state.context == savedContext)
        state.context = "Route 6 only."
        state.checkAgain()
        for _ in 0..<50 where state.checkStatus == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(state.context == "Route 6 only." && state.checkStatus == .noFlags)
        state.pastedText = "A separate passage."
        state.checkPasted()
        precondition(state.excerpt == "A separate passage.")
        precondition(state.context.isEmpty && state.pastedText.isEmpty)
        state.closePanel()
        state.present(text: "Travel times fell 40% citywide.", source: "Fixture",
                      extraContext: "The pilot measured Route 6 only.")
        for _ in 0..<50 where state.checkStatus == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        state.reviewContext()
        for _ in 0..<50 where state.webBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(state.reviewedSuppliedContext && state.reviewedEvidenceCount == 1)
        precondition(state.citations.first?.quote == "Route 6 only" && state.citations.first?.url == nil)
        state.closePanel()
        precondition(state.citations.isEmpty && !state.reviewedSuppliedContext)
        try await reviewsOneReportLinkedByTwoArticles(defaults: defaults, store: store)
        try await reviewsLoadedArticleWithoutFetchingItAgain(defaults: defaults, store: store)
        try await checksDirectlyWithSavedAndChangedOllamaModels(defaults: defaults, store: store)
        print("App state tests passed: local readiness, late-result cancellation, repeat checking, and local context evidence")
    }

    @MainActor private static func reviewsLoadedArticleWithoutFetchingItAgain(defaults: UserDefaults, store: ModelStore) async throws {
        let article = URL(string: "https://example.com/transit")!
        let other = URL(string: "https://example.org/transit")!
        let report = URL(string: "https://example.net/route-study.pdf")!
        let fetcher = FixturePages(first: article, second: other, original: report)
        let state = AppState(defaults: defaults, store: store, fetchPage: { try await fetcher.page($0) })
        state.present(text: "Bus travel times fell by 40% citywide.", source: "Fixture")
        for _ in 0..<100 where state.checkStatus == .checking { try await Task.sleep(for: .milliseconds(10)) }
        state.loadPageContext(article.absoluteString)
        for _ in 0..<100 where state.webBusy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(state.loadedArticleURL == article && state.evidenceClaim == nil)
        state.reviewLoadedArticle()
        for _ in 0..<100 where state.webBusy { try await Task.sleep(for: .milliseconds(10)) }
        let requests = await fetcher.requests
        precondition(requests == [article, report] && state.reviewedEvidenceCount == 2)
        precondition(state.evidenceClaim == state.excerpt && state.evidenceSummary.lead?.url == report)
    }

    @MainActor private static func checksDirectlyWithSavedAndChangedOllamaModels(defaults: UserDefaults, store: ModelStore) async throws {
        defaults.set("ollama", forKey: "engine")
        defaults.set("fixture:latest", forKey: "model")
        let engine = OllamaEngine()
        let state = AppState(defaults: defaults, store: store, ollama: engine)
        precondition(state.ollamaModels.isEmpty)
        state.present(text: "My first real check.", source: "Fixture")
        for _ in 0..<100 where state.checkStatus == .checking { try await Task.sleep(for: .milliseconds(10)) }
        precondition(state.checkStatus == .noFlags)
        let initial = await engine.requests
        precondition(initial.count == 1 && initial[0].model == "fixture:latest" && initial[0].text.contains("My first real check."))

        state.ollamaModel = "bad:latest"
        state.checkAgain()
        for _ in 0..<100 where state.checkStatus == .checking { try await Task.sleep(for: .milliseconds(10)) }
        precondition(state.checkStatus == .failed(CheckError.invalidResponse.localizedDescription))

        state.ollamaModel = "different:latest"
        state.checkAgain()
        for _ in 0..<100 where state.checkStatus == .checking { try await Task.sleep(for: .milliseconds(10)) }
        let requests = await engine.requests
        precondition(state.checkStatus == .noFlags && requests.map(\.model) == ["fixture:latest", "bad:latest", "different:latest"])

        state.ollamaModel = ""
        state.connectOllama()
        for _ in 0..<100 where state.modelWork != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(state.ollamaModel == "fixture:latest" && state.isReady)
        let requestsAfterDiscovery = await engine.requests
        precondition(requestsAfterDiscovery.count == requests.count)
    }

    @MainActor private static func reviewsOneReportLinkedByTwoArticles(defaults: UserDefaults, store: ModelStore) async throws {
        let first = URL(string: "https://example.com/transit")!
        let second = URL(string: "https://example.org/transit")!
        let original = URL(string: "https://example.net/route-study.pdf")!
        let fetcher = FixturePages(first: first, second: second, original: original)
        let state = AppState(defaults: defaults, store: store, fetchPage: { try await fetcher.page($0) })
        state.present(text: "Bus travel times fell by 40% citywide.", source: "Fixture")
        for _ in 0..<100 where state.checkStatus == .checking { try await Task.sleep(for: .milliseconds(10)) }
        state.openEvidence()
        state.findEvidence(addresses: [first.absoluteString, second.absoluteString])
        for _ in 0..<100 where state.webBusy { try await Task.sleep(for: .milliseconds(10)) }
        let requests = await fetcher.requests
        precondition(requests == [first, second, original])
        precondition(state.reviewedEvidenceCount == 3 && state.failedEvidenceCount == 0)
        precondition(state.citations.count == 1 && state.citations.first?.url == original)
        precondition(Set(state.citationTrail.map(\.articleURL)) == Set([first, second]))
        precondition(state.citationTrail.allSatisfy { $0.sourceURL == original && $0.status == .reviewed })
        state.closeEvidence()
        precondition(state.citationTrail.isEmpty && state.citations.isEmpty)
    }
}

private actor FixturePages {
    let first: URL
    let second: URL
    let original: URL
    private(set) var requests: [URL] = []

    init(first: URL, second: URL, original: URL) {
        self.first = first
        self.second = second
        self.original = original
    }

    func page(_ address: String) throws -> EvidencePage {
        let url = try EvidenceWeb.checkedURL(address)
        requests.append(url)
        if url == original {
            return EvidencePage(url: url, title: "Transit report", text: "Travel times were measured on Route 6 only.", publishedDate: nil)
        }
        guard url == first || url == second else { throw CheckError.invalidResponse }
        let reference = EvidenceReference(url: original, title: "Bus travel times pilot report",
                                          context: "The pilot report measured bus travel times on local routes.")
        return EvidencePage(url: url, title: "Transit article", text: "The transit agency released its pilot data.",
                            publishedDate: nil, references: [reference])
    }
}
