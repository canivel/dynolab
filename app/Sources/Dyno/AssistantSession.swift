import Foundation
import Observation

/// The app side of Dyno's assistant (src/dyno/lab/assistant.py). The lab service runs the conversation with the
/// local model and keeps it on disk; this keeps the visible part in sync: it sends what the person writes with a
/// snapshot of their screen, polls while the assistant works, and hands "show in Dyno" actions to the window.
@Observable @MainActor final class AssistantSession {
    var conversations: [[String: Any]] = []
    var conversationID: String? {
        didSet { if remember { UserDefaults.standard.set(conversationID, forKey: "assistantConversation") } }
    }
    /// Off for snapshots, which show a given conversation without changing the one the app reopens.
    @ObservationIgnored var remember = true
    var events: [[String: Any]] = []
    var live: [String: Any]?
    var pending: [String: Any]?
    var status = "idle"
    var title = ""
    var plan: [[String: Any]] = []
    var contextUse: [String: Any]?
    var budget = 32768
    var thinking = false
    /// Web search through SearXNG (Docker, this Mac), on for this conversation.
    var web = false
    /// SearXNG's state: off, starting, running or error (with the reason).
    var webStatus = "off"
    var webError: String?
    /// The connectors (MCP servers, Settings → Connectors) this conversation may use, by id; and every connector
    /// added, with its state (stopped, starting, running, error) and tools.
    var connectors: [String] = []
    var available: [[String: Any]] = []
    var hasEarlier = false
    /// Files being read for the assistant ("Reading paper.pdf…"), and how many tokens the chosen model can read.
    var attaching: String?
    var modelContext: [String: Int] = [:]
    /// The model this conversation last used ("port model"), so reopening it picks that model again.
    var conversationModel: String?
    /// For "Undo" on a setup the assistant filled in: the setup that was on screen before, by action id.
    var undo: [String: String] = [:]
    var error: String?
    var busy: Bool { status == "thinking" || status == "working" }

    /// Called once for each "show in Dyno" action the assistant takes while you watch (not when reloading history).
    @ObservationIgnored var onAction: (([String: Any]) -> Void)?
    @ObservationIgnored private var lab: ResearchLab?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastSeq = 0

    func attach(_ lab: ResearchLab, conversation: String? = nil) {
        guard self.lab == nil else { return }
        self.lab = lab
        conversationID = conversation ?? UserDefaults.standard.string(forKey: "assistantConversation")
        Task {
            // The lab service may still be starting when the window opens: wait for it rather than show an empty list.
            for _ in 0..<120 {
                if (try? await lab.request("/health")) != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await refreshList(); await loadConnectors(); if let id = conversationID { await open(id) }
        }
        NotificationCenter.default.addObserver(forName: .dynoConnectorsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.loadConnectors() }
        }
    }

    // MARK: Conversations

    func refreshList() async {
        guard let lab else { return }
        conversations = (try? await lab.request("/assistant/conversations", timeout: 10))?["conversations"] as? [[String: Any]] ?? []
    }

    func open(_ id: String) async {
        guard let lab else { return }
        do {
            let r = try await lab.request("/assistant/conversations/\(id)?limit=60", timeout: 15)
            conversationID = id
            events = r["events"] as? [[String: Any]] ?? []
            hasEarlier = r["earlier"] as? Bool ?? false
            lastSeq = events.last?["seq"] as? Int ?? 0
            apply(r, newEvents: [])
            error = nil
            if busy { poll() }
            if web { Task { await watchWeb() } }
            if !connectors.isEmpty { Task { await watchConnectors() } }
        } catch {
            // Forget it only when the lab says it no longer exists, not when the lab can't be reached.
            if conversationID == id, error.localizedDescription.contains("Unknown conversation") { conversationID = nil; events = []; title = "" }
        }
    }

    func newConversation() async {
        guard let lab else { return }
        if let r = try? await lab.request("/assistant/conversations", body: [:], timeout: 10), let id = r["id"] as? String {
            clear()
            await open(id); await refreshList()
        }
    }

