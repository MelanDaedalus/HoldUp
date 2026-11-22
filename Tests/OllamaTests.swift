import Foundation
import CryptoKit

@main
struct OllamaTests {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Ollama test failed. \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        if CommandLine.arguments.contains("--installed-empty-store") {
            try await installedEmptyStore()
            return
        }
        if CommandLine.arguments.contains("--loopback") {
            try await loopbackRedirect()
            return
        }

        try await rejectsUnverifiedCloudBeforeCheckingModels()
        try await failsClosedOnRedirectAndUnavailableServer()
        try await filtersRemoteAndUnsupportedModels()
        try await requiresLocalMetadataBeforeSendingAnExcerpt()
        try await separatesLoadingFromGeneration()
        try await successfulGenerationUsesSchemaAndLocalModel()
        try await cancelledPreparationNeverSendsAnExcerpt()
            try await generationRequiresASelectedModel()
        try snapshotsOnlyCompleteArtifacts()
        print("Ollama adapter tests passed")
    }

    private static func rejectsUnverifiedCloudBeforeCheckingModels() async throws {
        for status in [#"{"cloud":{"disabled":false,"source":"none"}}"#,
                       #"{"cloud":{"disabled":true,"source":"config"}}"#,
                       #"{"cloud":{"disabled":"true","source":"env"}}"#,
                       #"{"cloud":{"disabled":true}}"#] {
            let fixtures = Fixtures([.init(path: "/api/status", json: status)])
            try await expectError(.cloudUnverified) { try await fixtures.client.listModels() }
            try await fixtures.assertComplete()
        }
    }

    private static func failsClosedOnRedirectAndUnavailableServer() async throws {
        let redirected = Fixtures([.init(path: "/api/status", json: cloudDisabled, status: 307)])
        try await expectError(.cloudUnverified) { try await redirected.client.listModels() }
        try await redirected.assertComplete()

        let unavailable = OllamaClient(port: 51384) { _ in throw URLError(.cannotConnectToHost) }
        try await expectError(.serverUnavailable) { try await unavailable.listModels() }
    }

    private static func filtersRemoteAndUnsupportedModels() async throws {
        let fixtures = Fixtures([
            status,
            .init(path: "/api/tags", json: #"{"models":[{"name":"local:latest","model":"local:latest","size":17},{"name":"hidden:latest","model":"hidden:latest","remote_host":"https://ollama.com","size":1},{"name":"cloud:q4-cloud","model":"cloud:q4-cloud","size":1},{"name":"embed:latest","model":"embed:latest","size":25}]}"#),
            show(model: "local", json: supportedModel),
            show(model: "embed", json: #"{"details":{"format":"gguf"},"capabilities":["embedding"],"model_info":{"general.architecture":"bert"}}"#)
        ])
        let models = try await fixtures.client.listModels()
        try expect(models == [OllamaModel(name: "local:latest", size: 17)], "Only confirmed local completion models should be listed")
        try await fixtures.assertComplete()

        let empty = Fixtures([status, .init(path: "/api/tags", json: #"{"models":[]}"#)])
        try await expectError(.noModels) { try await empty.client.listModels() }
        try await empty.assertComplete()

        let imageOnly = Fixtures([
            status,
            .init(path: "/api/tags", json: #"{"models":[{"name":"image:latest","model":"image:latest","size":25}]}"#),
            show(model: "image", json: #"{"details":{"format":"safetensors"},"capabilities":["image"],"model_info":null}"#)
        ])
        try await expectError(.noModels) { try await imageOnly.client.listModels() }
        try await imageOnly.assertComplete()
    }

    private static func requiresLocalMetadataBeforeSendingAnExcerpt() async throws {
        for metadata in [#"{"remote_model":"upstream","details":{"format":"gguf"},"capabilities":["completion"],"model_info":{"general.architecture":"llama"}}"#,
                         #"{"remote_host":"https://ollama.com","details":{"format":"gguf"},"capabilities":["completion"],"model_info":{"general.architecture":"llama"}}"#,
                         #"{"details":{"format":"gguf"},"capabilities":["completion"]}"#,
                         #"{"details":{"format":"gguf"},"capabilities":["image","completion"],"model_info":{"general.architecture":"image"}}"#] {
            let fixtures = Fixtures([status, show(model: "local", json: metadata)])
            try await expectError(.modelMetadata) {
                try await fixtures.client.generate(system: "Check the claim", user: "PRIVATE FIXTURE", schema: schema, model: "local:latest")
            }
            try await fixtures.assertComplete()
        }
    }

    private static func separatesLoadingFromGeneration() async throws {
        let fixtures = Fixtures([
            status, show(model: "local", json: supportedModel),
            .init(path: "/api/generate", model: "local:latest:local", json: #"{"error":"out of memory"}"#, status: 500)
        ])
        try await expectError(.modelLoad) {
            try await fixtures.client.generate(system: "Check the claim", user: "PRIVATE FIXTURE", schema: schema, model: "local:latest")
        }
        try await fixtures.assertComplete()
    }

    private static func successfulGenerationUsesSchemaAndLocalModel() async throws {
        let fixtures = Fixtures([
            status, show(model: "local", json: supportedModel), load,
            .init(path: "/api/generate", model: "local:latest:local", prompt: "PUBLIC FIXTURE", json: #"{"model":"local:latest:local","done":true,"done_reason":"stop","response":"{\"answer\":\"sample\"}"}"#)
        ])
        let result = try await fixtures.client.generate(system: "Check the claim", user: "PUBLIC FIXTURE", schema: schema, model: "local:latest")
        try expect(result == #"{"answer":"sample"}"#, "The JSON string returned by Ollama should reach core validation")
        try await fixtures.assertComplete()
    }

    private static func cancelledPreparationNeverSendsAnExcerpt() async throws {
        let fixtures = Fixtures([
            status, show(model: "local", json: supportedModel),
            .init(path: "/api/generate", model: "local:latest:local", json: "", cancel: true)
        ])
        do {
            _ = try await fixtures.client.generate(system: "Check the claim", user: "PRIVATE FIXTURE", schema: schema, model: "local:latest")
            throw TestFailure(message: "Cancelled load returned a result")
        } catch is CancellationError {
            try await fixtures.assertComplete()
        }
    }

    private static func generationRequiresASelectedModel() async throws {
        let engine = OllamaEngine()
        try await expectError(.modelNotSelected) {
            try await engine.generate(system: "Check the claim", user: "PRIVATE FIXTURE", schema: schema, model: "")
        }
    }

    private static func snapshotsOnlyCompleteArtifacts() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("source")
        let snapshot = directory.appendingPathComponent("snapshot")
        let blobs = source.appendingPathComponent("blobs")
        let legacy = source.appendingPathComponent("manifests/registry.ollama.ai/library/model/latest")
        let modern = source.appendingPathComponent("manifests-v2/ollama.com/library/model/latest")
        defer { try? fm.removeItem(at: directory) }

        for folder in [blobs, legacy.deletingLastPathComponent(), modern.deletingLastPathComponent()] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let legacyMetadata = Data(#"{"schemaVersion":2}"#.utf8)
        let modernMetadata = Data(#"{"schemaVersion":2,"runner":"ggml"}"#.utf8)
        let digest = "sha256-" + SHA256.hash(data: modernMetadata).map { String(format: "%02x", $0) }.joined()
        let weights = "sha256-" + String(repeating: "a", count: 64)
        let partial = "sha256-" + String(repeating: "b", count: 64) + "-partial"
        let untrustedLink = "sha256-" + String(repeating: "c", count: 64)
        try Data("weights".utf8).write(to: blobs.appendingPathComponent(weights))
        try Data("still downloading".utf8).write(to: blobs.appendingPathComponent(partial))
        try fm.createSymbolicLink(at: blobs.appendingPathComponent(untrustedLink), withDestinationURL: blobs.appendingPathComponent(weights))
        try legacyMetadata.write(to: legacy)
        try modernMetadata.write(to: blobs.appendingPathComponent(digest))
        try fm.createSymbolicLink(at: modern, withDestinationURL: blobs.appendingPathComponent(digest))

        try snapshotOllamaStore(from: source, to: snapshot)
        let copiedLegacy = try Data(contentsOf: snapshot.appendingPathComponent("manifests/registry.ollama.ai/library/model/latest"))
        let copiedModern = try Data(contentsOf: snapshot.appendingPathComponent("manifests-v2/ollama.com/library/model/latest"))
        let copiedWeights = try Data(contentsOf: snapshot.appendingPathComponent("blobs/\(weights)"))
        try expect(copiedLegacy == legacyMetadata, "The legacy manifest should be readable locally")
        try expect(copiedModern == modernMetadata, "The v2 manifest should be readable locally")
        try expect(copiedWeights == Data("weights".utf8), "Only completed weights should be accessible in the private session")
        try expect(!fm.fileExists(atPath: snapshot.appendingPathComponent("blobs/\(partial)").path), "Active downloads should be omitted")
        try expect(!fm.fileExists(atPath: snapshot.appendingPathComponent("blobs/\(untrustedLink)").path), "Arbitrary blob links should be omitted")
        try fm.removeItem(at: snapshot)
        let originalPartial = try Data(contentsOf: blobs.appendingPathComponent(partial))
        try expect(originalPartial == Data("still downloading".utf8), "Closing the private snapshot should leave active downloads intact")
        try expect(fm.fileExists(atPath: blobs.appendingPathComponent(weights).path), "Closing the private snapshot should leave original weights intact")
    }

    private static func installedEmptyStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = OllamaEngine(modelStore: root)
        try await expectError(.noModels) {
            try await engine.generate(system: "Check the claim", user: "PRIVATE FIXTURE", schema: schema, model: "local:latest")
        }
        await engine.stop()
        print("Verified installed Ollama cloud-disabled startup using an empty temporary model store")
    }

    private static func loopbackRedirect() async throws {
        let output = Pipe()
        let stub = Process()
        stub.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        stub.arguments = ["-c", """
            from http.server import BaseHTTPRequestHandler, HTTPServer

            class Handler(BaseHTTPRequestHandler):
                def do_POST(self):
                    self.rfile.read(int(self.headers['Content-Length']))
                    if self.path == '/api/generate':
                        self.send_response(307)
                        self.send_header('Location', '/redirect-target')
                    else:
                        self.send_response(200)
                    self.send_header('Content-Length', '0')
                    self.end_headers()

            server = HTTPServer(('127.0.0.1', 0), Handler)
            print(server.server_port, flush=True)
            server.serve_forever()
            """]
        stub.standardOutput = output
        stub.standardError = FileHandle.nullDevice
        try stub.run()
        defer {
            if stub.isRunning { stub.terminate() }
            stub.waitUntilExit()
        }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = UInt16(line.trimmingCharacters(in: .whitespacesAndNewlines)), port != 0 else {
            throw TestFailure(message: "The fixture could not bind to an ephemeral loopback port")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"prompt":"PUBLIC FIXTURE"}"#.utf8)
        let session = OllamaClient.privateSession()
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        try expect((response as? HTTPURLResponse)?.statusCode == 307 && response.url == request.url,
                   "The real Ollama session forwarded a generation request on an HTTP redirect")
        print("Verified the private URLSession rejects POST redirects on a disposable loopback fixture")
    }

    private static let cloudDisabled = #"{"cloud":{"disabled":true,"source":"env"}}"#
    private static let status = Step(path: "/api/status", json: cloudDisabled)
    private static let schema = Data(#"{"type":"object","properties":{"answer":{"type":"string"}}}"#.utf8)
    private static let supportedModel = #"{"details":{"format":"gguf","family":"llama"},"capabilities":["completion"],"model_info":{"general.architecture":"llama"}}"#
    private static let load = Step(path: "/api/generate", model: "local:latest:local", json: #"{"model":"local:latest:local","done":true,"done_reason":"load","response":""}"#)

    private static func show(model: String, json: String) -> Step {
        Step(path: "/api/show", model: "\(model):latest:local", json: json)
    }

    private static func expectError<T>(_ expected: OllamaError, operation: () async throws -> T) async throws {
        do {
            _ = try await operation()
        } catch let error as OllamaError {
            return try expect(error == expected, "Expected \(expected), received \(error)")
        }
        throw TestFailure(message: "Expected \(expected), received no error")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message: message) }
    }

    private struct TestFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private struct Step: Sendable {
        let path: String
        var model: String? = nil
        var prompt: String? = nil
        let json: String
        var status: Int = 200
        var cancel: Bool = false
    }

    private actor Fixtures {
        private var steps: [Step]
        private var failure: TestFailure?

        init(_ steps: [Step]) { self.steps = steps }

        nonisolated var client: OllamaClient {
            OllamaClient(port: 51384) { request in try await self.response(request) }
        }

        func assertComplete() throws {
            if let failure { throw failure }
            try expect(steps.isEmpty, "Expected all fixture requests to be consumed")
        }

        private func response(_ request: URLRequest) throws -> (Data, URLResponse) {
            do {
                try expect(!steps.isEmpty, "The client sent an unexpected request")
                let step = steps.removeFirst()
                try expect(request.url?.absoluteString == "http://127.0.0.1:51384\(step.path)", "The client left its assigned loopback endpoint or used the wrong route")
                try expect(request.httpMethod == (step.model == nil ? "GET" : "POST"), "The request used the wrong method")
                if let model = step.model {
                    let body = request.httpBody ?? Data()
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                    try expect(json?["model"] as? String == model, "The request must use the verified model and explicitly request local inference")
                    if let prompt = step.prompt {
                        let format = json?["format"] as? [String: Any]
                        let answer = (format?["properties"] as? [String: [String: String]])?["answer"]
                        try expect(json?["prompt"] as? String == prompt, "The review excerpt changed")
                        try expect(json?["system"] as? String == "Check the claim", "The system prompt changed")
                        try expect(json?["stream"] as? Bool == false, "The request must expect a complete response")
                        try expect(format?["type"] as? String == "object" && answer?["type"] == "string", "The JSON schema must be included in the generation request")
                    } else {
                        try expect(json?["system"] == nil && (json?["prompt"] as? String ?? "").isEmpty, "Model metadata and load requests cannot contain text to review")
                    }
                } else {
                    try expect(request.httpBody == nil, "GET metadata cannot contain user text")
                }
                if step.cancel { throw URLError(.cancelled) }
                let response = HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: nil)!
                return (Data(step.json.utf8), response)
            } catch let error as TestFailure {
                failure = error
                throw error
            }
        }
    }
}
