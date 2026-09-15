import AppKit
import DynoKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct StudySharingView: View {
    let journal: ResearchJournal
    let study: ResearchStudy
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var thinking = false
    @State private var method = ""
    @State private var finding = ""
    @State private var limitations = ""
    @State private var preview = ""
    @State private var reviewed = false
    @State private var error = ""
    private var candidates: [ResearchEntry] { journal.entries.filter { !journal.archivedIDs.contains($0.id) && !["archive", "restore", "draft"].contains($0.kind) && $0.attachment == nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Share study").font(.title.bold()); Spacer(); Button("Close") { dismiss() } }
            Text("1 Select evidence → 2 Review package → 3 Publish on Dyno Research").font(.headline)
            if preview.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose what to share. Archived entries, working drafts, audio, attachments and raw connection logs are excluded.").foregroundStyle(.secondary)
                        ForEach(candidates) { entry in
                            Toggle("\(entry.kind.capitalized) · \(entry.title)", isOn: Binding(get: { selected.contains(entry.id) }, set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }))
                        }
                        Toggle("Include model-emitted thinking", isOn: $thinking)
                        Text("Method").font(.headline)
                        TextField("What did you test and how?", text: $method, axis: .vertical)
                        Text("Finding").font(.headline)
                        TextField("What did you observe? An inconclusive result is OK.", text: $finding, axis: .vertical)
                        Text("Limitations").font(.headline)
                        TextField("What can this experiment not establish?", text: $limitations, axis: .vertical)
                        Text("License: CC BY 4.0. Review prompts, context and notes for private information. Only share content you have the right to distribute.").font(.caption)
                    }
                }
                Button("Review sharing package") {
                    do { let p = CommunityStudy(study: study, entries: candidates.filter { selected.contains($0.id) }, includeThinking: thinking, method: method.trimmingCharacters(in: .whitespacesAndNewlines), finding: finding, limitations: limitations.trimmingCharacters(in: .whitespacesAndNewlines)); preview = String(data: try p.data(), encoding: .utf8) ?? ""; error = "" }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.dynoPrimary).disabled(selected.isEmpty || method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || limitations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("This is the exact package that will be saved. Edit it to redact private text. This does not change your local notebook.").foregroundStyle(.secondary)
                TextEditor(text: $preview).font(.system(.body, design: .monospaced)).frame(minHeight: 300).onChange(of: preview) { _, _ in reviewed = false }
                Toggle("I reviewed this content and have permission to share it publicly under the selected license.", isOn: $reviewed)
                HStack {
                    Button("Back") { preview = ""; reviewed = false }
                    Button("Save package & open publishing") {
                        do {
                            let data = Data(preview.utf8); _ = try CommunityStudy.read(data)
                            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Dyno-study-\(study.id.uuidString.prefix(8)).json"
                            if panel.runModal() == .OK, let url = panel.url {
                                try data.write(to: url, options: .atomic)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                NSWorkspace.shared.open(URL(string: "https://research.dynolab.dev/new")!)
                                error = "Package saved. On the website, sign in with GitHub, choose this file, then review the private draft and publish. Nothing has been uploaded automatically."
                            }
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.dynoPrimary).disabled(!reviewed)
                }
            }
            if !error.isEmpty { Text(error).font(.callout).textSelection(.enabled) }
        }.padding(24).frame(width: 740, height: 650, alignment: .topLeading).background(DynoBrand.background).textFieldStyle(.roundedBorder)
    }
}

struct StudyImportView: View {
    let journal: ResearchJournal
    @Environment(\.dismiss) private var dismiss
    @State private var package: CommunityStudy?
    @State private var data: Data?
    @State private var source = ""
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Import study").font(.title.bold()); Spacer(); Button("Close") { dismiss() } }
            Text("Download a study JSON from Dyno Research, then choose it here. You can read the evidence without starting a model.")
            Button("Choose study JSON…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 1_000_001 <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
                        let bytes = try Data(contentsOf: url); package = try CommunityStudy.read(bytes); data = bytes; error = ""
                    } catch { self.error = error.localizedDescription; package = nil; data = nil }
                }
            }
            if loading { ProgressView("Downloading the published study…") }
            TextField("Original study URL (optional, kept for attribution)", text: $source)
            if let p = package, let data {
                ScrollView { VStack(alignment: .leading, spacing: 12) { Text(p.title).font(.title2); Text(p.question); Text("\(p.entries.count) entries · \(p.model.name) · \(p.license)"); Text("Limitations").bold(); Text(p.limitations); Text("Omissions").bold(); Text(p.omissions.joined(separator: "\n")) } }
                Text("Creates a separate local study. Imported prompts remain inactive until you select a running endpoint and explicitly run them. Source bytes and a checksum are kept locally.").font(.caption)
                Button("Import as a new local study") {
                    do { let id = try p.importInto(journal.store, original: data, sourceURL: source.isEmpty ? "Downloaded study package; source URL not supplied" : source); journal.select(id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 660, height: 530, alignment: .topLeading).background(DynoBrand.background).textFieldStyle(.roundedBorder)
        .task(id: journal.incomingCommunityStudy) {
            guard let id = journal.incomingCommunityStudy else { return }
            loading = true; package = nil; data = nil
            defer { loading = false }
            do {
                source = "https://research.dynolab.dev/studies/" + id.uuidString.lowercased()
                let session = URLSession(configuration: .ephemeral, delegate: StudyDownloadDelegate(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let url = URL(string: "https://research.dynolab.dev/api/studies/" + id.uuidString.lowercased() + "/download")!
                var request = URLRequest(url: url); request.timeoutInterval = 30
                let (stream, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
                var bytes = Data()
                for try await byte in stream { try Task.checkCancellation(); guard bytes.count < 1_000_000 else { throw CocoaError(.fileReadTooLarge) }; bytes.append(byte) }
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard http.value(forHTTPHeaderField: "X-Content-SHA256") == hash else { throw CocoaError(.fileReadCorruptFile) }
                package = try CommunityStudy.read(bytes); data = bytes
            } catch { if !Task.isCancelled { self.error = "Could not download the study: " + error.localizedDescription + ". You can download its JSON in the browser and choose the file here." } }
        }
        .onDisappear { journal.incomingCommunityStudy = nil }
    }
}

private final class StudyDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
