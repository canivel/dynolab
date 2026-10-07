import AppKit
import SwiftUI

/// Author and license, and the research token for publishing to Dyno Research. Shared by every Share sheet.
struct ResearchSharingFields: View {
    @Binding var author: String
    @Binding var license: String
    @Binding var hasToken: Bool
    var published: URL?
    /// One sentence on what the research page shows for this kind of package.
    var pageShows: String
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Author (optional)", text: $author).textFieldStyle(.roundedBorder).frame(width: 260)
                Picker("License", selection: $license) { Text("CC BY 4.0").tag("CC-BY-4.0"); Text("CC0").tag("CC0-1.0") }.frame(width: 200)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Publish to Dyno Research").font(.headline)
                Text("Uploads a private draft to research.dynolab.dev with your research token. \(pageShows) You review it there and choose to publish; the token can't publish by itself.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                tokenRow
                if let published {
                    Label("Uploaded as a private draft. Review and publish it on the page that just opened.", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(DynoBrand.accent)
                    Link(published.absoluteString, destination: published).font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var tokenRow: some View {
        if hasToken {
            HStack {
                Label("Research token saved in the Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(DynoBrand.accent)
                Button("Forget") { ResearchToken.delete(); hasToken = false; token = "" }.buttonStyle(.link).font(.caption)
            }
        } else {
            HStack {
                SecureField("Research token (dyr_…, with drafts:write)", text: $token).textFieldStyle(.roundedBorder)
                Button("Save") { if ResearchToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) { hasToken = true; token = "" } }.disabled(token.isEmpty)
            }
            Link("Create a token at research.dynolab.dev/settings/agents ↗", destination: URL(string: "https://research.dynolab.dev/settings/agents")!).font(.caption)
        }
    }
}

/// What a result share sheet packages: one finished test, or the Evals table (one batch or everything).
enum SharedResult {
    case run(room: String)
    case eval(batch: String?)

    var endpoint: String {
        switch self { case .run: "/sandbox/packages/export-run"; case .eval: "/sandbox/packages/export-eval" }
    }
    var suffix: String {
        switch self { case .run: ".dynorun.json"; case .eval: ".dynoeval.json" }
    }
}

/// Share a result: save it as a file, or publish it to Dyno Research as a private draft.
struct ResultShareView: View {
    var lab: ResearchLab
    var result: SharedResult
    var suggestedTitle: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reviewerName") private var author = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var license = "CC-BY-4.0"
    @State private var thinking = false
    @State private var issue: String?
    @State private var working = false
    @State private var hasToken = ResearchToken.load() != nil
    @State private var published: URL?

    private var isRun: Bool { if case .run = result { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(isRun ? "Share this result" : "Share these Evals", systemImage: "square.and.arrow.up").font(.title2.bold())
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField(isRun ? "What happened (optional)" : "What this compares (optional)", text: $summary, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
            if isRun {
                Toggle("Include thinking", isOn: $thinking).toggleStyle(.checkbox)
                    .help("The agents' private reasoning. Left out unless you tick this.")
            }
            ResearchSharingFields(author: $author, license: $license, hasToken: $hasToken, published: published, pageShows: pageShows)
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Packaging…" : "Save file…", action: save).disabled(working)
                Button("Publish to Dyno Research…", action: publish).buttonStyle(.dynoPrimary).disabled(working || !hasToken)
            }
        }
        .padding(20).frame(width: 580).background(DynoBrand.background).dynoTheme()
        .onAppear { if title.isEmpty { title = suggestedTitle } }
    }

    private var explanation: String {
        isRun
            ? "Packages this finished test: the setup, the model and limits, the team, a timeline of every step, the Observer's events and its verdict. The honeypot's fake secrets are replaced with [secret]. Results of the same test appear together on its page."
            : "Packages the Evals table: each scenario and config, the share of safe runs with its 95% range, rule-break and disclosure rates, and every run's outcome."
    }
    private var pageShows: String {
        isRun ? "The page shows the verdict, a timeline per agent, the team tree and the environment." : "The page shows the table as a heat map with ranges, and links each scenario to its test."
    }

    private func makePackage() async throws -> [String: Any] {
        var body: [String: Any] = ["title": title, "description": summary, "author": author, "license": license]
        switch result {
        case .run(let room): body["room"] = room; if thinking { body["thinking"] = true }
        case .eval(let batch): if let batch { body["batch"] = batch }
        }
        return try await lab.request(result.endpoint, body: body, timeout: 120)
    }

    private func save() {
        working = true; issue = nil
        Task { @MainActor in
            defer { working = false }
            do { if try saveSharedPackage(try await makePackage(), suffix: result.suffix) != nil { dismiss() } }
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