    /// A blank chat. The conversation on screen stays in the list (stopped if it was working); the new one is
    /// made on the server with the first message, so pressing this twice doesn't leave empty conversations behind.
    func startNew() async {
        if busy { await stop() }
        clear()
        await refreshList()
    }

    var isBlank: Bool { conversationID == nil && events.isEmpty }

    private func clear() {
        poller?.cancel(); poller = nil
        conversationID = nil
        events = []; plan = []; pending = nil; live = nil; lastSeq = 0; hasEarlier = false
        title = ""; status = "idle"; contextUse = nil; conversationModel = nil; undo = [:]; error = nil
        budget = 32768; thinking = false; web = false; connectors = []
    }

    func loadEarlier() async {
        guard let lab, let id = conversationID, let first = events.first?["seq"] as? Int else { return }
        if let r = try? await lab.request("/assistant/conversations/\(id)?before=\(first)&limit=60", timeout: 15) {
            events = (r["events"] as? [[String: Any]] ?? []) + events
            hasEarlier = r["earlier"] as? Bool ?? false
        }
    }

    func rename(_ title: String) async {
        guard let lab, let id = conversationID else { return }
        _ = try? await lab.request("/assistant/conversations/\(id)/rename", body: ["title": title], timeout: 10)
        self.title = title; await refreshList()
    }

    func delete(_ id: String) async {
        guard let lab else { return }
        do {
            _ = try await lab.request("/assistant/conversations/\(id)/delete", body: [:], timeout: 10)
            if id == conversationID { clear() }
            await refreshList()
        } catch { self.error = error.localizedDescription }
    }

    func setSettings(budget: Int? = nil, thinking: Bool? = nil, web: Bool? = nil, connectors: [String]? = nil) async {
        guard let lab else { return }
        if conversationID == nil { await newConversation() }  // settings chosen before the first message stay with it
        guard let id = conversationID else { return }
        var body: [String: Any] = [:]
        if let budget { body["budget"] = budget; self.budget = budget }
        if let thinking { body["thinking"] = thinking; self.thinking = thinking }
        if let web { body["web"] = web; self.web = web }
        if let connectors { body["connectors"] = connectors; self.connectors = connectors }
        _ = try? await lab.request("/assistant/conversations/\(id)/settings", body: body, timeout: 10)
        if web == true { await watchWeb() }
        if connectors != nil { await watchConnectors() }
    }

    // MARK: Connectors

    func loadConnectors() async {
        guard let lab, let r = try? await lab.request("/assistant/connectors", timeout: 10) else { return }
        available = r["connectors"] as? [[String: Any]] ?? []
    }

    func connector(_ id: String) -> [String: Any]? { available.first { $0["id"] as? String == id } }

    func toggleConnector(_ id: String) async {
        let on = connectors.contains(id) ? connectors.filter { $0 != id } : connectors + [id]
        await setSettings(connectors: on)
    }

    /// The connectors that are on, by name, and whether any sends data off this Mac.
    var activeConnectors: [[String: Any]] { connectors.compactMap { connector($0) } }

