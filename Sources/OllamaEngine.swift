import CryptoKit
import Darwin
import Foundation
import Metal
import Network
import Security

struct OllamaModel: Identifiable, Hashable, Sendable {
    let name: String
    let size: Int64?

    var id: String { name }
}

enum OllamaError: LocalizedError, Equatable {
    case missingApplication
    case unverifiedApplication
    case modelStore
    case serverStart
    case serverUnavailable
    case cloudUnverified
    case noModels
    case modelMetadata
    case modelNotSelected
    case modelLoad
    case generation

    var errorDescription: String? {
        switch self {
        case .missingApplication: "Install Ollama for macOS to use its local models."
        case .unverifiedApplication: "Hold UP could not verify this Ollama installation. Install the official Ollama app and try again."
        case .modelStore: "Hold UP could not read Ollama’s installed models. Check the model folder and try again."
        case .serverStart: "The private Ollama session could not start. Try again or switch to the built-in model."
        case .serverUnavailable: "The private Ollama session is unavailable. Reconnect Ollama and try again."
        case .cloudUnverified: "Hold UP could not confirm that Ollama cloud is disabled. Update the official Ollama app and reconnect."
        case .noModels: "No compatible local text models were found. Finish installing a local text model in Ollama, then refresh this list."
        case .modelMetadata: "Hold UP could not verify the model’s local text generation capabilities. Refresh the model list or choose another local model."
        case .modelNotSelected: "Choose an installed local model in Settings before checking text."
        case .modelLoad: "Ollama could not load this model. Try a smaller local model or free up memory."
        case .generation: "Ollama did not complete the review. Try again or choose a different local model."
        }
    }
}

actor OllamaEngine {
    private var server: OwnedOllamaServer?
    private var client: OllamaClient?
    private var modelNames: Set<String> = []
    private var inProgress: (id: UUID, task: Task<String, Error>)?
    private let storeOverride: URL?

    init() { storeOverride = nil }

    #if OLLAMA_TESTS
    init(modelStore: URL) { storeOverride = modelStore }
    #endif

    static var applicationURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [URL(fileURLWithPath: "/Applications/Ollama.app", isDirectory: true), home.appendingPathComponent("Applications/Ollama.app", isDirectory: true)]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/Resources/ollama").path) }
    }

    func start() async throws -> [OllamaModel] {
        try Task.checkCancellation()
        disconnect()

        guard let app = Self.applicationURL else { throw OllamaError.missingApplication }
        let executable = app.appendingPathComponent("Contents/Resources/ollama")
        guard Self.isOfficialCode(app, identifier: "com.electron.ollama"),
              Self.isOfficialCode(executable, identifier: "ai.ollama.ollama") else {
            throw OllamaError.unverifiedApplication
        }

        let process = try OwnedOllamaServer(executable: executable, modelStore: storeOverride ?? Self.modelStore)
        server = process
        do {
            let local = try await process.waitForLoopback()
            let models = try await local.listModels()
            try Task.checkCancellation()
            guard server === process else { throw CancellationError() }
            client = local
            modelNames = Set(models.map(\.name))
            return models
        } catch {
            if server === process { disconnect() }
            throw error
        }
    }

    func generate(system: String, user: String, schema: Data, model: String) async throws -> String {
        try Task.checkCancellation()
        guard !model.isEmpty else { throw OllamaError.modelNotSelected }
        if client == nil || server?.isRunning != true {
            _ = try await start()
            try Task.checkCancellation()
        }
        guard let client, server?.isRunning == true else { throw OllamaError.serverUnavailable }
        guard modelNames.contains(model) else { throw OllamaError.modelNotSelected }

        inProgress?.task.cancel()
        let id = UUID()
        let task = Task {
            try await client.generate(system: system, user: user, schema: schema, model: model)
        }
        inProgress = (id, task)
        defer {
            if inProgress?.id == id { inProgress = nil }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() async {
        let previous = server
        disconnect()
        await previous?.waitForExit()
    }

    private func disconnect() {
        inProgress?.task.cancel()
        inProgress = nil
        client = nil
        modelNames = []
        server?.stop()
        server = nil
    }

    deinit {
        inProgress?.task.cancel()
        server?.stop()
    }

    private static var modelStore: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let path = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent(".ollama/models", isDirectory: true)
    }

    private static func isOfficialCode(_ url: URL, identifier: String) -> Bool {
        let requirement = """
            anchor apple generic and identifier "\(identifier)" and
            certificate 1[field.1.2.840.113635.100.6.2.6] and
            certificate leaf[field.1.2.840.113635.100.6.1.13] and
            certificate leaf[subject.OU] = "3MU9H2V9Y9"
            """
        var expected: SecRequirement?
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let expected, let code else { return false }
        return SecStaticCodeCheckValidity(code, flags, expected) == errSecSuccess
    }
}

