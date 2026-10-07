import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Writes a test package to a file the person chooses. Returns the file, or nil when they cancel.
@MainActor
func saveTestPackage(_ package: [String: Any]) throws -> URL? {
    let data = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let panel = NSSavePanel()
    let title = (package["title"] as? String ?? "test").lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    panel.nameFieldStringValue = String(title.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + ".dynotest.json"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    try data.write(to: url)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    return url
}

/// Share the current setup as a test package.
struct TestPackageShareView: View {
    var lab: ResearchLab
    var harnessDir: String
    var spec: [String: Any]
    var suggestedTitle: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reviewerName") private var author = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var license = "CC-BY-4.0"
    @State private var issue: String?
    @State private var working = false
    @State private var token = ResearchToken.load() ?? ""
    @State private var hasToken = ResearchToken.load() != nil
    @State private var published: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Share this test", systemImage: "square.and.arrow.up").font(.title2.bold())
            Text("Saves the whole setup in one file: the environment with its files, the goal, the rules, the lead agent, the prompt, alerts, script and history. It holds no model: whoever imports it picks one on their own Mac. Publish it to Dyno Research and others import it from its link, or send the file itself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("What it tests (optional)", text: $summary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            HStack {
                TextField("Author (optional)", text: $author).textFieldStyle(.roundedBorder).frame(width: 260)
                Picker("License", selection: $license) { Text("CC BY 4.0").tag("CC-BY-4.0"); Text("CC0").tag("CC0-1.0") }.frame(width: 200)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Publish to Dyno Research").font(.headline)
                Text("Uploads a private draft to research.dynolab.dev with your research token. The page shows the environment as a diagram, the rules, the script, and Open in Dyno. You review it there and choose to publish; the token can't publish by itself.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if hasToken {
                    HStack {
                        Label("Research token saved in the Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(DynoBrand.accent)
                        Button("Forget") { ResearchToken.delete(); hasToken = false; token = "" }.buttonStyle(.link).font(.caption)
                    }
                } else {
                    HStack {
                        SecureField("Research token (dyr_…, with drafts:write)", text: $token).textFieldStyle(.roundedBorder)
                        Button("Save") { if ResearchToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) { hasToken = true } }.disabled(token.isEmpty)
                    }
                    Link("Create a token at research.dynolab.dev/settings/agents ↗", destination: URL(string: "https://research.dynolab.dev/settings/agents")!).font(.caption)
                }
                if let published {
                    Label("Uploaded as a private draft. Review and publish it on the page that just opened.", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(DynoBrand.accent)
                    Link(published.absoluteString, destination: published).font(.caption)
                }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Packaging…" : "Save file…", action: share).disabled(working)
                Button("Publish to Dyno Research…", action: publish).buttonStyle(.dynoPrimary).disabled(working || !hasToken)
            }
        }
        .padding(20).frame(width: 560).background(DynoBrand.background).dynoTheme()
        .onAppear { if title.isEmpty { title = suggestedTitle.isEmpty ? String((spec["goal"] as? String ?? "").prefix(80)) : suggestedTitle } }
    }

    private func makePackage() async throws -> [String: Any] {
        var body: [String: Any] = ["spec": spec, "title": title, "description": summary, "author": author]
        if !harnessDir.isEmpty { body["harness_dir"] = harnessDir }
        var package = try await lab.request("/sandbox/packages/export", body: body, timeout: 60)
        package["license"] = license
        package.removeValue(forKey: "hash")  // the license changed the content; Dyno Research hashes what it stores
        return package
    }

    private func share() {
        working = true
        Task { @MainActor in
            defer { working = false }
            do { if try saveTestPackage(try await makePackage()) != nil { dismiss() } }
            catch { issue = error.localizedDescription }
        }
    }

    private func publish() {
        guard let token = ResearchToken.load() else { hasToken = false; return }
        working = true; issue = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let url = try await ResearchUpload.draft(try await makePackage(), token: token)
                published = url
                NSWorkspace.shared.open(url)
            } catch { issue = error.localizedDescription }
        }
    }
}

/// Import a shared test package: preview everything it creates and runs, then fill in Setup.
struct TestPackageImportView: View {
    var lab: ResearchLab
    var harnessDir: String
    var initialLink = ""
    var onImported: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var fileText: String?
    @State private var fileName: String?
    @State private var preview: [String: Any]?
    @State private var issue: String?
    @State private var working = false

