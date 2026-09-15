import XCTest
@testable import DynoKit
final class ResearchTimelineArchiveTests: XCTestCase {
    func testArchiveRestorePreservesQueryAndIndependentBranches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ResearchNotebook(directory: dir)
        let study = ResearchStudy(title: "Test", question: "Q", hypothesis: "")
        try store.create(study)
        let attempt = ResearchEntry(kind: "iteration", title: "Query")
        let result = ResearchEntry(kind: "result", title: "Result", parent: attempt.id, answer: "Answer")
        let branch = ResearchEntry(kind: "iteration", title: "Branch", parent: result.id)
        let note = ResearchEntry(kind: "note", title: "Observation", parent: result.id)
        for entry in [attempt, result, branch, note] { try store.append(entry, to: study.id) }
        let ids = ResearchTimelineArchive.queryIDs(for: result, in: [attempt, result, branch, note])
        XCTAssertEqual(Set(ids), [attempt.id, result.id])
        let body = String(data: try JSONEncoder().encode(ids), encoding: .utf8)!
        try store.append(ResearchEntry(kind: "archive", title: "Archive", body: body), to: study.id)
        let reopened = try store.entries(study.id)
        XCTAssertEqual(ResearchTimelineArchive.hiddenIDs(in: reopened), Set(ids))
        XCTAssertEqual(reopened.first(where: { $0.id == result.id })?.answer, "Answer")
        try store.append(ResearchEntry(kind: "restore", title: "Restore", body: body), to: study.id)
        XCTAssertTrue(ResearchTimelineArchive.hiddenIDs(in: try store.entries(study.id)).isEmpty)
    }
}