private final class OwnedOllamaServer: Sendable {
    private let process: Process
    private let directory: URL
    private let cpuOnly: Bool
    private let startup = StartupOutput()

    var isRunning: Bool { process.isRunning }

    init(executable: URL, modelStore: URL) throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("ClaimCheckOllama-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        cpuOnly = MTLCreateSystemDefaultDevice()?.makeCommandQueue() == nil
        let models = directory.appendingPathComponent("models", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try snapshotOllamaStore(from: modelStore, to: models)
        } catch {
            try? fm.removeItem(at: directory)
            if error is CancellationError { throw error }
            throw OllamaError.modelStore
        }

        let output = Pipe()
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { [startup] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                startup.append(data)
            }
        }

        process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.currentDirectoryURL = directory
        var environment = [
            "HOME": directory.path,
            "TMPDIR": directory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "NO_PROXY": "*",
            "OLLAMA_HOST": "127.0.0.1:0",
            "OLLAMA_MODELS": models.path,
            "OLLAMA_NO_CLOUD": "1",
            "OLLAMA_NOPRUNE": "1",
            "OLLAMA_DEBUG_LOG_REQUESTS": "0",
            "OLLAMA_NUM_PARALLEL": "1",
            "OLLAMA_MAX_LOADED_MODELS": "1"
        ]
        if cpuOnly { environment["LLAMA_ARG_DEVICE"] = "none" }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        process.terminationHandler = { _ in
            reader.readabilityHandler = nil
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            try? fm.removeItem(at: directory)
            throw OllamaError.serverStart
        }
    }

    func waitForLoopback() async throws -> OllamaClient {
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw OllamaError.serverStart }
            if let port = startup.port {
                let local = OllamaClient(port: port, cpuOnly: cpuOnly) { [process] request in
                    guard process.isRunning else { throw OllamaError.serverUnavailable }
                    // The request owns its session. Stopping the child never
                    // invalidates a session another task may be about to use.
                    let session = OllamaClient.privateSession()
                    defer { session.finishTasksAndInvalidate() }
                    return try await session.data(for: request)
                }
                do {
                    try await local.verifyCloud()
                    return local
                } catch OllamaError.serverUnavailable {
                    // The listener is announced before Ollama finishes discovering the GPU.
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw OllamaError.serverStart
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    func waitForExit() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !process.isRunning { try? FileManager.default.removeItem(at: directory) }
    }
}

private final class StartupOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var parsedPort: UInt16?

    var port: UInt16? { lock.withLock { parsedPort } }

    func append(_ data: Data) {
        lock.withLock {
            guard parsedPort == nil else { return }
            buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                guard let marker = line.range(of: "Listening on 127.0.0.1:"),
                      let port = UInt16(line[marker.upperBound...].prefix(while: \.isNumber)),
                      port != 0 else { continue }
                parsedPort = port
                buffer.removeAll()
                return
            }
            if buffer.count > 32_768 { buffer.removeAll() }
        }
    }
}

struct OllamaClient: Sendable {
    let port: UInt16
    let cpuOnly: Bool
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(port: UInt16, cpuOnly: Bool = false, transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.port = port
        self.cpuOnly = cpuOnly
        self.transport = transport
    }

    private struct CloudStatus: Decodable {
        struct State: Decodable {
            let disabled: Bool
            let source: String
        }

        let cloud: State
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable {
            let name: String
            let model: String
            let size: Int64?
            let remoteHost: String?
            let remoteModel: String?
        }

        let models: [Entry]
    }

