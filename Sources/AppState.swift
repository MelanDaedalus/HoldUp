import Combine
import Foundation

enum EngineChoice: String, CaseIterable, Identifiable {
    case builtIn, ollama

    var id: String { rawValue }
    var title: String { self == .builtIn ? "Built-in model" : "Ollama" }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", rules = "Rules", models = "Models", privacy = "Privacy", about = "About"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .rules: "checklist"
        case .models: "cpu"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
}

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    // Carbon values for kVK_ANSI_K, controlKey, optionKey, and cmdKey.
    static let standard = Shortcut(keyCode: 40, modifiers: 0x1900, label: "⌃⌥⌘K")
    static let clipboardDefault = Shortcut(keyCode: 38, modifiers: 0x1900, label: "⌃⌥⌘J")
}

enum CheckStatus: Equatable {
    case idle
    case notice(String)
    case checking
    case findings
    case noFlags
    case needsContext
    case failed(String)
    case cancelled
}

enum ModelWork: Equatable {
    case downloading(Int64)
    case verifying
    case connecting
    case removing
    case cancelling

    var label: String {
        switch self {
        case .downloading: "Downloading model…"
        case .verifying: "Verifying download…"
        case .connecting: "Starting local Ollama…"
        case .removing: "Removing model…"
        case .cancelling: "Cancelling…"
        }
    }
}

@MainActor final class AppState: ObservableObject {
    let store: ModelStore
    private let defaults: UserDefaults
    private let builtIn: BuiltInEngine
    private let ollama: OllamaEngine
    private let fetchPage: @Sendable (String) async throws -> EvidencePage
    private var checkTask: Task<Void, Never>?
    private var checkDrain: Task<Void, Never>?
    private var engineCleanup: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var checkID = UUID()
    private var modelID = UUID()

