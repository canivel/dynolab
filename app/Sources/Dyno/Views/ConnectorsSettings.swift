import AppKit
import SwiftUI

/// Settings → Connectors: the MCP servers the assistant can use (src/dyno/lab/connectors.py). Each conversation
/// turns them on with the + menu in the assistant. Values of environment variables and headers go to the login
/// Keychain through the lab, never to a file, and are never shown again.
struct ConnectorsSettings: View {
    @State private var connectors: [[String: Any]] = []
    @State private var loaded = false
    @State private var failed: String?
    @State private var editing: Draft?
    @State private var pasting = false
    @State private var testing: String?
    @State private var message: String?

    private var lab: ResearchLab { MonitorModel.shared.researchLab }

    var body: some View {
        Form {
            Section {
                Text("Connectors give the assistant tools from MCP servers: apps on this Mac (a command, like the ones Claude Desktop runs) or services online (a URL). Turn one on for a conversation with + in the assistant.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add connector…") { editing = Draft() }
                    Button("Paste a config…") { pasting = true }
                        .help("Paste Claude Desktop's or Claude Code's {\"mcpServers\": …} JSON")
                    Spacer()
                    if loaded { Button("Refresh") { Task { await load() } } }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if !loaded {
                Text(failed ?? "Loading…").font(.callout).foregroundStyle(.secondary)
            } else if connectors.isEmpty {
                Section { Text("No connectors yet.").foregroundStyle(.secondary) }
            } else {
                ForEach(connectors.compactMap { $0["id"] as? String }, id: \.self) { id in
                    if let c = connectors.first(where: { $0["id"] as? String == id }) { row(c) }
                }
            }
            Section("How they're used") {
                Text("A tool that only reads (the server says so) runs at once if you allow it for that connector. Anything else waits for your approval in the chat, like starting a test. What a connector returns is treated as information, never as instructions. A remote connector receives what the assistant sends it, so it leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .sheet(item: $editing) { d in ConnectorEditor(draft: d) { saved in editing = nil; if let saved { Task { await didSave(saved) } } } }
        .sheet(isPresented: $pasting) { PasteConfig { added in pasting = false; if added { Task { await load(); changed() } } } }
    }

    private func row(_ c: [String: Any]) -> some View {
        let id = c["id"] as? String ?? ""
        let remote = c["remote"] as? Bool == true
        let tools = c["tools"] as? [[String: Any]] ?? []
        let status = c["status"] as? String ?? "stopped"
        return Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: remote ? "network" : "puzzlepiece.extension").foregroundStyle(remote ? .orange : DynoBrand.accent).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c["name"] as? String ?? "Connector").font(.headline)
                    Text(Self.where_(c)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 4) {
                    if testing == id || status == "starting" { ProgressView().controlSize(.mini) }
                    Circle().fill(status == "running" ? Color.green : status == "error" ? Color.orange : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    Text(status == "running" ? "\(tools.count) tools" : status == "error" ? "Didn't start" : testing == id ? "Starting…" : "Not running")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if status == "error", let e = c["error"] as? String {
                Text(e).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Run read-only tools without asking", isOn: Binding(get: { c["allow_reads"] as? Bool == true }, set: { on in
                Task { await setAllowReads(c, on) }
            }))
            if !tools.isEmpty {
                DisclosureGroup("Tools") {
                    ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .top) {
                            Text(t["name"] as? String ?? "").font(.caption.monospaced())
                            if t["read_only"] as? Bool == true { Text("reads").font(.caption2).foregroundStyle(.green) }
                            Spacer()
                            Text(t["description"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: 280, alignment: .trailing)
                        }
                    }
                }.font(.caption)
            }
            HStack {
                Button(status == "running" ? "Restart" : "Test") { Task { await test(id) } }.disabled(testing != nil)
                Button("Edit…") { editing = Draft(c) }
                Spacer()
                Button("Remove", role: .destructive) { Task { await remove(c) } }
            }
        }
    }

    static func where_(_ c: [String: Any]) -> String {
        if c["remote"] as? Bool == true { return c["url"] as? String ?? "" }
        return ([c["command"] as? String ?? ""] + (c["args"] as? [String] ?? [])).joined(separator: " ")
    }

