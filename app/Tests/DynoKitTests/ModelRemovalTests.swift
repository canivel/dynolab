import Foundation
import Testing
@testable import DynoKit

struct ModelRemovalTests {
    /// A Hugging Face cache entry: weights in blobs, linked from a snapshot.
    private func cacheEntry(_ hub: URL, _ repo: String, files: [String]) throws -> URL {
        let entry = hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        let snapshot = entry.appendingPathComponent("snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: entry.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        for (i, name) in files.enumerated() {
            let blob = entry.appendingPathComponent("blobs/blob\(i)")
            try Data(repeating: 1, count: 1000).write(to: blob)
            try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(name), withDestinationURL: blob)
        }
        return snapshot
    }

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    @Test func anMLXModelInTheCacheGoesWithItsBlobs() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = root.appendingPathComponent("hub")
        let snapshot = try cacheEntry(hub, "org/model", files: ["config.json", "model.safetensors"])
        let targets = try ModelRemoval.targets(for: snapshot.path, roots: [hub.path])
        #expect(targets.map(\.lastPathComponent) == ["models--org--model"])
        #expect(ModelRemoval.size(of: targets[0]) >= 2000)  // the blobs, not the links
    }

    @Test func oneOfSeveralGGUFFilesGoesWithItsOwnBlobOnly() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let hub = root.appendingPathComponent("hub")
        let snapshot = try cacheEntry(hub, "org/gguf", files: ["a-Q4.gguf", "a-Q8.gguf"])
        let targets = try ModelRemoval.targets(for: snapshot.appendingPathComponent("a-Q4.gguf").path, roots: [hub.path])
        #expect(targets.map(\.lastPathComponent) == ["a-Q4.gguf", "blob0"])
        let only = try cacheEntry(hub, "org/single", files: ["b.gguf"])
        #expect(try ModelRemoval.targets(for: only.appendingPathComponent("b.gguf").path, roots: [hub.path]).map(\.lastPathComponent) == ["models--org--single"])
    }

    @Test func aPlainFolderGoesItselfAndNothingOutsideTheLibrary() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("models"), model = models.appendingPathComponent("my-model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        #expect(try ModelRemoval.targets(for: model.path, roots: [models.path]) == [model.standardizedFileURL])
        #expect(throws: ModelRemoval.Failure.self) { try ModelRemoval.targets(for: models.path, roots: [models.path]) }  // never a root
        #expect(throws: ModelRemoval.Failure.self) { try ModelRemoval.targets(for: model.path, roots: [root.appendingPathComponent("other").path]) }
        #expect(throws: ModelRemoval.Failure.self) { try ModelRemoval.targets(for: model.path + "/../../escape", roots: [models.path]) }
    }
}