    private struct ModelMetadata: Decodable {
        struct Details: Decodable { let format: String }
        struct Info: Decodable {
            let architecture: String?

            enum CodingKeys: String, CodingKey { case architecture = "general.architecture" }
        }

        let details: Details?
        let modelInfo: Info?
        let capabilities: [String]?
        let remoteHost: String?
        let remoteModel: String?
    }

    private struct GenerateReply: Decodable {
        let model: String
        let done: Bool
        let doneReason: String?
        let response: String
        let remoteHost: String?
        let remoteModel: String?
    }

    static func privateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": false, "HTTPSEnable": false, "SOCKSEnable": false,
            "ProxyAutoConfigEnable": false, "ProxyAutoDiscoveryEnable": false
        ]
        configuration.proxyConfigurations = []
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForResource = 200
        return URLSession(configuration: configuration, delegate: DirectLoopbackDelegate(), delegateQueue: nil)
    }

    func verifyCloud() async throws {
        let status: CloudStatus = try await request("/api/status", timeout: 2, failure: .cloudUnverified)
        guard status.cloud.disabled, ["env", "both"].contains(status.cloud.source) else {
            throw OllamaError.cloudUnverified
        }
    }

    func listModels() async throws -> [OllamaModel] {
        try await verifyCloud()
        let listing: ModelList = try await request("/api/tags", failure: .modelMetadata)
        var models = [OllamaModel]()
        var visited = Set<String>()
        var metadataFailed = false

        for item in listing.models {
            guard item.name == item.model, Self.isOrdinaryName(item.name),
                  !Self.isRemote(host: item.remoteHost, model: item.remoteModel),
                  visited.insert(item.name).inserted else { continue }
            do {
                if try await supportsCompletion(item.name) {
                    models.append(OllamaModel(name: item.name, size: item.size.flatMap { $0 > 0 ? $0 : nil }))
                }
            } catch OllamaError.modelMetadata {
                metadataFailed = true
            }
        }

        guard !models.isEmpty else { throw metadataFailed ? OllamaError.modelMetadata : .noModels }
        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func generate(system: String, user: String, schema: Data, model: String) async throws -> String {
        guard Self.isOrdinaryName(model) else { throw OllamaError.modelMetadata }
        try await verifyCloud()
        guard try await supportsCompletion(model) else { throw OllamaError.modelMetadata }
        guard let format = try? JSONSerialization.jsonObject(with: schema) as? [String: Any] else {
            throw OllamaError.generation
        }

        let local = model + ":local"
        // Ask Ollama to load the verified model before sending the review prompts.
        var options: [String: Any] = ["num_ctx": 8_192, "num_predict": 1_600, "temperature": 0.1]
        if cpuOnly { options["num_gpu"] = 0 }
        let load = try JSONSerialization.data(withJSONObject: ["model": local, "stream": false, "keep_alive": "2m", "options": options])
        let loaded: GenerateReply = try await request("/api/generate", body: load, timeout: 180, failure: .modelLoad)
        guard loaded.done, loaded.doneReason == "load", loaded.model == local,
              !Self.isRemote(host: loaded.remoteHost, model: loaded.remoteModel) else { throw OllamaError.modelLoad }

        let payload = try JSONSerialization.data(withJSONObject: [
            "model": local, "system": system, "prompt": user, "format": format, "think": false,
            "stream": false, "keep_alive": "2m", "truncate": false, "shift": false, "options": options
        ])
        let result: GenerateReply = try await request("/api/generate", body: payload, timeout: 180, failure: .generation)
        guard result.done, result.doneReason == "stop", result.model == local,
              !Self.isRemote(host: result.remoteHost, model: result.remoteModel),
              !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OllamaError.generation }
        return result.response
    }

    private func supportsCompletion(_ name: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["model": name + ":local"])
        let model: ModelMetadata = try await request("/api/show", body: body, timeout: 15, failure: .modelMetadata)
        guard !Self.isRemote(host: model.remoteHost, model: model.remoteModel) else { return false }
        guard let capabilities = model.capabilities else { throw OllamaError.modelMetadata }
        guard capabilities.contains("completion"), !capabilities.contains("image") else { return false }
        guard let format = model.details?.format,
              let architecture = model.modelInfo?.architecture,
              !format.isEmpty, !architecture.isEmpty else { throw OllamaError.modelMetadata }
        return ["gguf", "safetensors"].contains(format)
    }

    private static func isOrdinaryName(_ name: String) -> Bool {
        let pattern = #"^(?:[A-Za-z0-9][A-Za-z0-9_.-]*(?::[0-9]{1,5})?/)?(?:[A-Za-z0-9][A-Za-z0-9_.-]*/)?[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$"#
        guard name.utf8.count <= 512, name.range(of: pattern, options: .regularExpression) == name.startIndex..<name.endIndex,
              let component = name.split(separator: "/").last else { return false }
        let parts = component.lowercased().split(separator: ":")
        guard parts.count == 2 else { return false }
        return parts[1] != "cloud" && parts[1] != "local" && !parts[1].hasSuffix("-cloud") && !parts[0].hasSuffix("-cloud")
    }

    private static func isRemote(host: String?, model: String?) -> Bool {
        (host.map { !$0.isEmpty } ?? false) || (model.map { !$0.isEmpty } ?? false)
    }

    private func request<T: Decodable>(
        _ path: String, body: Data? = nil, timeout: TimeInterval = 8, failure: OllamaError
    ) async throws -> T {
        try Task.checkCancellation()
        guard port != 0, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw OllamaError.serverUnavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let transportError = error as? OllamaError { throw transportError }
            throw path == "/api/status" ? OllamaError.serverUnavailable : failure
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200 else { throw failure }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw failure
        }
    }
}

