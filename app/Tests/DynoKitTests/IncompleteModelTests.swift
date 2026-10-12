import Foundation
import Testing
@testable import DynoKit

struct IncompleteModelTests {
    @Test func aShardTheIndexNamesButIsMissingMakesTheModelIncomplete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("incomplete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = ["weight_map": ["a": "model-00001-of-00003.safetensors", "b": "model-00002-of-00003.safetensors", "c": "model-00003-of-00003.safetensors"]]
        try JSONSerialization.data(withJSONObject: index).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
        try Data([1]).write(to: dir.appendingPathComponent("model-00001-of-00003.safetensors"))
        try Data([1]).write(to: dir.appendingPathComponent("model-00003-of-00003.safetensors"))
        // A cache link whose blob never finished.
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("model-00002-of-00003.safetensors"),
                                                   withDestinationURL: dir.appendingPathComponent("blob.incomplete-gone"))
        #expect(ModelLibrary.missingWeights(in: dir.path) == ["model-00002-of-00003.safetensors"])
        try Data([1]).write(to: dir.appendingPathComponent("blob.incomplete-gone"))
        #expect(ModelLibrary.missingWeights(in: dir.path).isEmpty)
    }
}
