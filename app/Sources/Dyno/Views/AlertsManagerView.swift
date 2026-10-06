import SwiftUI

/// The person's Observer alerts: checks on what agents think, say and do. Every test that starts
/// runs the alerts that are on, and keeps a copy of them, so editing an alert later never
/// changes a past test.
struct AlertsManagerView: View {
    var lab: ResearchLab
    var servers: [(port: Int, label: String, model: String)]
    @Environment(\.dismiss) private var dismiss
    @State private var alerts: [[String: Any]] = []
    @State private var selectedID: String?
    @State private var draft = AlertDraft()
    @State private var issue: String?
    @State private var saving = false
    // Try on a past test
    @State private var rooms: [[String: Any]] = []
    @State private var tryRoom = ""
    @State private var tryResult: [String: Any]?

    struct AlertDraft: Equatable {
        var id: String? = nil
        var name = "New alert"
        var description = ""
        var severity = "warning"
        var enabled = true
        var kind = "phrases"
        var reads: Set<String> = ["thinking"]
        var phrases = ""
        var regex = false
        var question = ""
        var modelPort: Int? = nil

        init() {}
        init(_ a: [String: Any]) {
            id = a["id"] as? String; name = a["name"] as? String ?? ""; description = a["description"] as? String ?? ""
            severity = a["severity"] as? String ?? "warning"; enabled = a["enabled"] as? Bool ?? true; kind = a["kind"] as? String ?? "phrases"
            reads = Set(a["reads"] as? [String] ?? []); phrases = (a["phrases"] as? [String] ?? []).joined(separator: "\n")
            regex = a["regex"] as? Bool ?? false; question = a["question"] as? String ?? ""; modelPort = a["model_port"] as? Int
        }
        func body(servers: [(port: Int, label: String, model: String)]) -> [String: Any] {
            var b: [String: Any] = ["name": name, "description": description, "severity": severity, "enabled": enabled, "kind": kind,
                                    "reads": SOURCES.map(\.0).filter { reads.contains($0) }]
            if let id { b["id"] = id }
            if kind == "phrases" {
                b["phrases"] = phrases.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                b["regex"] = regex
            } else {
                b["question"] = question
                b["model_port"] = modelPort.map { $0 as Any } ?? NSNull()
                if let p = modelPort, let s = servers.first(where: { $0.port == p }) { b["model"] = s.model }
            }
            return b
        }
    }
    static let SOURCES: [(String, String)] = [("thinking", "Thinking"), ("messages", "Messages to the team"), ("commands", "Commands"),
                                              ("outputs", "Command output"), ("reports", "Final report")]
    private var SOURCES: [(String, String)] { Self.SOURCES }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bell.badge").font(.title2).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Observer alerts").font(.title2.bold())
                    Text("Your own checks on what the agents think, say and do. They run inside the Observer, so the agents never know. Each test keeps the alerts it ran with.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 14) {
                list.frame(width: 300)
                editor.frame(maxWidth: .infinity)
            }
        }
        .padding(20).frame(minWidth: 1000, idealWidth: 1100, minHeight: 640, idealHeight: 720)
        .background(DynoBrand.background).dynoTheme()
        .task {
            await load()
            if let first = alerts.first { pick(first) }
            if let list = (try? await lab.request("/sandbox/rooms"))?["rooms"] as? [[String: Any]] {
                rooms = list.filter { $0["status"] as? String != "running" }
                tryRoom = rooms.first?["id"] as? String ?? ""
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(alerts.indices, id: \.self) { i in
                        let a = alerts[i], id = a["id"] as? String
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { a["enabled"] as? Bool ?? false }, set: { on in toggle(a, on) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a["name"] as? String ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                                Text((a["kind"] as? String == "llm" ? "Model check" : "Words or phrases") + " · reads " + ((a["reads"] as? [String] ?? []).joined(separator: ", ")))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.padding(8).contentShape(Rectangle()).onTapGesture { pick(a) }
                        .background(RoundedRectangle(cornerRadius: 8).fill(id == selectedID ? DynoBrand.accent.opacity(0.14) : Color.clear))
                    }
                }
            }
            Button { selectedID = nil; draft = AlertDraft(); tryResult = nil } label: { Label("New alert", systemImage: "plus").frame(maxWidth: .infinity) }
            Text("On means every new test runs it.").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.surface))
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                EvalCard(title: draft.id == nil ? "New alert" : "Edit alert") {
                    TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).font(.title3)
                    TextField("What it means (optional)", text: $draft.description).textFieldStyle(.roundedBorder)
                    HStack(spacing: 16) {
                        Toggle("On for new tests", isOn: $draft.enabled)
                        Picker("Severity", selection: $draft.severity) { Text("Warning").tag("warning"); Text("Info").tag("info") }.frame(width: 200)
                    }
                    Text("Reads").font(.callout.weight(.semibold))
                    HStack(spacing: 14) {
                        ForEach(SOURCES, id: \.0) { key, label in
                            Toggle(label, isOn: Binding(get: { draft.reads.contains(key) }, set: { if $0 { draft.reads.insert(key) } else { draft.reads.remove(key) } }))
                                .toggleStyle(.checkbox)
                        }
                    }
                    Text("Thinking is each agent's private reasoning. The other agents never see it.").font(.caption2).foregroundStyle(.secondary)
                    Picker("Decides by", selection: $draft.kind) { Text("Words or phrases").tag("phrases"); Text("Asking a model").tag("llm") }
                        .pickerStyle(.segmented).frame(maxWidth: 380)
                    if draft.kind == "phrases" {
                        Text("One per line. Fires when any of them appears, ignoring case. A phrase matches whole words only, so “eval” doesn't match “evaluate”.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.phrases).font(.system(.callout, design: .monospaced)).frame(minHeight: 150)
                            .scrollContentBackground(.hidden).padding(6).background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.background))
                        Toggle("Lines are regular expressions", isOn: $draft.regex).toggleStyle(.checkbox).font(.caption)
                    } else {
                        Text("A model reads each passage and answers this yes-or-no question. It catches what a phrase list misses, but it's slower: it runs in the background, so the agents never wait.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        TextField("Question", text: $draft.question, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                        Picker("Model", selection: $draft.modelPort) {
                            Text("The lead agent's model").tag(Int?.none)
                            ForEach(servers, id: \.port) { s in Text("\(s.label) · :\(String(s.port))").tag(Int?.some(s.port)) }
                        }.frame(maxWidth: 420)
                    }
                    HStack {
                        if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        if draft.id != nil { Button("Delete", role: .destructive, action: delete) }
                        Button(saving ? "Saving…" : "Save", action: save).buttonStyle(.dynoPrimary).disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.reads.isEmpty)
                    }
                }
                if draft.kind == "phrases" { tryCard }
            }
        }
    }

    private var tryCard: some View {
        EvalCard(title: "Try it on a past test") {
            HStack {
                Picker("Test", selection: $tryRoom) {
                    ForEach(rooms.indices, id: \.self) { i in
                        let r = rooms[i]
                        Text("\(r["title"] as? String ?? "Room") · \((r["created"] as? Double).map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "")").tag(r["id"] as? String ?? "")
                    }
                }.frame(maxWidth: 520)
                Button("Try", action: tryIt).disabled(tryRoom.isEmpty)
            }
            if let r = tryResult {
                let hits = r["hits"] as? [[String: Any]] ?? []
                Text(hits.isEmpty ? "It wouldn't have fired on that test." : "It would have fired \(hits.count) time\(hits.count == 1 ? "" : "s"):")
                    .font(.callout.weight(.semibold))
                ForEach(hits.prefix(30).indices, id: \.self) { i in
                    let h = hits[i]
                    HStack(alignment: .top, spacing: 8) {
                        Text(h["agent"] as? String ?? "").font(.caption.bold()).frame(width: 100, alignment: .leading)
                        Text(h["source"] as? String ?? "").font(.caption2).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text("“\(h["quote"] as? String ?? "")”").font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func pick(_ a: [String: Any]) { selectedID = a["id"] as? String; draft = AlertDraft(a); issue = nil; tryResult = nil }

    private func load() async {
        if let d = try? await lab.request("/sandbox/alerts", timeout: 15) { alerts = d["alerts"] as? [[String: Any]] ?? [] }
    }

    private func toggle(_ a: [String: Any], _ on: Bool) {
        var d = AlertDraft(a); d.enabled = on
        Task {
            _ = try? await lab.request("/sandbox/alerts", body: d.body(servers: servers), timeout: 15)
            await load()
            if selectedID == d.id { draft.enabled = on }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                let saved = try await lab.request("/sandbox/alerts", body: draft.body(servers: servers), timeout: 15)
                await load(); pick(saved); issue = nil
            } catch { issue = error.localizedDescription }
            saving = false
        }
    }

    private func delete() {
        guard let id = draft.id else { return }
        Task {
            _ = try? await lab.request("/sandbox/alerts/delete", body: ["id": id], timeout: 15)
            await load()
            if let first = alerts.first { pick(first) } else { draft = AlertDraft(); selectedID = nil }
        }
    }

    private func tryIt() {
        var alert = draft.body(servers: servers)
        alert["enabled"] = nil; alert["description"] = nil; alert["severity"] = nil
        Task {
            do { tryResult = try await lab.request("/sandbox/alerts/try", body: ["alert": alert, "room": tryRoom], timeout: 60); issue = nil }
            catch { issue = error.localizedDescription }
        }
    }
}
