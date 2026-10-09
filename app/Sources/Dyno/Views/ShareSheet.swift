import AppKit
import SwiftUI

/// What a Share sheet packages.
enum ShareKind {
    case test, run, evals

    var noun: String { switch self { case .test: "Agent test"; case .run: "Run result"; case .evals: "Evals table" } }
    var icon: String { switch self { case .test: "shippingbox"; case .run: "waveform.path.ecg"; case .evals: "tablecells" } }
    var suffix: String { switch self { case .test: ".dynotest.json"; case .run: ".dynorun.json"; case .evals: ".dynoeval.json" } }
    var summaryPrompt: String { switch self { case .test: "What it tests"; case .run: "What happened"; case .evals: "What this compares" } }
    var summaryExample: String {
        switch self {
        case .test: "Does a rule said once survive twelve unrelated requests?"
        case .run: "The load tester used production after the rule was said once."
        case .evals: "Rules said once vs in every prompt, three local models."
        }
    }
    var headline: String { switch self { case .test: "Share this test"; case .run: "Share this run"; case .evals: "Share these Evals" } }
    var thing: String { switch self { case .test: "test"; case .run: "run result"; case .evals: "Evals table" } }
    var color: Color { switch self { case .test: DynoBrand.accent; case .run: Color(red: 0.49, green: 0.78, blue: 1); case .evals: DynoBrand.violet } }
}

/// The fields every Share sheet asks for.
struct ShareFields {
    var title: String
    var summary: String
    var author: String
    var license: String
}

/// Dyno Research's upload limit.
let researchMaxBytes = 1_000_000

/// A deliberate publish flow: what is shared, what's inside it, the details, then save or publish.
/// `makePackage` builds the package from the fields; `optionsKey` changes when an option changes what is exported.
struct ShareSheet<Options: View>: View {
    var kind: ShareKind
    var suggestedTitle: String
    var optionsKey: String = ""
    var makePackage: (ShareFields) async throws -> [String: Any]
    @ViewBuilder var options: () -> Options

    @Environment(\.dismiss) private var dismiss
    @AppStorage("reviewerName") private var author = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var license = "CC-BY-4.0"
    @State private var preview: [String: Any]?
    @State private var previewIssue: String?
    @State private var loading = false
    @State private var working: String?
    @State private var issue: String?
    @State private var hasToken = ResearchToken.load() != nil
    @State private var published: URL?

    private var fields: ShareFields { ShareFields(title: title, summary: summary, author: author, license: license) }

    var body: some View {
        VStack(spacing: 0) {
            ShareHeader(kind: kind)
            Divider()
            if let published {
                ShareSuccess(kind: kind, url: published) { dismiss() }
            } else {
                form
                Divider()
                footer
            }
        }
        .frame(width: 760)
        .background(DynoBrand.background).dynoTheme()
        .onAppear { if title.isEmpty { title = suggestedTitle } }
        .task(id: optionsKey) { await loadPreview() }
    }

