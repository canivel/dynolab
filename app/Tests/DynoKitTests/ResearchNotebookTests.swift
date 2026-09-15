import XCTest
@testable import DynoKit
final class ResearchNotebookTests: XCTestCase {
    func testCappedResultPreparesSeparateRetryWithoutChangingConditions() {
        var settings = ResearchIteration(); settings.prompt = "Original"; settings.maxTokens = 2048
        settings.context = [ResearchMessage(role: "user", content: "Prior")]
        let entry = ResearchEntry(kind: "result", title: "Baseline", body: #"{"response":{"choices":[{"finish_reason":"length"}]}}"#, iteration: settings, answer: "", thinking: "Still thinking")
        XCTAssertTrue(entry.hitTokenLimit); XCTAssertFalse(entry.hasFinalAnswer)
        XCTAssertTrue(entry.completionWarning?.contains("2048") == true)
        XCTAssertTrue(entry.completionWarning?.contains("before returning a final answer") == true)
        let retry = entry.largerBudgetRetry!
        XCTAssertEqual(retry.maxTokens, 8192); XCTAssertEqual(entry.iteration?.maxTokens, 2048)
        XCTAssertEqual(retry.prompt, settings.prompt); XCTAssertEqual(retry.context.first?.content, "Prior")
        XCTAssertEqual(retry.thinking, settings.thinking); XCTAssertEqual(retry.seed, settings.seed)
        let stopped = ResearchEntry(kind: "result", title: "Done", body: #"{"response":{"choices":[{"finish_reason":"stop"}]}}"#, iteration: settings, answer: "Answer")
        XCTAssertFalse(stopped.hitTokenLimit); XCTAssertNil(stopped.largerBudgetRetry)
        XCTAssertTrue(stopped.hasFinalAnswer); XCTAssertNil(stopped.completionWarning)
        let empty = ResearchEntry(kind: "result", title: "Empty", body: stopped.body, answer: " ")
        XCTAssertTrue(empty.completionWarning?.contains("finish reason: stop") == true)
        let partial = ResearchEntry(kind: "result", title: "Partial", body: entry.body, answer: "An unfinished")
        XCTAssertTrue(partial.completionWarning?.contains("may be incomplete") == true)
    }
    func testIncompleteThinkingIsNotInventedAsFinalAnswer() {
        let incomplete = ResearchResponseText(content: "<think>Still considering")
        XCTAssertEqual(incomplete.answer, "")
        XCTAssertEqual(incomplete.thinking, "Still considering")
        let complete = ResearchResponseText(content: "<think>Check record</think> No")
        XCTAssertEqual(complete.answer, "No")
        XCTAssertEqual(complete.thinking, "Check record")
        XCTAssertEqual(ResearchResponseText(content: "No", reasoning: "Separate field").thinking, "Separate field")
    }
    func testWorkingDraftAndAudioSurviveReopenWithoutChangingEvidence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ResearchNotebook(directory: dir)
        let study = ResearchStudy(title: "Study", question: "Q", hypothesis: "H"); try store.create(study)
        let first = ResearchEntry(kind: "note", title: "Original", body: "Keep this"); try store.append(first, to: study.id)
        var input = ResearchIteration(); input.prompt = "Unsaved editor text"
        let draft = ResearchWorkingCopy(input: input, title: "Revision", parent: first.id, note: "My observation", noteKind: "Observation", focus: first.id)
        try store.saveWorkingCopy(draft, study: study.id, session: UUID())
        XCTAssertEqual(try ResearchNotebook(directory: dir).workingCopy(study.id)?.note, "My observation")
        XCTAssertEqual(try store.entries(study.id).count, 1)
        let source = dir.appendingPathComponent("voice.m4a"); try Data([1, 2, 3]).write(to: source)
        let attachment = try store.attach(source, study: study.id)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: store.folder(study.id).appendingPathComponent(attachment)), Data([1, 2, 3]))
    }
    func testHistorySurvivesReopenAndBranchesPreserveInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchNotebook(directory: directory)
        let study = ResearchStudy(title: "Pressure", question: "Does evidence stay fixed?", hypothesis: "No reversal")
        try store.create(study)
        var input = ResearchIteration(); input.prompt = "Check the record"; input.model = "pinned-model"
        let draft = ResearchEntry(kind: "iteration", title: "Baseline", iteration: input)
        try store.append(draft, to: study.id)
        let result = ResearchEntry(kind: "result", title: "Baseline result", parent: draft.id, iteration: input, answer: "No")
        try store.append(result, to: study.id)
        input.context = [ResearchMessage(role: "user", content: input.prompt), ResearchMessage(role: "assistant", content: "No")]
        input.prompt = "But I disagree"
        try store.append(ResearchEntry(kind: "iteration", title: "Challenge", parent: result.id, iteration: input), to: study.id)
        let reopened = ResearchNotebook(directory: directory)
        XCTAssertEqual(try reopened.studies().first?.id, study.id)
        let entries = try reopened.entries(study.id)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first(where: { $0.id == draft.id })?.iteration?.prompt, "Check the record")
        XCTAssertEqual(input.messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertThrowsError(try store.append(draft, to: study.id))
    }
    func testMissingStudyAndCorruptEntryAreVisibleErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchNotebook(directory: directory)
        XCTAssertThrowsError(try store.append(ResearchEntry(kind: "note", title: "Note"), to: UUID()))
        let study = ResearchStudy(title: "Test", question: "Q", hypothesis: "H"); try store.create(study)
        let entry = ResearchEntry(kind: "note", title: "Keep me"); try store.append(entry, to: study.id)
        try Data("broken".utf8).write(to: store.folder(study.id).appendingPathComponent("entries/\(entry.id.uuidString).json"))
        XCTAssertThrowsError(try store.entries(study.id))
    }
}
