import AppKit
import DynoKit
import Observation

@Observable @MainActor final class ResearchJournal {
    var studies: [ResearchStudy] = []
    var entries: [ResearchEntry] = []
    var selected: UUID?
    var incomingCommunityStudy: UUID?
    var error: String?
    var pendingWrites: [UUID: ResearchEntry] = [:]
    @ObservationIgnored private var pendingStudies: [UUID: UUID] = [:]
    var input = ResearchIteration() { didSet { persistDraft() } }
    var parent: UUID? { didSet { persistDraft() } }
    var completionAlert: ResearchEntry?
    var showingCompletionAlert = false
    var liveAnswer = ""
    var liveThinking = ""
    var liveStatus = ""
    var running = false
    var runTitle = "Baseline" { didSet { persistDraft() } }
    var note = "" { didSet { persistDraft() } }
    var noteKind = "Observation" { didSet { persistDraft() } }
    var focus: UUID? { didSet { persistDraft() } }
    let voice = ResearchVoiceNote()
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private let draftSession = UUID()
    @ObservationIgnored var task: Task<Void, Never>?
    let store: ResearchNotebook
    init(store: ResearchNotebook = ResearchNotebook()) { self.store = store; reload(); if let id = selected { select(id) } }
    func reload() {
        do { studies = try store.studies(); if selected == nil { selected = studies.first?.id }; entries = try selected.map { try store.entries($0) } ?? [] }
        catch { self.error = "Notebook could not be read: \(error.localizedDescription). Your files have not been removed." }
    }
    private func persistDraft() {
        guard !restoring, let id = selected else { return }
        do { try store.saveWorkingCopy(ResearchWorkingCopy(input: input, title: runTitle, parent: parent, note: note, noteKind: noteKind, focus: focus), study: id, session: draftSession) }
        catch { self.error = "Draft could not be saved: \(error.localizedDescription)" }
    }
    func select(_ id: UUID) {
        restoring = true
        defer { restoring = false }
        selected = id; parent = nil; input = ResearchIteration(); runTitle = "Baseline"; note = ""; noteKind = "Observation"; focus = nil
        do {
            if let draft = try store.workingCopy(id) { input = draft.input; runTitle = draft.title; parent = draft.parent; note = draft.note; noteKind = draft.noteKind; focus = draft.focus }
        } catch { self.error = error.localizedDescription }
        reload()
    }
    func create(title: String, question: String, hypothesis: String) {
        do { let study = ResearchStudy(title: title, question: question, hypothesis: hypothesis); try store.create(study); select(study.id) }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func save(_ entry: ResearchEntry, study: UUID? = nil) -> Bool {
        guard let id = study ?? selected else { return false }
        do { try store.append(entry, to: id); pendingWrites[entry.id] = nil; pendingStudies[entry.id] = nil; reload(); return true }
        catch { pendingWrites[entry.id] = entry; pendingStudies[entry.id] = id; self.error = "Entry has not been saved: \(error.localizedDescription). Keep the app open and retry saving."; return false }
    }
    var archivedIDs: Set<UUID> { ResearchTimelineArchive.hiddenIDs(in: entries) }
    func archive(_ entry: ResearchEntry, restoring: Bool = false) {
        guard !running else { return }
        let ids = ResearchTimelineArchive.queryIDs(for: entry, in: entries)
        guard let data = try? JSONEncoder().encode(ids), let body = String(data: data, encoding: .utf8) else { return }
        _ = save(ResearchEntry(kind: restoring ? "restore" : "archive", title: restoring ? "Restored query" : "Archived query", body: body, parent: entry.id))
    }
    func retryWrites() {
        for (id, entry) in Array(pendingWrites) { if let study = pendingStudies[id] { _ = save(entry, study: study) } }
        if pendingWrites.isEmpty { error = nil }
    }
    func revise(_ entry: ResearchEntry, followup: Bool) {
        guard var settings = entry.iteration else { return }
        if followup {
            guard entry.kind == "result", !entry.hitTokenLimit, entry.hasFinalAnswer, let answer = entry.answer else { return }
            settings.context += [ResearchMessage(role: "user", content: settings.prompt), ResearchMessage(role: "assistant", content: answer)]
            settings.prompt = ""
        }
        input = settings; parent = entry.id; runTitle = followup ? "Follow-up" : "Revision"
    }
    func prepareLongerRetry(_ entry: ResearchEntry) {
        guard !running, let settings = entry.largerBudgetRetry else { return }
        input = settings; parent = entry.id; runTitle = "Retry · higher token limit"
    }
    func run() {
        guard !running, pendingWrites.isEmpty, let study = selected, input.port > 0, !input.model.isEmpty, !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let settings = input
        let attempt = ResearchEntry(kind: "iteration", title: runTitle, body: "Submitted to the selected local endpoint. A separate result or error entry follows.", parent: parent, iteration: settings)
        guard save(attempt, study: study) else { return }
        running = true; error = nil
        liveAnswer = ""; liveThinking = ""; liveStatus = "Waiting for the endpoint…"
        task = Task {
            defer { running = false; task = nil }
            var stream = ResearchStream()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600 // No incoming data for ten minutes.
            configuration.timeoutIntervalForResource = 7200 // Bounded two-hour run, including streaming.
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var payload: [String: Any] = [:]
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.port)/v1/chat/completions")!)
                request.httpMethod = "POST"; request.timeoutInterval = 600
                payload = ["model": settings.model, "messages": settings.messages.map { ["role": $0.role, "content": $0.content] }, "temperature": settings.temperature, "max_tokens": settings.maxTokens, "seed": settings.seed, "stream": true]
                if settings.thinking != "default" { payload["chat_template_kwargs"] = ["enable_thinking": settings.thinking == "on"] }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    var detail = ""
                    for try await line in bytes.lines { detail += line; if detail.count > 8192 { break } }
                    throw NSError(domain: "Journal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Endpoint request failed: \(detail)"])
                }
                guard http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
                    throw NSError(domain: "Journal", code: 2, userInfo: [NSLocalizedDescriptionKey: "This endpoint did not return a streaming response. No request was automatically retried."])
                }
                var lastUpdate = Date.distantPast
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    try stream.consume(line)
                    if Date().timeIntervalSince(lastUpdate) > 0.15 || stream.done {
                        let text = stream.text
                        liveAnswer = text.answer; liveThinking = text.thinking
                        liveStatus = "Receiving model output · \((stream.content.count + stream.reasoning.count).formatted()) characters"
                        lastUpdate = Date()
                    }
                    if stream.done { break }
                }
                guard stream.finishReason != nil else {
                    throw NSError(domain: "Journal", code: 3, userInfo: [NSLocalizedDescriptionKey: "The stream ended without a finish reason. Partial output is preserved; this is not a completed response."])
                }
                let parsed = stream.text
                liveAnswer = parsed.answer; liveThinking = parsed.thinking
                let evidence: [String: Any] = ["request": payload, "response": stream.response, "stream_chunks": stream.chunks, "endpoint": request.url!.absoluteString, "note": "Response assembled from recorded streaming deltas. Thinking is model output, not verified reasoning. Model identity is endpoint-reported. No activations captured."]
                let body = String(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!
                let result = ResearchEntry(kind: "result", title: "\(attempt.title) · \(stream.finishReason ?? "unknown finish")", body: body, parent: attempt.id, iteration: settings, answer: parsed.answer, thinking: parsed.thinking)
                _ = save(result, study: study)
                if result.completionWarning != nil { completionAlert = result; showingCompletionAlert = true }
            } catch {
                liveAnswer = stream.text.answer; liveThinking = stream.text.thinking
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                let timedOut = (error as? URLError)?.code == .timedOut
                let explanation = cancelled ? "Client request cancelled. The endpoint may still finish scheduled generation." : timedOut ? "The endpoint stopped sending data for ten minutes, or the two-hour run limit was reached. Check Execution before retrying: the server may still be generating." : error.localizedDescription
                let evidence: [String: Any] = ["error": explanation, "request": payload, "response": stream.response, "stream_chunks": stream.chunks, "incomplete": true]
                let body = (try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? explanation
                _ = save(ResearchEntry(kind: cancelled ? "cancelled" : "error", title: cancelled ? "Request cancelled · partial output" : "Request failed · incomplete", body: body, parent: attempt.id, iteration: settings, answer: stream.text.answer, thinking: stream.text.thinking), study: study)
                if !cancelled { self.error = explanation }

            }
        }
    }
    func export() {
        guard let id = selected else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Research-notebook-\(id.uuidString.prefix(8))"; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try FileManager.default.copyItem(at: store.folder(id), to: url) }
            catch { self.error = error.localizedDescription }
        }
    }
}