    // MARK: Lab calls

    private func changed() { NotificationCenter.default.post(name: .dynoConnectorsChanged, object: nil) }

    /// The research service starts with the app; Settings can open first, so keep trying for a while.
    private func load() async {
        for _ in 0..<30 {
            if let r = try? await lab.request("/assistant/connectors", timeout: 10) {
                connectors = r["connectors"] as? [[String: Any]] ?? []; loaded = true; failed = nil; return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        failed = "The research service isn't running. Open the Lab tab once, then come back."
    }

    private func didSave(_ c: [String: Any]) async {
        await load(); changed()
        if let id = c["id"] as? String { await test(id) }
    }

    private func test(_ id: String) async {
        testing = id; message = nil
        defer { testing = nil }
        do {
            let r = try await lab.request("/assistant/connectors/test", body: ["id": id], timeout: 90)
            await load(); changed()
            let n = (r["tools"] as? [Any])?.count ?? 0
            message = r["status"] as? String == "running" ? "\(r["name"] as? String ?? "It") works: \(n) tools." : nil
        } catch { message = error.localizedDescription; await load() }
    }

    private func setAllowReads(_ c: [String: Any], _ on: Bool) async {
        var body = Draft(c).body
        body["allow_reads"] = on
        do { _ = try await lab.request("/assistant/connectors", body: body, timeout: 20); await load(); changed() }
        catch { message = error.localizedDescription }
    }

    private func remove(_ c: [String: Any]) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(c["name"] as? String ?? "this connector")?"
        alert.informativeText = "Its saved values are deleted from the Keychain. Conversations that used it keep their history."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { _ = try await lab.request("/assistant/connectors/delete", body: ["id": c["id"] as? String ?? ""], timeout: 20); await load(); changed() }
        catch { message = error.localizedDescription }
    }
}

/// A connector being added or edited. Saved values are never sent back: a row with an empty value keeps its value.
struct Draft: Identifiable {
    struct Pair: Identifiable { var id = UUID(); var key = ""; var value = ""; var saved = false }
    var id = UUID()
    var connectorID: String?
    var name = ""
    var transport = "stdio"
    var command = ""
    var args = ""
    var url = ""
    var env: [Pair] = []
    var headers: [Pair] = []
    var allowReads = false

    init() {}

    init(_ c: [String: Any]) {
        connectorID = c["id"] as? String
        name = c["name"] as? String ?? ""
        transport = c["transport"] as? String ?? "stdio"
        command = c["command"] as? String ?? ""
        args = (c["args"] as? [String] ?? []).map(Draft.quote).joined(separator: " ")
        url = c["url"] as? String ?? ""
        env = (c["env_keys"] as? [String] ?? []).map { Pair(key: $0, saved: true) }
        headers = (c["headers_keys"] as? [String] ?? []).map { Pair(key: $0, saved: true) }
        allowReads = c["allow_reads"] as? Bool == true
    }

    var body: [String: Any] {
        func values(_ pairs: [Pair]) -> [String: Any] {
            var out: [String: Any] = [:]
            for p in pairs where !p.key.trimmingCharacters(in: .whitespaces).isEmpty {
                out[p.key.trimmingCharacters(in: .whitespaces)] = p.value.isEmpty && p.saved ? NSNull() : p.value
            }
            return out
        }
        var b: [String: Any] = ["name": name, "transport": transport, "allow_reads": allowReads]
        if let connectorID { b["id"] = connectorID }
        if transport == "stdio" { b["command"] = command.trimmingCharacters(in: .whitespaces); b["args"] = Draft.split(args); b["env"] = values(env) }
        else { b["url"] = url.trimmingCharacters(in: .whitespaces); b["headers"] = values(headers) }
        return b
    }