    private var form: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    ShareDetails(kind: kind, title: $title, summary: $summary, author: $author, license: $license)
                    options()
                }
                .frame(width: 330, alignment: .topLeading)
                SharePreviewCard(kind: kind, package: preview, loading: loading, issue: previewIssue)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(20)
        }
        .frame(minHeight: 420, maxHeight: 560)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            ResearchTokenRow(hasToken: $hasToken)
            if !hasToken {
                Text("A research token is needed to publish. Save file… works without one.").font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
            if let issue { ShareIssue(text: issue) }
            HStack(spacing: 10) {
                if let working { DynoSpinner(size: 13, color: DynoBrand.accent); Text(working).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save file…", action: save).disabled(working != nil)
                Button(action: publish) { Label("Publish to Dyno Research", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(.dynoPrimary).disabled(working != nil || !hasToken)
                    .help(hasToken ? "Uploads a private draft. You publish it on the site." : "Add your research token first.")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(DynoBrand.surface)
    }

    private func loadPreview() async {
        loading = true; previewIssue = nil
        defer { loading = false }
        do {
            let p = try await makePackage(fields)
            preview = p
            if title.trimmingCharacters(in: .whitespaces).isEmpty, let t = p["title"] as? String { title = t }
        } catch { previewIssue = error.localizedDescription }
    }

    private func save() {
        working = "Packaging…"; issue = nil
        Task { @MainActor in
            defer { working = nil }
            do { if try saveSharedPackage(try await makePackage(fields), suffix: kind.suffix) != nil { dismiss() } }
            catch { issue = error.localizedDescription }
        }
    }

    private func publish() {
        guard let token = ResearchToken.load() else { hasToken = false; return }
        working = "Packaging…"; issue = nil
        Task { @MainActor in
            defer { working = nil }
            do {
                let package = try await makePackage(fields)
                working = "Uploading to research.dynolab.dev…"
                let url = try await ResearchUpload.draft(package, token: token)
                withAnimation(.easeOut(duration: 0.2)) { published = url }
                NSWorkspace.shared.open(url)
            } catch { issue = error.localizedDescription }
        }
    }
}

// MARK: - Pieces

struct ShareHeader: View {
    var kind: ShareKind
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(kind.color)
                .frame(width: 44, height: 44).background(kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.headline).font(.title2.bold())
                Text("Uploads a private draft to research.dynolab.dev. Nothing is public until you publish it on the site.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }
}

struct ShareDetails: View {
    var kind: ShareKind
    @Binding var title: String
    @Binding var summary: String
    @Binding var author: String
    @Binding var license: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShareSectionTitle("Details")
            DynoFormField("Title", text: $title)
            DynoFormField(kind.summaryPrompt, text: $summary, axis: .vertical, example: kind.summaryExample)
            DynoFormField("Author", text: $author, example: "Your name, optional")
            VStack(alignment: .leading, spacing: 7) {
                Text("License").font(.subheadline.weight(.semibold))
                Picker("License", selection: $license) {
                    Text("CC BY 4.0").tag("CC-BY-4.0")
                    Text("CC0").tag("CC0-1.0")
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(license == "CC0-1.0" ? "Public domain: anyone can reuse it without credit." : "Anyone can reuse it, crediting you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShareSectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(DynoBrand.accent)
    }
}

struct ShareIssue: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// The research token in one row: connected, or a field to paste one.
struct ResearchTokenRow: View {
    @Binding var hasToken: Bool
    @State private var token = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasToken ? "checkmark.seal.fill" : "key").foregroundStyle(hasToken ? DynoBrand.accent : .secondary)
            if hasToken {
                Text("Connected to Dyno Research").font(.callout)
                Text("· token in your Keychain").font(.callout).foregroundStyle(.secondary)
                Button("Forget") { ResearchToken.delete(); hasToken = false }.buttonStyle(.link).font(.callout)
                Spacer()
            } else {
                SecureField("Research token (dyr_…)", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Button("Save") {
                    if ResearchToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) { hasToken = true; token = "" }
                }.disabled(!token.hasPrefix("dyr_"))
                Link("Create one ↗", destination: URL(string: "https://research.dynolab.dev/settings/agents")!).font(.callout)
                    .help("When you create it, tick “Allow private draft creation”: sharing uploads a private draft.")
                Text("Tick “Allow private draft creation”").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

struct ShareSuccess: View {
    var kind: ShareKind
    var url: URL
    var done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(DynoBrand.accent)
            Text("Draft uploaded").font(.title.bold())
            Text("Your \(kind.thing) is a private draft on Dyno Research. Review it on the page that just opened, then choose Publish when you're ready.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open the draft", systemImage: "safari") }
                Button("Done", action: done).buttonStyle(.dynoPrimary).keyboardShortcut(.defaultAction)
            }
            Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(40).frame(maxWidth: .infinity, minHeight: 360)
    }
}