    @Published var rules: [Rule] { didSet { save(rules, as: "rules") } }
    @Published private(set) var engine: EngineChoice { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "model") } }
    @Published private(set) var ollamaModels: [OllamaModel] = []
    @Published private(set) var builtInInstalled: Bool
    @Published private(set) var modelWork: ModelWork?
    @Published private(set) var modelError: String?
    @Published private(set) var modelNote: String?
    @Published private(set) var welcomeCompleted: Bool
    @Published var section: SettingsSection = .general
    @Published var reviewDetail: ReviewDetail { didSet { defaults.set(reviewDetail.rawValue, forKey: "reviewDetail") } }

    @Published private(set) var shortcut: Shortcut { didSet { save(shortcut, as: "shortcut") } }
    @Published private(set) var clipboardShortcut: Shortcut { didSet { save(clipboardShortcut, as: "clipboardShortcut") } }
    @Published private(set) var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: "shortcutEnabled") } }
    @Published var shortcutError: String?
    @Published var recordingShortcut = false
    @Published var recordingClipboardShortcut = false
    @Published var canReadSelection = false

    @Published private(set) var excerpt = ""
    @Published private(set) var source = ""
    @Published var context = ""
    @Published var pastedText = ""
    @Published var contextExpanded = false
    @Published private(set) var checkStatus: CheckStatus = .idle
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var evidenceClaim: String?
    @Published private(set) var citations: [EvidenceCitation] = []
    @Published private(set) var citationTrail: [EvidenceTrail] = []
    @Published private var loadedArticle: EvidencePage?
    var loadedArticleURL: URL? { loadedArticle?.url }
    @Published private(set) var reviewedEvidenceCount = 0
    @Published private(set) var failedEvidenceCount = 0
    @Published private(set) var reviewedSuppliedContext = false

    var evidenceSummary: EvidenceSynthesis {
        EvidenceSynthesis.make(from: citations, reviewedSources: reviewedEvidenceCount, failedSources: failedEvidenceCount,
                               trails: citationTrail)
    }
    @Published private(set) var webStatus: String?
    @Published private(set) var webBusy = false

    init(defaults: UserDefaults = .standard, store: ModelStore = .standard,
         builtIn: BuiltInEngine = BuiltInEngine(), ollama: OllamaEngine = OllamaEngine(),
         fetchPage: @escaping @Sendable (String) async throws -> EvidencePage = EvidenceWeb.page) {
        self.defaults = defaults
        self.store = store
        self.builtIn = builtIn
        self.ollama = ollama
        self.fetchPage = fetchPage
        rules = Rule.saved(in: defaults)
        engine = defaults.string(forKey: "engine").flatMap(EngineChoice.init(rawValue:)) ?? .builtIn
        ollamaModel = defaults.string(forKey: "model") ?? ""
        builtInInstalled = store.isInstalled
        welcomeCompleted = defaults.bool(forKey: "welcomeCompleted")
        reviewDetail = defaults.string(forKey: "reviewDetail").flatMap(ReviewDetail.init(rawValue:)) ?? .balanced
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        clipboardShortcut = defaults.data(forKey: "clipboardShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .clipboardDefault
        shortcutEnabled = defaults.object(forKey: "shortcutEnabled") as? Bool ?? true
    }

    var isReady: Bool {
        switch engine {
        case .builtIn: builtInInstalled
        case .ollama: !ollamaModel.trimmed.isEmpty
        }
    }

    var engineLabel: String { engine == .builtIn ? store.asset.name : ollamaModel.isEmpty ? "Ollama" : ollamaModel }
    var needsSetup: Bool { welcomeCompleted == false }

    func finishWelcome() {
        guard isReady else { return }
        welcomeCompleted = true
        defaults.set(true, forKey: "welcomeCompleted")
    }

    func updateShortcut(_ value: Shortcut) {
        shortcut = value
        shortcutEnabled = true
        shortcutError = nil
    }

    func updateClipboardShortcut(_ value: Shortcut) {
        clipboardShortcut = value
        shortcutEnabled = true
        shortcutError = nil
    }

    func setShortcutEnabled(_ enabled: Bool) {
        shortcutEnabled = enabled
    }

    func selectEngine(_ choice: EngineChoice) {
        guard engine != choice, modelWork == nil else { return }
        if checkStatus == .checking { cancelCheck() }
        if webBusy { cancelWebWork() }
        let old = engine
        engine = choice
        modelError = nil
        modelNote = nil
        if old == .ollama {
            ollamaModels = []
        }
        let earlierCleanup = engineCleanup
        let drained = checkDrain
        engineCleanup = Task { [ollama, builtIn] in
            await earlierCleanup?.value
            await drained?.value
            switch old {
            case .builtIn: await builtIn.unload()
            case .ollama: await ollama.stop()
            }
        }
    }

    func downloadModel() {
        guard engine == .builtIn else { return }
        runModelWork(.downloading(0)) { id in
            try await self.store.download(progress: { [weak self] bytes in
                Task { @MainActor in
                    guard let self, self.modelID == id, case .downloading = self.modelWork else { return }
                    self.modelWork = .downloading(bytes)
                }
            }, verifying: { [weak self] in
                Task { @MainActor in
                    guard let self, self.modelID == id, case .downloading = self.modelWork else { return }
                    self.modelWork = .verifying
                }
            })
        }
    }

    func connectOllama() {
        guard engine == .ollama else { return }
        runModelWork(.connecting) { _ in
            self.ollamaModels = []
            let models = try await self.ollama.start()
            if Task.isCancelled {
                await self.ollama.stop()
                throw CancellationError()
            }
            self.ollamaModels = models
            if !models.contains(where: { $0.name == self.ollamaModel }) {
                self.ollamaModel = models.count == 1 ? models[0].name : ""
            }
        }
    }

    func removeBuiltIn() {
        runModelWork(.removing) { _ in
            await self.builtIn.unload()
            try Task.checkCancellation()
            try self.store.remove()
            self.builtInInstalled = false
        }
    }

    func cancelModelWork() {
        guard modelTask != nil else { return }
        modelWork = .cancelling
        modelTask?.cancel()
    }

    func present(text: String?, source: String, missing: String = "Highlight or paste a passage to check.",
                 extraContext: String = "") {
        closePanel()
        self.source = source
        excerpt = text?.trimmed ?? ""
        context = extraContext
        guard !excerpt.isEmpty else {
            checkStatus = .notice(missing)
            return
        }
        checkAgain()
    }

    func presentSample() {
        present(text: PreparedCheck.sampleExcerpt, source: "Sample passage", extraContext: PreparedCheck.sampleContext)
    }

    func checkPasted() {
        guard !pastedText.trimmed.isEmpty else { return }
        present(text: pastedText, source: "Pasted text")
    }

    func openEvidence(for quote: String? = nil) {
        guard !excerpt.isEmpty, checkStatus != .checking else { return }
        cancelCheckTask()
        resetEvidenceResults()
        webStatus = nil
        evidenceClaim = quote.map { EvidenceReview.claim(in: excerpt, around: $0) } ?? excerpt
    }

    func closeEvidence() {
        cancelCheckTask()
        evidenceClaim = nil
        resetEvidenceResults()
        webStatus = nil
    }

    func cancelWebWork() {
        cancelCheckTask()
        webStatus = "Cancelled."
    }

    func loadPageContext(_ address: String) {
        guard !excerpt.isEmpty else { return }
        let claim = excerpt
        runWebWork("Reading public page…") { id in
            let page = try await self.fetchPage(address)
            guard id == self.checkID, !Task.isCancelled else { return }
            let heading = "Page: " + page.url.absoluteString + "\n" +
                "Title: " + String(page.title.prefix(200)) + "\n\n"
            let available = PreparedCheck.contextLimit - self.context.count - heading.count - 2
            guard available >= 160 else {
                self.webStatus = "Make room in the context field before adding another page."
                return
            }
            let passages = ReadingContext.surrounding(claim, in: page.text, limit: available) ??
                EvidenceReview.relevantPassages(in: page.text, for: claim, limit: available)
            if !self.context.isEmpty { self.context += "\n\n" }
            self.context += heading + passages
            self.loadedArticle = page
            self.webStatus = "Page text added. Review it before using it as context."
        }
    }

    func reviewContext() {
        guard !context.trimmed.isEmpty, isReady, modelWork == nil, !webBusy, checkStatus != .checking else { return }
        if evidenceClaim == nil { openEvidence() }
        guard let claim = evidenceClaim else { return }
        guard claim.count <= PreparedCheck.excerptLimit else {
            webStatus = CheckError.excerptTooLong.localizedDescription
            return
        }
        let supplied = context
        let selectedEngine = engine
        let selectedModel = ollamaModel
        resetEvidenceResults()
        reviewedSuppliedContext = true
        runWebWork("Comparing the claim with your context locally…") { id in
            do {
                let request = try EvidenceReview.request(source: supplied, claim: claim)
                let result = try await self.evaluate(request, with: selectedEngine, model: selectedModel,
                                                     system: EvidenceReview.systemMessage, schema: EvidenceReview.schema)
                guard id == self.checkID, !Task.isCancelled else { return }
                let matches = EvidenceReview.citations(from: result, original: supplied, claim: claim,
                                                       url: nil, title: "Supplied context", date: nil)
                guard result.outcome != .findings || !matches.isEmpty else { throw CheckError.invalidResponse }
                self.citations = matches
                self.reviewedEvidenceCount = 1
                self.webStatus = nil
            } catch {
                if id == self.checkID, !Task.isCancelled { self.failedEvidenceCount = 1 }
                throw error
            }
        }
    }

    func reviewLoadedArticle(for quote: String? = nil) {
        guard let article = loadedArticle, isReady, modelWork == nil, !webBusy, checkStatus != .checking else { return }
        if evidenceClaim == nil || quote != nil { openEvidence(for: quote) }
        findEvidence(addresses: [article.url.absoluteString], cachedArticle: article)
    }

    func findEvidence(addresses: [String], cachedArticle: EvidencePage? = nil) {
        guard let claim = evidenceClaim, isReady, modelWork == nil, !webBusy, checkStatus != .checking,
              (1...3).contains(addresses.count) else { return }
        guard claim.count <= PreparedCheck.excerptLimit else {
            webStatus = CheckError.excerptTooLong.localizedDescription
            return
        }
        let sources = EvidenceWeb.uniqueSources(addresses)
        let selectedEngine = engine
        let selectedModel = ollamaModel
        resetEvidenceResults()
        runWebWork(cachedArticle == nil ? "Reading public sources…" : "Reviewing the article locally…") { id in
            var failed = 0
            var firstError: String?
            var pages: [EvidencePage] = []
            var completed: [String: (url: URL, title: String, status: EvidenceTrail.Status)] = [:]
            for address in sources {
                guard id == self.checkID, !Task.isCancelled else { return }
                do {
                    let requestedURL = try EvidenceWeb.checkedURL(address)
                    let requestedKey = EvidenceWeb.sourceIdentity(requestedURL)
                    let page: EvidencePage
                    if let cachedArticle, EvidenceWeb.sourceIdentity(cachedArticle.url) == requestedKey {
                        page = cachedArticle
                    } else {
                        page = try await self.fetchPage(address)
                    }
                    guard id == self.checkID, !Task.isCancelled else { return }
                    let finalKey = EvidenceWeb.sourceIdentity(page.url)
                    if let previous = completed[finalKey] {
                        completed[requestedKey] = previous
                        continue
                    }
                    pages.append(page)
                    self.webStatus = "Reviewing source passages locally…"
                    let matches = try await self.reviewPage(page, claim: claim, engine: selectedEngine, model: selectedModel)
                    guard id == self.checkID, !Task.isCancelled else { return }
                    self.appendEvidence(matches)
                    let reviewed = (page.url, page.title, matches.isEmpty ? EvidenceTrail.Status.noMatch : .reviewed)
                    completed[finalKey] = reviewed
                    completed[requestedKey] = reviewed
                    self.reviewedEvidenceCount += 1
                } catch {
                    try Task.checkCancellation()
                    failed += 1
                    if firstError == nil { firstError = error.localizedDescription }
                    if let url = try? EvidenceWeb.checkedURL(address) {
                        completed[EvidenceWeb.sourceIdentity(url)] = (url, url.host() ?? address, .unavailable)
                    }
                }
            }

            var additionalFetches = 0
            let linksByPage = pages.map { page in (page, EvidenceWeb.citationCandidates(in: page, for: claim)) }
            for rank in 0..<3 {
                for (page, references) in linksByPage where rank < references.count {
                    guard id == self.checkID, !Task.isCancelled else { return }
                    let reference = references[rank]
                    let key = EvidenceWeb.sourceIdentity(reference.url)
                    if completed[key] == nil, additionalFetches < 2 {
                        additionalFetches += 1
                        self.webStatus = "Following a cited source…"
                        do {
                            let cited = try await self.fetchPage(reference.url.absoluteString)
                            guard id == self.checkID, !Task.isCancelled else { return }
                            let finalKey = EvidenceWeb.sourceIdentity(cited.url)
                            if let previous = completed[finalKey] {
                                completed[key] = previous
                            } else {
                                let matches = try await self.reviewPage(cited, claim: claim, engine: selectedEngine, model: selectedModel)
                                guard id == self.checkID, !Task.isCancelled else { return }
                                self.appendEvidence(matches)
                                let reviewed = (cited.url, cited.title, matches.isEmpty ? EvidenceTrail.Status.noMatch : .reviewed)
                                completed[finalKey] = reviewed
                                completed[key] = reviewed
                                self.reviewedEvidenceCount += 1
                            }
                        } catch {
                            try Task.checkCancellation()
                            completed[key] = (reference.url, reference.title, .unavailable)
                            failed += 1
                            if firstError == nil { firstError = error.localizedDescription }
                        }
                    }
                    if let source = completed[key], EvidenceWeb.sourceIdentity(page.url) != EvidenceWeb.sourceIdentity(source.url) {
                        let trail = EvidenceTrail(articleURL: page.url, articleTitle: page.title, sourceURL: source.url,
                                                  sourceTitle: source.title, status: source.status)
                        if !self.citationTrail.contains(where: { $0.id == trail.id }) { self.citationTrail.append(trail) }
                    }
                }
            }
            self.failedEvidenceCount = failed
            if self.reviewedEvidenceCount == 0, failed > 0 {
                self.webStatus = firstError ?? "The sources could not be reviewed."
            } else {
                self.webStatus = nil
            }
        }
    }

    private func resetEvidenceResults() {
        citations = []
        citationTrail = []
        reviewedEvidenceCount = 0
        failedEvidenceCount = 0
        reviewedSuppliedContext = false
    }

    private func reviewPage(_ page: EvidencePage, claim: String, engine: EngineChoice, model: String) async throws -> [EvidenceCitation] {
        let request = try EvidenceReview.request(source: page.text, claim: claim)
        let result = try await evaluate(request, with: engine, model: model, system: EvidenceReview.systemMessage,
                                        schema: EvidenceReview.schema)
        let matches = EvidenceReview.citations(from: result, original: page.text, claim: claim, url: page.url,
                                               title: page.title, date: page.publishedDate)
        guard result.outcome != .findings || !matches.isEmpty else { throw CheckError.invalidResponse }
        return matches
    }

    private func appendEvidence(_ matches: [EvidenceCitation]) {
        for match in matches where !citations.contains(where: { $0.id == match.id }) { citations.append(match) }
    }

    private func runWebWork(_ message: String, operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard !webBusy, checkStatus != .checking, modelWork == nil else { return }
        cancelCheckTask()
        let id = checkID
        let previous = checkDrain
        let cleanup = engineCleanup
        webBusy = true
        webStatus = message
        checkTask = Task { [weak self] in
            await previous?.value
            await cleanup?.value
            guard let self, !Task.isCancelled, id == self.checkID else { return }
            self.checkDrain = nil
            do { try await operation(id) }
            catch {
                guard id == self.checkID, !Task.isCancelled else { return }
                self.webStatus = error.localizedDescription
            }
            guard id == self.checkID else { return }
            self.webBusy = false
            self.checkTask = nil
        }
    }

    func checkAgain() {
        cancelCheckTask()
        webStatus = nil
        findings = []
        guard isReady, modelWork == nil else {
            checkStatus = .notice("Finish model setup to run this check.")
            return
        }
        let request: PreparedCheck
        do { request = try PreparedCheck(excerpt: excerpt, context: context, rules: rules) }
        catch {
            checkStatus = .failed(error.localizedDescription)
            return
        }

        let id = checkID
        let selectedEngine = engine
        let selectedModel = ollamaModel
        let previousCheck = checkDrain
        let cleanup = engineCleanup
        checkStatus = .checking
        checkTask = Task { [weak self] in
            guard let self else { return }
            await previousCheck?.value
            await cleanup?.value
            guard !Task.isCancelled, id == self.checkID else { return }
            self.checkDrain = nil
            do {
                let result = try await self.evaluate(request, with: selectedEngine, model: selectedModel)
                guard !Task.isCancelled, id == self.checkID else { return }
                self.findings = result.findings
                switch result.outcome {
                case .findings: self.checkStatus = .findings
                case .noFlags: self.checkStatus = .noFlags
                case .needsContext: self.checkStatus = .needsContext
                }
            } catch {
                guard !Task.isCancelled, id == self.checkID else { return }
                self.checkStatus = .failed(error.localizedDescription)
            }
            guard id == self.checkID else { return }
            self.checkTask = nil
        }
    }

    func cancelCheck() {
        cancelCheckTask()
        checkStatus = .cancelled
    }

    func closePanel() {
        closeEvidence()
        loadedArticle = nil
        excerpt = ""
        source = ""
        context = ""
        pastedText = ""
        contextExpanded = false
        findings = []
        checkStatus = .idle
    }

    func shutdown() async {
        closePanel()
        let work = modelTask
        work?.cancel()
        await checkDrain?.value
        await engineCleanup?.value
        await ollama.stop()
        await work?.value
    }

    private func evaluate(_ request: PreparedCheck, with choice: EngineChoice, model: String,
                          system: String = PreparedCheck.systemMessage, schema: Data = PreparedCheck.schema) async throws -> CheckResult {
        let response: String
        switch choice {
        case .builtIn:
            response = try await builtIn.generate(system: system,
                                                  user: request.userMessage, modelURL: store.fileURL, evidenceOnly: request.evidenceOnly)
        case .ollama:
            response = try await ollama.generate(system: system, user: request.userMessage,
                                                  schema: schema, model: model)
        }
        try Task.checkCancellation()
        return try request.result(from: response)
    }

    private func runModelWork(_ work: ModelWork, operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard modelTask == nil else { return }
        if checkStatus == .checking { cancelCheck() }
        if webBusy { cancelWebWork() }
        modelID = UUID()
        let id = modelID
        modelWork = work
        modelError = nil
        modelNote = nil
        let previousCheck = checkDrain
        let cleanup = engineCleanup
        modelTask = Task { [weak self] in
            guard let self else { return }
            await previousCheck?.value
            await cleanup?.value
            do {
                try Task.checkCancellation()
                try await operation(id)
            }
            catch {
                if Task.isCancelled {
                    self.modelNote = "Cancelled."
                } else {
                    self.modelError = error.localizedDescription
                }
            }
            self.builtInInstalled = self.store.isInstalled
            self.modelID = UUID()
            self.modelTask = nil
            self.modelWork = nil
        }
    }

    private func cancelCheckTask() {
        webBusy = false
        checkID = UUID()
        if let checkTask {
            checkTask.cancel()
            checkDrain = checkTask
        }
        checkTask = nil
    }

    private func save<Value: Encodable>(_ value: Value, as key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