    private var source: [String: Any] {
        var b: [String: Any] = [:]
        if let fileText { b["package"] = fileText } else { b["url"] = link.trimmingCharacters(in: .whitespaces) }
        if !harnessDir.isEmpty { b["harness_dir"] = harnessDir }
        return b
    }
    private var env: [String: Any] { preview?["environment"] as? [String: Any] ?? [:] }
    private var envOK: Bool { env["action"] as? String != "save" || ((env["validation"] as? [String: Any])?["ok"] as? Bool == true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import a test", systemImage: "square.and.arrow.down.on.square").font(.title2.bold())
            HStack {
                TextField("research.dynolab.dev link to a shared test", text: $link)
                    .textFieldStyle(.roundedBorder).onSubmit(load)
                    .onChange(of: link) { _, new in if !new.isEmpty { fileText = nil; fileName = nil; preview = nil } }  // typing a link replaces a file
                Button("Open file…", action: openFile)
                Button(working ? "Reading…" : "Preview", action: load).disabled(working || (fileText == nil && link.isEmpty))
            }
            if let fileName { Text("File: \(fileName)").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                if let p = preview { summary(p).frame(maxWidth: .infinity, alignment: .leading) }
                else { Text("Preview a package to see what it holds, what it will save on this Mac, and everything its test runs. Nothing is saved or run until you import it, and importing runs nothing either.").foregroundStyle(.secondary) }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import into Setup", action: importIt).buttonStyle(.dynoPrimary).disabled(working || preview == nil || !envOK)
            }
        }
        .padding(20).frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 680).background(DynoBrand.background).dynoTheme()
        .onAppear { if !initialLink.isEmpty && link.isEmpty { link = initialLink; load() } }
    }

    @ViewBuilder private func summary(_ p: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p["title"] as? String ?? "").font(.title3.bold())
            let byline = [p["author"] as? String, p["created"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !byline.isEmpty { Text(byline).font(.caption).foregroundStyle(.secondary) }
            if let d = p["description"] as? String, !d.isEmpty { Text(d).font(.callout) }
            if p["hash_ok"] as? Bool == false { Label("The package was edited after it was made (its hash doesn't match). That's fine if you expected it.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            EvalCard(title: "The test") {
                Text(p["goal"] as? String ?? "").font(.callout).lineLimit(6)
                ForEach(((p["rules"] as? [[String: Any]]) ?? []).indices, id: \.self) { i in
                    let r = ((p["rules"] as? [[String: Any]]) ?? [])[i]
                    Text("\(i + 1). \(r["text"] as? String ?? "")" + (r["delivery"] as? String == "chat_once" ? "  · said once" : "")).font(.caption)
                }
                let lead = p["lead"] as? [String: Any] ?? [:]
                Text("Lead: \(lead["name"] as? String ?? "") · author's model: \((lead["model_hint"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "not given"). You'll pick a model running on this Mac.").font(.caption).foregroundStyle(.secondary)
                Text("\(p["alerts"] as? Int ?? 0) alerts · \(p["script"] as? Int ?? 0) scripted messages · \(p["history"] as? Int ?? 0) history turns").font(.caption).foregroundStyle(.secondary)
            }
            EvalCard(title: "What it saves on this Mac") {
                Text(envLine).font(.callout)
                ForEach(((env["validation"] as? [String: Any])?["errors"] as? [String]) ?? [], id: \.self) { Label($0, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                Text(promptLine).font(.callout)
            }
            EvalCard(title: "What its test runs (inside the gVisor sandbox)") {
                let runs = p["runs"] as? [[String: Any]] ?? []
                if runs.isEmpty { Text("A plain machine: no services.").font(.caption).foregroundStyle(.secondary) }
                ForEach(runs.indices, id: \.self) { i in
                    let r = runs[i]
                    Text("\(r["node"] as? String ?? ""): \(r["image"] as? String ?? "") · \(r["runs"] as? String ?? "nothing")").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var envLine: String {
        let id = env["id"] as? String ?? ""
        switch env["action"] as? String {
        case "plain": return "Environment: a plain machine."
        case "reuse": return "Environment: \(id), already on this Mac. It will be reused."
        default: return "Environment: saved as \(id)" + (env["renamed"] as? Bool == true ? ", a new id, because yours with the same name is different." : ".")
        }
    }
    private var promptLine: String {
        let p = preview?["prompt"] as? [String: Any] ?? [:]
        switch p["action"] as? String {
        case "reuse": return "Agent prompt: \(p["name"] as? String ?? "") v\(p["version"] as? Int ?? 1), already on this Mac."
        case "save": return "Agent prompt: saved as “\(p["name"] as? String ?? "")”."
        default: return "Agent prompt: the built-in one."
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        link = ""
        fileText = text; fileName = url.lastPathComponent
        load()
    }

    private func load() {
        working = true; issue = nil
        Task { @MainActor in
            defer { working = false }
            do { preview = try await lab.request("/sandbox/packages/preview", body: source, timeout: 60) }
            catch { preview = nil; issue = error.localizedDescription }
        }
    }

    private func importIt() {
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let result = try await lab.request("/sandbox/packages/import", body: source, timeout: 90)
                if let setup = result["setup"] as? [String: Any] { onImported(setup); dismiss() }
            } catch { issue = error.localizedDescription }
        }
    }
}
