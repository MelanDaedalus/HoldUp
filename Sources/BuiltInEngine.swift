import Foundation
import os

actor BuiltInEngine {
    private let runtime = BuiltInRuntime()
    private var activeRun: BuiltInCancellation?

    func generate(system: String, user: String, modelURL: URL, evidenceOnly: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard modelURL.isFileURL else { throw BuiltInError.model }
        guard activeRun == nil else { throw BuiltInError.busy }
        let cancellation = BuiltInCancellation()
        activeRun = cancellation
        defer { activeRun = nil }
        return try await withTaskCancellationHandler {
            let response = try await runtime.generate(
                system: system, user: user, modelURL: modelURL.standardizedFileURL,
                evidenceOnly: evidenceOnly, cancellation: cancellation
            )
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw CancellationError() }
            return response
        } onCancel: {
            cancellation.cancel()
        }
    }

    func unload() async {
        activeRun?.cancel()
        await runtime.unload()
    }
}

private final class BuiltInCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

private final class BuiltInRuntime: @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.claimcheck.inference", qos: .userInitiated)
    // All access happens on the serial inference queue.
    private var loadedModel: Model?

    private final class Model {
        let url: URL
        let handle: OpaquePointer

        init(url: URL, handle: OpaquePointer) {
            self.url = url
            self.handle = handle
        }

        deinit {
            cc_built_in_close(handle)
        }
    }

    private static let isCancelled: CCBuiltInCancellation = { data in
        guard let data else { return true }
        return Unmanaged<BuiltInCancellation>.fromOpaque(data).takeUnretainedValue().isCancelled
    }

    func generate(
        system: String, user: String, modelURL: URL, evidenceOnly: Bool, cancellation: BuiltInCancellation
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result {
                    try self.generateOnWorker(
                        system: system, user: user, modelURL: modelURL, evidenceOnly: evidenceOnly, cancellation: cancellation
                    )
                })
            }
        }
    }

    func unload() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.async {
                self.loadedModel = nil
                continuation.resume()
            }
        }
    }

    private func generateOnWorker(
        system: String, user: String, modelURL: URL, evidenceOnly: Bool, cancellation: BuiltInCancellation
    ) throws -> String {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let retainedCancellation = Unmanaged.passRetained(cancellation)
        defer { retainedCancellation.release() }
        let cancellationData = retainedCancellation.toOpaque()

        if loadedModel?.url != modelURL {
            loadedModel = nil
            var handle: OpaquePointer?
            let status = modelURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return CC_BUILT_IN_MODEL_ERROR }
                return cc_built_in_open(path, Self.isCancelled, cancellationData, &handle)
            }
            try BuiltInError.check(status)
            guard let handle else { throw BuiltInError.model }
            loadedModel = Model(url: modelURL, handle: handle)
        }
        guard let model = loadedModel else { throw BuiltInError.model }

        var response: UnsafeMutablePointer<CChar>?
        let generate = evidenceOnly ? cc_built_in_generate_evidence : cc_built_in_generate
        let status = system.withCString { systemBytes in
            user.withCString { userBytes in
                generate(
                    model.handle, systemBytes, system.utf8.count, userBytes, user.utf8.count,
                    Self.isCancelled, cancellationData, &response
                )
            }
        }
        defer { cc_built_in_free_response(response) }
        try BuiltInError.check(status)
        guard let response, let decoded = String(validatingCString: response) else {
            throw BuiltInError.incomplete
        }
        return decoded
    }
}

private enum BuiltInError: LocalizedError {
    case busy
    case model
    case promptTooLong
    case runtime
    case incomplete

    static func check(_ status: CCBuiltInStatus) throws {
        switch status {
        case CC_BUILT_IN_OK: return
        case CC_BUILT_IN_CANCELLED: throw CancellationError()
        case CC_BUILT_IN_MODEL_ERROR: throw Self.model
        case CC_BUILT_IN_PROMPT_TOO_LONG: throw Self.promptTooLong
        case CC_BUILT_IN_INCOMPLETE: throw Self.incomplete
        default: throw Self.runtime
        }
    }

    var errorDescription: String? {
        switch self {
        case .busy: "The built-in model is finishing another check. Try again in a moment."
        case .model: "The built-in model could not be opened. Check its installation in Settings."
        case .promptTooLong: "The text and rules exceed the built-in model’s context limit. Shorten the selection or context and try again."
        case .runtime: "The built-in model ran into a processing error. Try the check again."
        case .incomplete: "The built-in model could not finish a structured response. Try a shorter selection."
        }
    }
}
