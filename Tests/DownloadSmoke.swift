import Foundation
import os

// Exercise URLSession progress and publication with a small pinned public fixture.
@main struct DownloadSmoke {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClaimCheckTransferTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ModelStore(folder: folder, asset: .init(
            name: "Transfer fixture", filename: "fixture.gguf", bytes: 1_185_376,
            sha256: "270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/models-moved/resolve/499bc88/tinyllamas/stories260K.gguf")!
        ))
        let updates = OSAllocatedUnfairLock(initialState: Int64(0))
        let verified = OSAllocatedUnfairLock(initialState: false)
        try await store.download(progress: { count in updates.withLock { $0 = max($0, count) } },
                                 verifying: { verified.withLock { $0 = true } })
        guard store.isInstalled, verified.withLock({ $0 }), updates.withLock({ $0 }) > 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Transfer did not publish an installed artifact and progress. Last byte count: \(updates.withLock { $0 })"
            ])
        }
        print("HTTPS transfer reported progress, verified its checksum, and installed the model")
    }
}
