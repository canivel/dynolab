import AppKit
import DynoKit
import SwiftUI

struct ResearchJournalView: View {
    var model: MonitorModel
    private var journal: ResearchJournal { model.researchLab.journal }
    @State private var creating = false
    @State private var sharing = false
    @State private var importing = false
    @State private var title = ""
    @State private var question = ""
    @State private var hypothesis = ""
    @State private var search = ""
    @State private var showArchived = false
    @State private var showLive = false
    private var voice: ResearchVoiceNote { journal.voice }
    private var study: ResearchStudy? { journal.studies.first { $0.id == journal.selected } }
    private var runtimeReady: Bool { model.researchLab.runtime.ready(journal.input.port, model: journal.input.model) && servers.contains { $0.port == journal.input.port && $0.identifier == journal.input.model } }
    private var servers: [LLMModel] { model.snapshot.models.filter { $0.port != nil } }
    var body: some View {
        @Bindable var journal = journal
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your studies").font(.title2.bold())
                Text("A question, its evidence, and how your understanding changes.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("New study", systemImage: "plus") { creating = true }.disabled(journal.running || voice.recording || voice.transcribing || voice.requestingMicrophone || voice.audio != nil)
                Button("Import study", systemImage: "square.and.arrow.down") { importing = true }.disabled(journal.running)
                Button("Refresh studies") { journal.reload() }
                ScrollView {
                    ForEach(journal.studies) { item in
                        Button { journal.select(item.id) } label: {
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline)
                                Text(item.question).font(.caption).lineLimit(2)
                                Text(item.created.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                .background(journal.selected == item.id ? DynoBrand.lime.opacity(0.16) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(journal.running || voice.recording || voice.transcribing || voice.requestingMicrophone || voice.audio != nil)
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
                Text("Saved locally · append-only history\nCorrections and revisions become new entries.").font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(minWidth: 230, idealWidth: 260, maxWidth: 320, maxHeight: .infinity, alignment: .topLeading)
            if let study {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { Text(study.title).font(.largeTitle.bold()); Spacer(); Button("Share study", systemImage: "square.and.arrow.up") { sharing = true }; Menu("More") { Button("Export full private notebook") { journal.export() } } }
                        Text(study.question).font(.title3)
                        if !study.hypothesis.isEmpty { Text("Initial hypothesis: \(study.hypothesis)") }
                        Text("Keep observations separate from interpretations. Record disconfirming examples, output limits and alternative explanations.").font(.caption).foregroundStyle(.secondary)
                        if let error = journal.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if !journal.pendingWrites.isEmpty {
                            Text("Unsaved entries: \(journal.pendingWrites.count). Keep this app open until saving succeeds.").foregroundStyle(.red)
                            Button("Retry saving entries") { journal.retryWrites() }
                            ForEach(Array(journal.pendingWrites.values)) { entry in entryCard(entry) }
                        }
                        GroupBox("Prompt iteration") { iterationForm }
                        GroupBox("Journal entry") { noteForm }
                        HStack { Text("Timeline").font(.title2); Spacer(); TextField("Search entries", text: $search).frame(maxWidth: 230) }
                        Text("Select an entry to attach observations to it. Revise starts a separate test; Follow up includes the saved conversation and answer.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Show archived queries", isOn: $showArchived).toggleStyle(.switch)
                        Text("Archive hides a query and its result from this timeline. Restore it with Show archived queries. Notes, branches and exported evidence stay intact.").font(.caption).foregroundStyle(.secondary)
                        ForEach(journal.entries.filter { !["archive", "restore"].contains($0.kind) && (showArchived || !journal.archivedIDs.contains($0.id)) && (search.isEmpty || ($0.title + $0.body + ($0.answer ?? "")).localizedCaseInsensitiveContains(search)) }) { entry in
                            entryCard(entry)
                        }
                        if journal.entries.isEmpty { ContentUnavailableView("Start with your question", systemImage: "book", description: Text("Save a baseline prompt or a planning note. Each later result and observation stays in this timeline.")) }
                    }.padding(22)
                }.frame(minWidth: 600, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Your research starts here", systemImage: "book.closed", description: Text("Create a study with a question and initial hypothesis. Save each prompt, result and observation as the investigation develops."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(journal.completionAlert?.hitTokenLimit == true ? "Output token limit reached" : "No final answer returned", isPresented: $journal.showingCompletionAlert, presenting: journal.completionAlert) { entry in
            if let retry = entry.largerBudgetRetry {
                Button("Prepare retry with \(retry.maxTokens) tokens") { journal.prepareLongerRetry(entry) }
            }
            Button("Close", role: .cancel) { }
        } message: { entry in
            Text((entry.completionWarning ?? "") + (entry.largerBudgetRetry != nil ? "\n\nThe retry button prepares the prompt editor; it does not run automatically." : ""))
        }
        .onChange(of: journal.running) { _, running in if running { showLive = true } }
        .sheet(isPresented: $showLive) {
            ResearchLiveResponseView(journal: journal) { showLive = false }
        }
        .onAppear { journal.reload(); if journal.running { showLive = true }; if journal.incomingCommunityStudy != nil { importing = true } }
        .onChange(of: journal.incomingCommunityStudy) { _, id in if id != nil { importing = true } }
        .onDisappear { voice.stop(); voice.cancelTranscription() }
        .sheet(isPresented: $sharing) { if let study { StudySharingView(journal: journal, study: study) } }
        .sheet(isPresented: $importing) { StudyImportView(journal: journal) }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Start a research study").font(.title2)
                TextField("Study title", text: $title)
                TextField("Research question", text: $question)
                TextField("Initial hypothesis (optional)", text: $hypothesis)
                Text("What result would change your mind? You can record a plan and success criteria as your first journal entry.").font(.caption)
                HStack { Button("Cancel") { creating = false }; Spacer(); Button("Create study") { journal.create(title: title, question: question, hypothesis: hypothesis); title = ""; question = ""; hypothesis = ""; creating = false }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || question.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 520)
        }
    }
    private var iterationForm: some View {
        @Bindable var journal = journal
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Iteration title", text: $journal.runTitle)
            Picker("Running model", selection: Binding(get: { journal.input.port }, set: { port in
                journal.input.port = port; journal.input.model = servers.first { $0.port == port }?.identifier ?? ""
            })) {
                Text("Select a running endpoint").tag(UInt16(0))
                ForEach(servers) { item in Text("\(item.name) · :\(item.port!)").tag(item.port!) }
            }
            if !runtimeReady { Text("Execution locked until this prompt’s selected model or pool is running and reachable. You can still read history and save planning notes.").font(.caption).foregroundStyle(.orange) }
            if servers.isEmpty { Text("Start a model in Models or a pool in Pools. You can write and save prompts without running a model.").font(.caption).foregroundStyle(.secondary) }
            if let parent = journal.parent { HStack { Text("Branches from \(parent.uuidString.prefix(8)) · \(journal.input.context.count) prior messages").font(.caption); Button("New independent prompt") { journal.parent = nil; journal.input.context = [] } } }
            TextEditor(text: $journal.input.prompt).font(.body).frame(height: 100).border(Color.secondary.opacity(0.2))
            if journal.running || !journal.liveThinking.isEmpty || !journal.liveAnswer.isEmpty {
                Button { showLive = true } label: { Label(journal.running ? "Show live thinking and answer" : "View last streamed response", systemImage: "waveform") }.buttonStyle(.dynoPrimary)
                if journal.running { Text(journal.liveStatus).font(.caption).foregroundStyle(.secondary) }
            }
            generationControls
            DisclosureGroup("Advanced · system instruction, temperature and conversation") {
                TextField("System instruction", text: $journal.input.system)
                HStack { Text("Temperature"); TextField("Temperature", value: $journal.input.temperature, format: .number).frame(width: 70); Text("Seed"); TextField("Seed", value: $journal.input.seed, format: .number).frame(width: 100) }
                Text("Thinking support depends on the endpoint. Emitted reasoning is model output, not a verified account of computation. This request does not capture activations.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(journal.input.context.enumerated()), id: \.offset) { _, message in Text("\(message.role): \(message.content)").font(.caption).textSelection(.enabled) }
            }
            HStack {
                Button("Save prompt draft") { _ = journal.save(ResearchEntry(kind: "draft", title: journal.runTitle, parent: journal.parent, iteration: journal.input)) }.disabled(journal.input.prompt.isEmpty)
                Button { if runtimeReady { journal.run() } } label: { Label(journal.running ? "Running…" : "Run and save iteration", systemImage: "play.fill") }.buttonStyle(.dynoPrimary).controlSize(.large).disabled(!runtimeReady || journal.running || !journal.pendingWrites.isEmpty || journal.input.port == 0 || journal.input.prompt.isEmpty || !journal.input.temperature.isFinite || !(0...2).contains(journal.input.temperature))
                if journal.running { ProgressView().controlSize(.small); Button("Cancel request") { journal.task?.cancel() } }
            }
            Text("Prompt and note working copies are saved automatically. Save a draft entry to freeze a version in the timeline. Runs are recorded before submission, then receive a separate result, cancellation or error entry. No earlier entry is overwritten.").font(.caption).foregroundStyle(.secondary)
        }.padding(8)
    }
    private var generationControls: some View {
        @Bindable var journal = journal
        return VStack(alignment: .leading, spacing: 12) {
            Label("Generation settings", systemImage: "slider.horizontal.3").font(.headline)
            Text("Thinking").font(.subheadline.bold())
            Picker("Thinking", selection: $journal.input.thinking) {
                Text("Model default").tag("default")
                Text("On").tag("on")
                Text("Off").tag("off")
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Thinking mode")
            Text(journal.input.thinking == "off" ? "Requests an answer without thinking, if supported. This changes the experimental condition." : "Thinking shares the output budget with the answer. Model default uses the endpoint’s configured behavior.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("Output token limit").font(.subheadline.bold())
                Spacer()
                Text("\(journal.input.maxTokens.formatted()) tokens").font(.headline.monospacedDigit()).foregroundStyle(DynoBrand.accent)
            }
            Slider(value: Binding(get: { Double(journal.input.maxTokens) }, set: { journal.input.maxTokens = Int($0) }), in: 128...16384, step: 128)
                .accessibilityLabel("Output token limit").accessibilityValue("\(journal.input.maxTokens) tokens")
            HStack {
                Text("128 · shorter"); Spacer(); Text("16,384 · more room")
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([2048, 4096, 8192, 16384], id: \.self) { limit in
                    Button { journal.input.maxTokens = limit } label: {
                        Text("\(limit / 1024)K").frame(maxWidth: .infinity)
                    }.buttonStyle(DynoButtonStyle(primary: journal.input.maxTokens == limit))
                        .accessibilityLabel("Set output limit to \(limit) tokens")
                }
            }
            Text("A limit, not a target: generation can finish earlier. More room can take longer and does not guarantee a final answer.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if journal.input.thinking != "off" && journal.input.maxTokens < 8192 {
                Label("Thinking may use this budget before an answer appears. Try 8K for more room.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).background(DynoBrand.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DynoBrand.accent.opacity(0.22)))
    }
    private var noteForm: some View {
        @Bindable var journal = journal
        @Bindable var voice = voice
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Entry type", selection: $journal.noteKind) { ForEach(["Plan", "Observation", "Interpretation", "Alternative explanation", "Next step", "Conclusion", "Correction"], id: \.self) { Text($0) } }
                if journal.focus != nil { Button("Link: \(journal.focus!.uuidString.prefix(8)) · clear") { journal.focus = nil } }
            }
            TextEditor(text: $journal.note).frame(height: 85).border(Color.secondary.opacity(0.2))
            HStack {
                Button("Save entry") { if journal.save(ResearchEntry(kind: "note", title: journal.noteKind, body: journal.note, parent: journal.focus)) { journal.note = "" } }.disabled(journal.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Attach result or file…") { attachFile() }
            }
            DisclosureGroup("Voice note · local transcription") {
                HStack {
                    Button(voice.recording ? "Stop recording" : "Record voice note") { if voice.recording { voice.stop() } else { voice.record() } }.disabled(voice.transcribing || voice.requestingMicrophone)
                    Button("Import audio…") { voice.importAudio() }.disabled(voice.recording || voice.transcribing || voice.requestingMicrophone)
                    Button("Transcribe on device") { voice.transcribe() }.disabled(voice.audio == nil || voice.recording || voice.transcribing || voice.requestingMicrophone)
                    if voice.transcribing { ProgressView().controlSize(.small); Button("Cancel transcription") { voice.cancelTranscription() } }
                }
                if voice.recording { Text("● Recording microphone").foregroundStyle(.red) }
                if let audio = voice.audio {
                    HStack { Text(audio.lastPathComponent).font(.caption); Button("Discard audio draft") { voice.audio = nil; voice.transcript = "" }.disabled(voice.recording || voice.transcribing || voice.requestingMicrophone) }
                    Text("Save or discard this audio draft before switching studies.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = voice.error { Text(error).foregroundStyle(.orange).font(.caption) }
                TextEditor(text: $voice.transcript).frame(height: 80)
                Button("Save audio and reviewed transcript") { saveVoice() }.disabled(voice.audio == nil || voice.recording || voice.transcribing || voice.requestingMicrophone)
                Text("Uses macOS on-device speech recognition in your current language when available. No cloud fallback. Review transcription errors before saving. Audio is copied into this study.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8)
    }
    private func entryCard(_ entry: ResearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { journal.focus = entry.id } label: { Image(systemName: journal.focus == entry.id ? "checkmark.circle.fill" : "circle") }
                Text(entry.title).font(.headline)
                if journal.archivedIDs.contains(entry.id) { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                Button(journal.archivedIDs.contains(entry.id) ? "Restore" : "Archive", systemImage: journal.archivedIDs.contains(entry.id) ? "arrow.uturn.backward" : "archivebox") { journal.archive(entry, restoring: journal.archivedIDs.contains(entry.id)) }.disabled(journal.running)
                Spacer(); Text(entry.kind).font(.caption).foregroundStyle(.secondary)
                Text(entry.created.formatted(date: .abbreviated, time: .standard)).font(.caption)
            }
            Text("\(entry.id.uuidString.prefix(8))\(entry.parent.map { " · follows \($0.uuidString.prefix(8))" } ?? "")").font(.caption2).foregroundStyle(.secondary)
            if entry.kind == "iteration", !journal.entries.contains(where: { $0.parent == entry.id && ["result", "error", "cancelled"].contains($0.kind) }) {
                Text(journal.running ? "Request in progress" : "No completion saved. The app or request may have been interrupted; inspect the endpoint before retrying.").font(.caption).foregroundStyle(.orange)
            }
            if let settings = entry.iteration {
                Text(settings.prompt).textSelection(.enabled)
                Text("\(settings.model.isEmpty ? "No model selected" : settings.model) · thinking \(settings.thinking) · limit \(settings.maxTokens) · seed \(settings.seed)").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Revise prompt") { journal.revise(entry, followup: false) }; if entry.kind == "result" && entry.hasFinalAnswer && !entry.hitTokenLimit { Button("Follow up") { journal.revise(entry, followup: true) } } }.disabled(journal.running)
            }
            if ["error", "cancelled"].contains(entry.kind) { Text("Incomplete run · any output below is partial, not a finished answer.").foregroundStyle(.orange) }
            if let reasoning = entry.thinking, !reasoning.isEmpty { DisclosureGroup("Model-emitted thinking · not verified reasoning") { Text(reasoning).textSelection(.enabled) } }
            if entry.hitTokenLimit {
                Label(entry.hasFinalAnswer ? "Token limit reached · answer may be incomplete" : "Token limit reached before a final answer", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The output budget includes thinking and the answer. This run stopped at its token limit; it is not a completed response for evaluation.").font(.callout)
                if let retry = entry.largerBudgetRetry {
                    Button("Prepare retry with \(retry.maxTokens) tokens") { journal.prepareLongerRetry(entry) }.disabled(journal.running)
                    Text("Loads the same prompt and settings into the editor with a larger budget. Scroll to the prompt, review, then Run and save iteration. The original result stays unchanged; more tokens do not guarantee an answer.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let answer = entry.answer {
                if entry.hasFinalAnswer { Text(answer).textSelection(.enabled) }
                else if !entry.hitTokenLimit { Text("No final answer returned. Inspect the saved response and finish reason.").foregroundStyle(.orange) }
            }
            if entry.kind == "result" || entry.kind == "evidence" { DisclosureGroup("Saved request / response / evidence") { Text(entry.body).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
            else if !entry.body.isEmpty { Text(entry.body).textSelection(.enabled) }
            if let attachment = entry.attachment, let study = journal.selected {
                Button("Open attachment") { NSWorkspace.shared.open(journal.store.folder(study).appendingPathComponent(attachment)) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func attachFile() {
        guard let study = journal.selected else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { let path = try journal.store.attach(url, study: study); _ = journal.save(ResearchEntry(kind: "attachment", title: url.lastPathComponent, body: "Evidence file copied into this notebook. Interpretations belong in a separate entry.", parent: journal.focus, attachment: path)) }
            catch { journal.error = error.localizedDescription }
        }
    }
    private func saveVoice() {
        guard let study = journal.selected, let audio = voice.audio else { return }
        do {
            let path = try journal.store.attach(audio, study: study)
            if journal.save(ResearchEntry(kind: "voice", title: "Voice note · \(journal.noteKind)", body: voice.transcript.isEmpty ? "Audio note; no transcript saved." : voice.transcript, parent: journal.focus, attachment: path)) { voice.audio = nil; voice.transcript = "" }
        } catch { journal.error = error.localizedDescription }
    }
}

struct JournalAttachButton: View {
    var value: [String: Any]
    var title: String
    @State private var open = false
    @State private var studies: [ResearchStudy] = []
    @State private var message = ""
    var body: some View {
        Button("Save to study") {
            do { studies = try ResearchNotebook().studies(); message = ""; open = true }
            catch { message = error.localizedDescription; open = true }
        }.disabled(value.isEmpty).popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save a snapshot to a study").font(.headline)
                if studies.isEmpty { Text("Create a study in Lab → Studies first.") }
                ForEach(studies) { study in
                    Button(study.title) {
                        do {
                            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                            try ResearchNotebook().append(ResearchEntry(kind: "evidence", title: title, body: String(data: data, encoding: .utf8)!), to: study.id)
                            message = "Saved to \(study.title). Open Studies to see it."
                        } catch { message = error.localizedDescription }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }.padding(18).frame(width: 330)
        }
    }
}
