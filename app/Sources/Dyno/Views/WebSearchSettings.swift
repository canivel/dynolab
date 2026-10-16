import SwiftUI

/// Settings → Web search: SearXNG on this Mac (free, Docker) or a paid search API, for the assistant and for
/// Claude Code and Codex running on a local model. A key goes to the login Keychain through the lab; it never
/// lands in a file.
struct WebSearchSettings: View {
    struct Provider: Identifiable, Hashable { var id: String; var name: String; var signup: String?; var hasKey: Bool }

    @State private var providers: [Provider] = []
    @State private var current = "searxng"
    @State private var chosen = "searxng"
    @State private var key = ""
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private var lab: ResearchLab { MonitorModel.shared.researchLab }
    private var selected: Provider? { providers.first { $0.id == chosen } }

    var body: some View {
        Section("Web search") {
            if providers.isEmpty {
                Text(failed ? (message ?? "The research service isn't running.") : "Loading…")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Search with", selection: $chosen) {
                    ForEach(providers) { p in Text(p.name).tag(p.id) }
                }
                if let p = selected, p.signup != nil {
                    SecureField(p.hasKey ? "Key saved in the Keychain (type to replace)" : "API key", text: $key)
                    HStack {
                        if let signup = p.signup, let url = URL(string: signup) { Link("Get a \(p.name) key", destination: url) }
                        Spacer()
                        if p.hasKey { Button("Remove key") { Task { await save(removing: true) } }.disabled(busy) }
                    }
                } else {
                    Text("Free. Runs SearXNG in Docker on this Mac; queries go from this Mac to Google, Bing, DuckDuckGo and others.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(chosen == current && key.isEmpty ? "Saved" : "Save") { Task { await save() } }
                        .disabled(busy || (chosen == current && key.isEmpty))
                    Button("Test") { Task { await test() } }.disabled(busy || chosen != current)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let message { Text(message).font(.caption).foregroundStyle(failed ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
                Text("Used by Dyno's assistant, and by Claude Code and Codex when they run on a local model through Dyno.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
        .onChange(of: chosen) { message = nil; failed = false; key = "" }
    }

    private func apply(_ r: [String: Any]) {
        providers = (r["providers"] as? [[String: Any]] ?? []).map {
            Provider(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", signup: $0["signup"] as? String, hasKey: $0["has_key"] as? Bool == true)
        }
        current = r["provider"] as? String ?? "searxng"
    }

    /// The research service starts with the app; Settings can open first, so keep trying for a while.
    private func load() async {
        for _ in 0..<30 {
            if let r = try? await lab.request("/assistant/web/providers", timeout: 10) {
                apply(r); chosen = current; failed = false; message = nil; return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        failed = true; message = "The research service isn't running. Open the Lab tab once, then come back."
    }

    private func save(removing: Bool = false) async {
        busy = true; defer { busy = false }
        var body: [String: Any] = ["provider": removing ? "searxng" : chosen]
        if removing { body = ["provider": chosen, "api_key": ""] } else if !key.isEmpty { body["api_key"] = key }
        do {
            if removing {
                // Removing the key also returns search to SearXNG, which needs none.
                _ = try? await lab.request("/assistant/web/providers", body: body, timeout: 20)
                apply(try await lab.request("/assistant/web/providers", body: ["provider": "searxng"], timeout: 20))
            } else {
                apply(try await lab.request("/assistant/web/providers", body: body, timeout: 20))
            }
            chosen = current; key = ""; failed = false
            message = removing ? "Key removed. Searching with SearXNG." : "Saved."
        } catch { failed = true; message = error.localizedDescription }
    }

    private func test() async {
        busy = true; defer { busy = false }
        message = current == "searxng" ? "Searching (the first time, Docker downloads SearXNG, about 100 MB)…" : "Searching…"
        do {
            let r = try await lab.request("/assistant/web/test", body: ["query": "Apple silicon"], timeout: 240)
            let first = (r["results"] as? [[String: Any]])?.first?["title"] as? String
            failed = first == nil
            message = first.map { "Works. First result: \($0)" } ?? "No results came back."
        } catch { failed = true; message = error.localizedDescription }
    }
}