    /// Arguments as a shell would split them: spaces separate, quotes keep spaces in one argument.
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, any = false
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { quote = ch; any = true }
            else if ch == " " || ch == "\t" || ch == "\n" { if !cur.isEmpty || any { out.append(cur) }; cur = ""; any = false }
            else { cur.append(ch) }
        }
        if !cur.isEmpty || any { out.append(cur) }
        return out
    }

    static func quote(_ a: String) -> String { a.isEmpty || a.contains(where: { $0 == " " || $0 == "\"" }) ? "'\(a)'" : a }
}

struct ConnectorEditor: View {
    @State var draft: Draft
    var done: ([String: Any]?) -> Void
    @State private var error: String?
    @State private var saving = false

    private var lab: ResearchLab { MonitorModel.shared.researchLab }

    /// Official MCP reference servers, to start from.
    private static let examples: [(String, String, String)] = [
        ("Files in a folder", "npx", "-y @modelcontextprotocol/server-filesystem ~/Documents"),
        ("Memory (a knowledge graph)", "npx", "-y @modelcontextprotocol/server-memory"),
        ("Fetch web pages", "uvx", "mcp-server-fetch"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.connectorID == nil ? "Add a connector" : "Edit \(draft.name)").font(.title3.weight(.semibold))
                Spacer()
                if draft.connectorID == nil {
                    Menu("Examples") {
                        ForEach(Self.examples, id: \.0) { e in
                            Button(e.0) { draft.name = e.0; draft.transport = "stdio"; draft.command = e.1; draft.args = e.2 }
                        }
                    }.fixedSize()
                }
            }
            Form {
                TextField("Name", text: $draft.name, prompt: Text("GitHub"))
                Picker("Runs", selection: $draft.transport) {
                    Text("On this Mac (a command)").tag("stdio")
                    Text("Remote (URL)").tag("http")
                    Text("Remote (SSE, older servers)").tag("sse")
                }
                if draft.transport == "stdio" {
                    TextField("Command", text: $draft.command, prompt: Text("npx"))
                    TextField("Arguments", text: $draft.args, prompt: Text("-y @modelcontextprotocol/server-filesystem ~/Papers"))
                    pairs("Environment variables", $draft.env, keyPrompt: "GITHUB_TOKEN")
                } else {
                    TextField("URL", text: $draft.url, prompt: Text("https://example.com/mcp"))
                    pairs("Headers", $draft.headers, keyPrompt: "Authorization")
                    Text("Servers that sign in through a browser (OAuth) aren't supported yet; use a token in a header, e.g. Authorization: Bearer ….")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Run read-only tools without asking", isOn: $draft.allowReads)
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Values are kept in the Keychain.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction).buttonStyle(.dynoPrimary)
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 540).dynoTheme()
    }

    private func pairs(_ title: String, _ list: Binding<[Draft.Pair]>, keyPrompt: String) -> some View {
        Section(title) {
            ForEach(list) { $p in
                HStack {
                    TextField("", text: $p.key, prompt: Text(keyPrompt)).frame(maxWidth: 170).disabled(p.saved)
                    SecureField("", text: $p.value, prompt: Text(p.saved ? "Saved (type to replace)" : "Value"))
                    Button { list.wrappedValue.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button("Add") { list.wrappedValue.append(Draft.Pair()) }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do { done(try await lab.request("/assistant/connectors", body: draft.body, timeout: 20)) }
        catch { self.error = error.localizedDescription }
    }
}

/// Paste the JSON Claude Desktop (claude_desktop_config.json) or Claude Code (.mcp.json) uses.
struct PasteConfig: View {
    var done: (Bool) -> Void
    @State private var text = ""
    @State private var error: String?
    private var lab: ResearchLab { MonitorModel.shared.researchLab }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a config").font(.title3.weight(.semibold))
            Text("The {\"mcpServers\": {…}} JSON from Claude Desktop (claude_desktop_config.json) or Claude Code (.mcp.json). Each server becomes a connector; tokens in it go to the Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.caption.monospaced()).frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }.keyboardShortcut(.defaultAction).buttonStyle(.dynoPrimary)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 540).dynoTheme()
    }

    private func add() async {
        do { _ = try await lab.request("/assistant/connectors/import", body: ["json": text], timeout: 30); done(true) }
        catch { self.error = error.localizedDescription }
    }
}