private final class DirectLoopbackDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// Ollama may repair or prune its store on launch. Give the private server its own
// filesystem view and omit partially downloaded and non-regular blobs.
func snapshotOllamaStore(from source: URL, to destination: URL) throws {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    let blobPattern = #"^sha256-[0-9a-fA-F]{64}$"#
    let originalBlobs = source.appendingPathComponent("blobs", isDirectory: true).resolvingSymlinksInPath()
    let privateBlobs = destination.appendingPathComponent("blobs", isDirectory: true)
    try fm.createDirectory(at: privateBlobs, withIntermediateDirectories: true)

    if fm.fileExists(atPath: originalBlobs.path) {
        let files = try fm.contentsOfDirectory(at: originalBlobs, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        for file in files {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            guard name.range(of: blobPattern, options: .regularExpression) == name.startIndex..<name.endIndex,
                  let metadata = try? file.resourceValues(forKeys: keys), metadata.isRegularFile == true,
                  metadata.isSymbolicLink != true else { continue }

            let target = privateBlobs.appendingPathComponent(name)
            if clonefile(file.path, target.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                if errno == ENOENT { continue }
                guard errno == EXDEV || errno == ENOTSUP else { throw OllamaError.modelStore }
                try fm.createSymbolicLink(at: target, withDestinationURL: file)
            }
        }
    }

    for tree in ["manifests", "manifests-v2"] {
        let root = source.appendingPathComponent(tree, isDirectory: true).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path),
              let entries = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }

        for case let entry as URL in entries {
            try Task.checkCancellation()
            guard entries.level == 4 else { continue }
            entries.skipDescendants()
            let original = entry.resolvingSymlinksInPath()
            guard let metadata = try? original.resourceValues(forKeys: keys), metadata.isRegularFile == true,
                  let bytes = metadata.fileSize, (1...8_388_608).contains(bytes) else { continue }

            let relative = entry.pathComponents.suffix(4).joined(separator: "/")
            let target = destination.appendingPathComponent(tree).appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? entry.resourceValues(forKeys: keys).isSymbolicLink) == true {
                let name = original.lastPathComponent
                guard tree == "manifests-v2", original.deletingLastPathComponent().path == originalBlobs.path,
                      name.range(of: blobPattern, options: .regularExpression) == name.startIndex..<name.endIndex,
                      let data = try? Data(contentsOf: original), data.count == bytes else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard name.lowercased() == "sha256-" + digest else { continue }
                try data.write(to: target)
            } else {
                do {
                    try fm.copyItem(at: entry, to: target)
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    continue
                }
            }
        }
    }
}
