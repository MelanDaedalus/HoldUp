import Foundation
import os

@main
struct BuiltInEngineSmoke {
    struct SmokeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure("Pass a local GGUF fixture path.")
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = BuiltInEngine()
        let system = "Return a JSON claim-check result. Use no_flags and an empty findings array for a grounded claim."
        let user = "The excerpt says: The temperature was 20°C on Tuesday."

        let invalidURL = modelURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        do {
            _ = try await engine.generate(system: system, user: user, modelURL: invalidURL)
            throw SmokeFailure("An absent GGUF file must fail.")
        } catch let error as SmokeFailure {
            throw error
        } catch is CancellationError {
            throw SmokeFailure("An absent model reported cancellation.")
        } catch {
            print("PASS: absent GGUF rejected")
        }

        let response = try await engine.generate(system: system, user: user, modelURL: modelURL)
        try validate(response)
        print("PASS: bundled runtime returned constrained JSON")

        let evidence = try await engine.generate(system: "Return the JSON object {\"findings\":[]}.", user: user,
                                                 modelURL: modelURL, evidenceOnly: true)
        let decoded = try JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any]
        guard let decoded, Set(decoded.keys) == ["findings"], decoded["findings"] is [[String: Any]] else {
            throw SmokeFailure("The evidence runtime did not return its expected response shape.")
        }
        print("PASS: bundled runtime returned constrained evidence JSON")

        await engine.unload()
        try verifyNativeCancellation(modelURL, system: system)
        print("PASS: native cancellation interrupted an active decode")

        let task = Task {
            try await engine.generate(system: system, user: user, modelURL: modelURL)
        }
        task.cancel()
        do {
            _ = try await task.value
            throw SmokeFailure("Cancelled inference returned a response.")
        } catch is CancellationError {
            print("PASS: cancellation surfaced to the caller")
        }
        await engine.unload()

        let nextResponse = try await engine.generate(system: system, user: user, modelURL: modelURL)
        try validate(nextResponse)
        print("PASS: inference resumed after cancellation and unload")
        await engine.unload()
    }

    private final class DecodeCancellation: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
    }

    private static func verifyNativeCancellation(_ url: URL, system: String) throws {
        var model: OpaquePointer?
        let loadStatus = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return CC_BUILT_IN_MODEL_ERROR }
            return cc_built_in_open(path, { _ in false }, nil, &model)
        }
        guard loadStatus == CC_BUILT_IN_OK, let model else {
            throw SmokeFailure("The native cancellation test could not load its fixture.")
        }
        defer { cc_built_in_close(model) }

        let flag = Unmanaged.passRetained(DecodeCancellation())
        defer { flag.release() }
        let context = String(repeating: " More text for the cancellable prompt.", count: 100)
        var response: UnsafeMutablePointer<CChar>?
        let status = system.withCString { systemBytes in
            context.withCString { contextBytes in
                cc_built_in_generate(
                    model, systemBytes, system.utf8.count, contextBytes, context.utf8.count,
                    { data in
                        guard let data else { return true }
                        let state = Unmanaged<DecodeCancellation>.fromOpaque(data).takeUnretainedValue()
                        return state.calls.withLock { checks in
                            checks += 1
                            return checks >= 3
                        }
                    },
                    flag.toOpaque(), &response
                )
            }
        }
        defer { cc_built_in_free_response(response) }
        guard status == CC_BUILT_IN_CANCELLED, response == nil else {
            throw SmokeFailure("Native decoding continued after the cancellation callback.")
        }
    }

    private static func validate(_ response: String) throws {
        let decoded = try JSONSerialization.jsonObject(with: Data(response.utf8))
        guard let object = decoded as? [String: Any], Set(object.keys) == ["outcome", "findings"],
              let outcome = object["outcome"] as? String,
              let findings = object["findings"] as? [[String: String]] else {
            throw SmokeFailure("Invalid result shape: \(response)")
        }
        switch outcome {
        case "findings":
            guard (1...5).contains(findings.count), findings.allSatisfy({
                Set($0.keys) == ["ruleID", "quote", "reason", "verify"] && $0.values.allSatisfy { !$0.isEmpty }
            }) else {
                throw SmokeFailure("Invalid findings: \(response)")
            }
        case "no_flags", "needs_context":
            guard findings.isEmpty else {
                throw SmokeFailure("An empty outcome included findings: \(response)")
            }
        default:
            throw SmokeFailure("Unknown outcome: \(outcome)")
        }
    }
}
