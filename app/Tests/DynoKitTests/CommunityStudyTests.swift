import XCTest
@testable import DynoKit
final class CommunityStudyTests: XCTestCase {
    func testSharingExcludesTransportAndPreservesPromptConditions() throws {
        var input = ResearchIteration(); input.model = "Test model"; input.port = 8999; input.prompt = "Question"; input.system = "System"; input.context = [ResearchMessage(role: "user", content: "Context")]
        let entry = ResearchEntry(kind: "result", title: "Result", body: "PRIVATE_TRANSPORT_SECRET", iteration: input, answer: "Answer", thinking: "Thinking")
        let p = CommunityStudy(study: ResearchStudy(title: "Test", question: "Question", hypothesis: ""), entries: [entry], includeThinking: false, method: "Method", finding: "Inconclusive", limitations: "One case")
        let bytes = try p.data(); let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_TRANSPORT_SECRET")); XCTAssertFalse(text.contains("8999")); XCTAssertNil(p.entries[0].thinking)
        XCTAssertEqual(p.entries[0].context?.first?.content, "Context")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchNotebook(directory: root); let id = try p.importInto(store, original: bytes, sourceURL: "https://research.dynolab.dev/studies/test")
        let imported = try store.entries(id); let result = try XCTUnwrap(imported.first { $0.kind == "result" })
        XCTAssertEqual(result.iteration?.port, 0); XCTAssertEqual(result.answer, "Answer"); XCTAssertNotEqual(result.id, entry.id)
        XCTAssertEqual(try Data(contentsOf: store.folder(id).appendingPathComponent("source-package.json")), bytes)
    }
    func testRejectsCycleAndOversizeBeforeImport() throws {
        let entry = ResearchEntry(kind: "note", title: "Note", body: "Note")
        var p = CommunityStudy(study: ResearchStudy(title: "Test", question: "Q", hypothesis: ""), entries: [entry], includeThinking: false, method: "M", finding: "", limitations: "L")
        p.entries[0].parent = p.entries[0].id
        XCTAssertThrowsError(try p.data())
        XCTAssertThrowsError(try CommunityStudy.read(Data(repeating: 32, count: 1_000_001)))
    }
}
