import XCTest
@testable import DynoKit

final class GGUFModelsTests: XCTestCase {
    func testOnlyCompleteSingleGGUFModelsAppear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in [("good.gguf", "GGUFweights"), ("bad.gguf", "HTMLerror"), ("download.gguf.incomplete", "GGUFweights"), ("shard-00001-of-00002.gguf", "GGUFweights"), ("model.safetensors", "weights")] {
            try Data(content.utf8).write(to: root.appendingPathComponent(name))
        }
        try Data(#"{"repository":"org/example","filename":"good.gguf"}"#.utf8).write(to: root.appendingPathComponent("model.json"))
        let found = GGUFModels.scan(roots: [root.path])
        XCTAssertEqual(found.map(\.name), ["good.gguf"])
        XCTAssertEqual(found.first?.repository, "org/example")
    }
}
