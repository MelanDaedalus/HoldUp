import CryptoKit
import Foundation
import os

struct ModelAsset: Sendable {
    let name: String
    let filename: String
    let bytes: Int64
    let sha256: String
    let downloadURL: URL

    static let compact = ModelAsset(
        name: "Qwen3 1.7B",
        filename: "qwen3-1.7b-q4-3d0b790534fe.gguf",
        bytes: 1_359_279_776,
        sha256: "3d0b790534fe4b79525fc3692950408dca41171676ed7e21db57af5c65ef6ab6",
        downloadURL: URL(string: "https://registry.ollama.ai/v2/library/qwen3/blobs/sha256:3d0b790534fe4b79525fc3692950408dca41171676ed7e21db57af5c65ef6ab6")!
    )

    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct ModelStore: Sendable {
    let folder: URL
    let asset: ModelAsset

    static let standard = ModelStore(
        folder: URL.applicationSupportDirectory.appending(path: "Claim Check/Models", directoryHint: .isDirectory),
        asset: .compact
    )

    var fileURL: URL { folder.appending(path: asset.filename, directoryHint: .notDirectory) }

    var isInstalled: Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == asset.bytes
    }

    func download(progress: @escaping @Sendable (Int64) -> Void,
                  verifying: @escaping @Sendable () -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Use filesystem free bytes, which remains available when the OS withholds
        // the purgeable-capacity estimate from a managed process.
        let capacity = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        if let free = (capacity[.systemFreeSize] as? NSNumber)?.int64Value, free < asset.bytes + 64_000_000 {
            throw StorageError.space(asset.sizeDescription)
        }
        let staged = folder.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        let transfer = DownloadTransfer(staged: staged, progress: progress)
        try await transfer.download(asset.downloadURL)
        try Task.checkCancellation()
        verifying()
        try verifyAndInstall(staged: staged)
    }

    func verifyAndInstall(staged: URL) throws {
        let info = try staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, Int64(info.fileSize ?? -1) == asset.bytes else {
            throw StorageError.badModel
        }
        let handle = try FileHandle(forReadingFrom: staged)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else { throw StorageError.badModel }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: fileURL)
        }
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, Sendable {
        private struct Status {
            var cancelled = false
            var task: URLSessionDownloadTask?
            var completion: CheckedContinuation<Void, Error>?
            var file: Result<Void, Error>?
        }

        private let status = OSAllocatedUnfairLock(initialState: Status())
        let staged: URL
        let progress: @Sendable (Int64) -> Void

        init(staged: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.staged = staged
            self.progress = progress
        }

        func download(_ url: URL) async throws {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 7_200
            config.urlCache = nil
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                    let task = session.downloadTask(with: url)
                    let cancelled = status.withLock {
                        $0.task = task
                        $0.completion = completion
                        return $0.cancelled
                    }
                    task.resume()
                    if cancelled { task.cancel() }
                }
            } onCancel: {
                let task = self.status.withLock {
                    $0.cancelled = true
                    return $0.task
                }
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let result = Result<Void, Error> {
                guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https" else { throw StorageError.badResponse }
                try FileManager.default.moveItem(at: location, to: staged)
            }
            status.withLock { $0.file = result }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let finished = status.withLock {
                let completion = $0.completion
                let file = $0.file
                $0.task = nil
                $0.completion = nil
                return (completion, file)
            }
            if let error {
                finished.0?.resume(throwing: error)
            } else {
                finished.0?.resume(with: finished.1 ?? .failure(StorageError.badResponse))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
    }
}

enum StorageError: LocalizedError {
    case space(String), badResponse, badModel

    var errorDescription: String? {
        switch self {
        case .space(let size): "Free at least \(size) of disk space plus room for verification, then retry."
        case .badResponse: "The model server didn’t return a complete download. Try again."
        case .badModel: "The downloaded file didn’t match the expected model. Try downloading it again."
        }
    }
}