    /// Follows the connectors this conversation turned on while they start (npx may download a server first).
    func watchConnectors() async {
        for _ in 0..<90 {
            await loadConnectors()
            if !activeConnectors.contains(where: { $0["status"] as? String == "starting" }) { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The most tokens a model can read (from its config), cached by model id; nil if Dyno can't tell.
    func loadModelContext(_ id: String) async {
        guard let lab, modelContext[id] == nil,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let r = try? await lab.request("/assistant/model-context?model=\(encoded)", timeout: 10) else { return }
        modelContext[id] = r["context"] as? Int ?? 0
    }

    /// Reads each file on this Mac (PDF, Word, text, images with OCR) and attaches its text to the conversation.
    func attach(_ urls: [URL]) async {
        guard let lab, !urls.isEmpty, !busy else { return }
        if conversationID == nil { await newConversation() }
        guard let id = conversationID else { return }
        error = nil
        for url in urls {
            attaching = "Reading \(url.lastPathComponent)…"
            let access = url.startAccessingSecurityScopedResource()
            let result = await Task.detached(priority: .userInitiated) { Result { try DocumentReader.read(url) } }.value
            if access { url.stopAccessingSecurityScopedResource() }
            do {
                let doc = try result.get()
                attaching = "Attaching \(doc.name)…"
                let r = try await lab.request("/assistant/conversations/\(id)/documents",
                                              body: ["name": doc.name, "kind": doc.kind, "pages": doc.pages, "note": doc.note], timeout: 120)
                merge(r)
            } catch { self.error = error.localizedDescription }
        }
        attaching = nil
        await refreshList()
    }

    /// Follows SearXNG while it starts (the first time Docker downloads it, about 100 MB).
    func watchWeb() async {
        guard let lab else { return }
        for _ in 0..<600 {
            if let r = try? await lab.request("/assistant/web", timeout: 5) {
                webStatus = r["status"] as? String ?? "off"
                webError = r["error"] as? String
            }
            if webStatus != "starting" { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: A turn

    func send(_ text: String, context: [String: Any], model: [String: Any]) async {
        guard let lab else { return }
        if conversationID == nil { await newConversation() }
        guard let id = conversationID else { return }
        error = nil
        do {
            let r = try await lab.request("/assistant/conversations/\(id)/messages",
                                          body: ["text": text, "context": context, "model": model], timeout: 20)
            merge(r)
            poll()
        } catch { self.error = error.localizedDescription }
    }

    func decide(approve: Bool, note: String = "") async {
        guard let lab, let id = conversationID, let proposal = pending?["id"] as? String else { return }
        error = nil
        do {
            let r = try await lab.request("/assistant/conversations/\(id)/decide",
                                          body: ["proposal": proposal, "approve": approve, "note": note], timeout: 120)
            merge(r)
            poll()
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        guard let lab, let id = conversationID else { return }
        _ = try? await lab.request("/assistant/conversations/\(id)/stop", body: [:], timeout: 10)
    }

    private func poll() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let lab = self.lab, let id = self.conversationID else { return }
                if let r = try? await lab.request("/assistant/conversations/\(id)?after=\(self.lastSeq)&limit=500", timeout: 10) {
                    guard !Task.isCancelled, self.conversationID == id else { return }  // a new chat started meanwhile
                    self.merge(r)
                    if !self.busy { await self.refreshList(); return }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func merge(_ r: [String: Any]) {
        let new = (r["events"] as? [[String: Any]] ?? []).filter { ($0["seq"] as? Int ?? 0) > lastSeq }
        events += new
        lastSeq = events.last?["seq"] as? Int ?? lastSeq
        apply(r, newEvents: new)
    }

    private func apply(_ r: [String: Any], newEvents: [[String: Any]]) {
        let c = r["conversation"] as? [String: Any] ?? [:]
        status = c["status"] as? String ?? "idle"
        title = c["title"] as? String ?? ""
        plan = c["plan"] as? [[String: Any]] ?? []
        budget = c["budget"] as? Int ?? 32768
        thinking = c["thinking"] as? Bool ?? false
        web = c["web"] as? Bool ?? false
        connectors = c["connectors"] as? [String] ?? []
        let used = c["model"] as? [String: Any]
        conversationModel = (used?["model"] as? String).map { m in (used?["port"] as? Int).map { "\($0) \(m)" } ?? m }
        live = r["live"] as? [String: Any]
        pending = r["pending"] as? [String: Any]
        contextUse = r["context"] as? [String: Any]
        for e in newEvents where e["kind"] as? String == "ui" { onAction?(e) }
    }
}

extension Notification.Name {
    /// Settings → Connectors changed the list; the assistant reloads it.
    static let dynoConnectorsChanged = Notification.Name("dynoConnectorsChanged")
}
