import Foundation

@main struct ModelStoreTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = ModelAsset(name: "Fixture", filename: "test.gguf", bytes: 5,
                                  sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
                                  downloadURL: URL(string: "https://example.com/artifact")!)
        let store = ModelStore(folder: root, asset: manifest)
        let staged = root.appendingPathComponent("staged")
        try Data("wrong".utf8).write(to: staged)
        do {
            try store.verifyAndInstall(staged: staged)
            preconditionFailure("Accepted a same-size file with the wrong digest")
        } catch {}
        precondition(!store.isInstalled)
        try Data("hello".utf8).write(to: staged)
        try store.verifyAndInstall(staged: staged)
        let installed = try Data(contentsOf: store.fileURL)
        precondition(store.isInstalled && installed == Data("hello".utf8))
        try Data("wrong".utf8).write(to: staged)
        do {
            try store.verifyAndInstall(staged: staged)
            preconditionFailure("Replaced the valid file with corrupt data")
        } catch {}
        let preserved = try Data(contentsOf: store.fileURL)
        precondition(preserved == installed)
        try Data("hello".utf8).write(to: staged)
        try store.verifyAndInstall(staged: staged)
        precondition(store.isInstalled)
        try store.remove()
        precondition(!store.isInstalled)
        print("Model storage tests passed: checksum, publication, retry, preservation and removal")
    }
}
