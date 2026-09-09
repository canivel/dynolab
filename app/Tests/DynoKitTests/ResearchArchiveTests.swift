import XCTest
@testable import DynoKit

final class ResearchArchiveTests: XCTestCase {
    func testRoundTripSeparateKindsAndImmutableRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchArchive(directory: directory)
        try store.save(["config": ["prompt": "First", "layers": [4, 8]], "result": ["norms": [1.2, 3.4]]], kind: "activation")
        try store.save(["config": ["prompt": "Second"]], kind: "activation")
        var trace = TokenTrace(model: "test-model")
        trace.text = "Hello"
        trace.tokens = [TokenReading(id: 0, text: "Hello", probability: 0.75, alternatives: [("Hello", 0.75), ("Hi", 0.25)])]
        try store.save(["reference": trace.archiveValue, "thinking": "off"], kind: "tokens")
        let reopened = ResearchArchive(directory: directory)
        XCTAssertEqual(try reopened.load(kind: "activation").count, 2)
        let tokenRuns = try reopened.load(kind: "tokens")
        XCTAssertEqual(tokenRuns.count, 1)
        let decoded = TokenTrace(archiveValue: tokenRuns[0]["reference"] as! [String: Any])
        XCTAssertEqual(decoded.model, trace.model)
        XCTAssertEqual(decoded.tokens[0].alternatives[1].probability, 0.25)
        XCTAssertEqual(tokenRuns[0]["thinking"] as? String, "off")
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("broken.json"))
        XCTAssertEqual(try reopened.load(kind: "tokens").count, 1)
    }
}
