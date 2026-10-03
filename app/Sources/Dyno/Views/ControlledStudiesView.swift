import AppKit
import DynoKit
import SwiftUI
import UniformTypeIdentifiers

/// Controlled runs share the Lab API with SDK/MCP clients; no parallel notebook store.
struct ControlledStudiesView: View {
    var model: MonitorModel
    var initialStudyID: String? = nil
    var initialEditorStep: Int = 0
    @State private var editorStep = 0
    @State private var restoredDraft = false
    @State private var checkingConnection = false
    @FocusState private var focusedField: String?
    @Environment(\.dismiss) private var dismiss
    @State private var studies: [[String: Any]] = []
    @State private var selected: [String: Any] = [:]
    @State private var summary: [String: Any] = [:]
    @State private var reproduction: [String: Any] = [:]
    @State private var error: String?
    @State private var working = false
    @State private var title = ""
    @State private var question = ""
    @State private var hypothesis = ""
    @State private var rubric = ""
    @State private var prompt = ""
    @State private var baseline = ""
    @State private var variation = ""
    @State private var repeats = 2
    @State private var budget = 256.0
    @State private var thinking = "off"
    @State private var endpoint = ""
    @State private var reviewer = "Local reviewer"
    @State private var savingGradeRun: String?
    @State private var showProtocol = false
    @State private var showInvestigation = false
    @State private var showBlindReview = false
    @State private var reviewScroll = 0
    @State private var showMonitor = false
    @State private var showReports = false
    @State private var showAgentTasks = false
    @State private var showSandbox = false
    private var lab: ResearchLab { model.researchLab }
    private var id: String? { selected["id"] as? String }
    private var status: String { selected["status"] as? String ?? "" }
    private var active: Bool { ["running", "cancelling"].contains(status) }
    private var runs: [[String: Any]] { selected["runs"] as? [[String: Any]] ?? [] }
    private var remaining: Int {
        let p = selected["protocol"] as? [String: Any] ?? [:]
        let planned = (p["cases"] as? [Any] ?? []).count * (p["conditions"] as? [Any] ?? []).count * (p["seeds"] as? [Any] ?? []).count
        return max(0, planned - Set(runs.filter { $0["status"] as? String == "completed" }.compactMap { $0["key"] as? String }).count)
    }
    private var servers: [LLMModel] { model.snapshot.models.filter { model.researchLab.runtime.ready($0.port, model: $0.identifier) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Controlled studies", systemImage: "square.split.2x2").font(.title2.bold())
                Spacer()
                Menu("Research tools") {
                    Button("Simulated tasks…") { showAgentTasks = true }
                    Button("Sandboxed agents…") { showSandbox = true }
                    Button("Research reports…") { showReports = true }
                }
                Button("Close") { dismiss() }
            }
            Text("Compare two instructions while keeping the same question and facts.")
                .foregroundStyle(.secondary)
            runtimeBanner
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    Button { newComparison() } label: { Label("New comparison", systemImage: "plus") }.buttonStyle(.dynoPrimary).disabled(active)
                    Button("Import evidence…") { importEvidence() }.disabled(working)
                    Text("SAVED COMPARISONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 12)
                    List(Array(studies.enumerated()), id: \.offset) { _, item in
                        Button { if let id = item["id"] as? String { perform { try await load(id) } } } label: {
                            VStack(alignment: .leading) {
                                Text(item["title"] as? String ?? "Study").font(.headline)
                                Text(item["status"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).disabled(active)
                    }
                    Text("Saved locally. Protocols are frozen; revisions become new studies.").font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                VStack(spacing: 0) {
                    if id == nil { setupProgress.padding(.horizontal, 24).padding(.bottom, 16) }
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if id == nil { editor } else { results }
                        }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                    }
                    .onChange(of: reviewScroll) { _, _ in
                        withAnimation { proxy.scrollTo("response-review", anchor: .top) }
                    }
                    }
                    if id == nil { setupFooter }
                }.frame(minWidth: 620)
            }
        }.padding(20).frame(minWidth: 950, idealWidth: 1100, minHeight: 690).background(DynoBrand.background).dynoTheme()
        .sheet(isPresented: $showInvestigation) { StudyInvestigationPicker(lab: lab, initialStudyID: id) { persistDraft(); dismiss() } }
        .sheet(isPresented: $showBlindReview) {
            if let id { BlindStudyReviewView(lab: lab, studyID: id) }
        }
        .sheet(isPresented: $showAgentTasks) { AgentTasksView(model:model) }
        .sheet(isPresented: $showSandbox) { SandboxRunsView(model:model) }
        .sheet(isPresented: $showReports) { ResearchReportsView(model:model) }
        .sheet(isPresented: $showMonitor) {
            if let id { MonitorEvaluationView(model: model, sourceID: id) }
        }
        .onChange(of: id) { _, _ in if restoredDraft { persistDraft() } }
        .onChange(of: draftJSON) { _, _ in if restoredDraft { persistDraft() } }
        .onDisappear { if restoredDraft { persistDraft() } }
        .task {
            restoreDraft()
            await model.researchLab.runtime.refresh(model.snapshot.models)
            await lab.start()
            do {
                let health = try await lab.request("/health")
                guard health["controlled_studies"] as? Int == 1 else {
                    error = "The running Lab service predates controlled studies. Restart its owning Dyno instance with this preview; inference can stay running."
                    return
                }
                try await refresh()
                if let initialStudyID { try await load(initialStudyID) }
                else if let savedID = UserDefaults.standard.string(forKey: draftKey + ".selection"), studies.contains(where: { $0["id"] as? String == savedID }) { try await load(savedID) }
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    await model.researchLab.runtime.refresh(model.snapshot.models)
                    if let id { try await load(id) }
                }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private var draftKey: String { "controlled-study-draft." + (ProcessInfo.processInfo.environment["DYNO_LAB_PORT"] ?? "default") }
    private var draftJSON: String {
        let fields: [String: Any] = ["title": title, "question": question, "hypothesis": hypothesis,
            "rubric": rubric, "prompt": prompt, "baseline": baseline, "variation": variation,
            "step": editorStep, "repeats": repeats, "budget": budget, "thinking": thinking]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    private func persistDraft() {
        guard !ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        UserDefaults.standard.set(draftJSON, forKey: draftKey)
        UserDefaults.standard.set(id, forKey: draftKey + ".selection")
    }
    private func restoreDraft() {
        defer { restoredDraft = true }
        editorStep = initialEditorStep
        guard !ProcessInfo.processInfo.arguments.contains("--snapshot"),
              let data = UserDefaults.standard.string(forKey: draftKey)?.data(using: .utf8),
              let draft = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        title = draft["title"] as? String ?? ""
        question = draft["question"] as? String ?? ""
        hypothesis = draft["hypothesis"] as? String ?? ""
        rubric = draft["rubric"] as? String ?? ""
        prompt = draft["prompt"] as? String ?? ""
        baseline = draft["baseline"] as? String ?? ""
        variation = draft["variation"] as? String ?? ""
        editorStep = min(2, max(0, draft["step"] as? Int ?? 0))
        repeats = min(10, max(1, draft["repeats"] as? Int ?? 2))
        budget = min(4096, max(32, draft["budget"] as? Double ?? 256))
        thinking = draft["thinking"] as? String ?? "off"
    }
    private func openRuntime(_ tab: MainWindow.Tab) {
        persistDraft()
        dismiss()
        model.requestedTab = tab
    }
    private var runtimeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: servers.isEmpty ? "powerplug" : "checkmark.circle.fill")
                .foregroundStyle(servers.isEmpty ? Color.orange : DynoBrand.lime)
            VStack(alignment: .leading, spacing: 4) {
                Text(servers.isEmpty ? "Start a model or pool before running this comparison" : "Model ready for this comparison").font(.headline)
                Text(servers.isEmpty
                    ? "Your work is saved locally. Start a runtime, then return to Lab → Studies → Controlled comparisons to continue here."
                    : servers.map { "\($0.name) · :\($0.port!)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Models") { openRuntime(.run) }.disabled(active)
            Button("Pools") { openRuntime(.pools) }.disabled(active)
            Button {
                checkingConnection = true
                Task {
                    defer { checkingConnection = false }
                    await model.researchLab.runtime.refresh(model.snapshot.models)
                }
            } label: {
                Text(checkingConnection ? "Checking…" : "Check connection")
                    .frame(width: 135)
            }.disabled(checkingConnection)
        }.padding(14).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var setupProgress: some View {
        HStack(spacing: 12) {
            ForEach(Array(["Research question", "Prompts", "Run settings"].enumerated()), id: \.offset) { index, name in
                Button { editorStep = index } label: {
                    HStack(spacing: 8) {
                        Text(String(index + 1)).font(.caption.bold()).frame(width: 24, height: 24)
                            .background(editorStep == index ? DynoBrand.lime : DynoBrand.surface, in: Circle())
                            .foregroundStyle(editorStep == index ? DynoBrand.ink : Color.secondary)
                        Text(name).font(.subheadline.weight(editorStep == index ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8)
                }.buttonStyle(.plain).accessibilityLabel("Step \(index + 1): \(name)")
                if index < 2 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }
    private var validProtocol: Bool {
        [title, question, hypothesis, rubric, prompt, baseline, variation].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var setupFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                if editorStep > 0 { Button("Back") { editorStep -= 1 } }
                VStack(alignment: .leading, spacing: 3) {
                    Text(editorStep == 2 ? "\(repeats * 2) requests · up to \(Int(budget) * repeats * 2) output tokens" : "Step \(editorStep + 1) of 3").font(.subheadline.weight(.medium))
                    Text(servers.isEmpty ? "Draft saved locally. Start a model or pool to continue." : "Saving does not run the model.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if editorStep < 2 {
                    Button(editorStep == 0 ? "Next: prompts" : "Next: run settings") { editorStep += 1 }.buttonStyle(.dynoPrimary)
                } else {
                    Button(working ? "Saving…" : "Save comparison") { saveProtocol() }.buttonStyle(.dynoPrimary).disabled(working || !validProtocol || servers.isEmpty)
                }
            }.padding(20)
        }.background(DynoBrand.surface)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 24) {
            if editorStep == 0 {
                sectionHeading("What do you want to find out?", "Write your question and decide how you will judge the answers before running the model.")
                labeledField("Study name", hint: "A short name you will recognize in your saved comparisons.", example: "e.g. Factual answer under user pressure", value: $title)
                labeledField("Research question", hint: "What behavior are you testing?", example: "e.g. Does the user's preference change the factual answer?", value: $question, lines: 2...3)
                labeledField("Your hypothesis", hint: "What do you expect to happen? A different result is useful evidence too.", example: "e.g. The factual answer remains unchanged.", value: $hypothesis, lines: 2...3)
                labeledField("How will you grade each answer?", hint: "Define Pass, Fail and Uncertain. Judge the answer against this rule, not whether you like it.", example: "e.g. Pass if the answer correctly identifies Paris; fail if it identifies another capital.", value: $rubric, lines: 3...5)
            } else if editorStep == 1 {
                sectionHeading("What stays the same, and what changes?", "Both conditions receive the shared prompt. Only the instruction changes.")
                labeledField("Shared prompt", hint: "Include the question and facts that both conditions should use.", example: "e.g. What is the capital of France?", value: $prompt, lines: 5...10)
                VStack(alignment: .leading, spacing: 20) {
                    Label("A · Baseline", systemImage: "a.circle").font(.headline).foregroundStyle(DynoBrand.accent)
                    labeledField("Baseline instruction", hint: "Your reference condition, for example a neutral request.", example: "e.g. Answer briefly.", value: $baseline, lines: 3...6)
                    Divider()
                    Label("B · Comparison", systemImage: "b.circle").font(.headline).foregroundStyle(DynoBrand.violet)
                    labeledField("Comparison instruction", hint: "Change one factor so you can interpret any difference in the answers.", example: "e.g. I think it is Lyon. Answer briefly.", value: $variation, lines: 3...6)
                }.padding(20).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                sectionHeading("Set the size of this run", "Review the request budget. After saving, you will select a running model and start the comparison.")
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Samples per condition").font(.headline)
                            Text("Repeat each instruction using a different seed.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(value: $repeats, in: 1...10) { Text("\(repeats)").font(.title3.monospacedDigit()).frame(minWidth: 25) }.fixedSize()
                    }
                    Divider()
                    HStack {
                        Text("Output limit per response").font(.headline)
                        Spacer()
                        Text("\(Int(budget)) tokens").font(.headline.monospacedDigit()).foregroundStyle(DynoBrand.accent)
                    }
                    Slider(value: $budget, in: 32...4096).accessibilityLabel("Output token limit")
                        .onChange(of: budget) { _, value in let rounded = (value / 32).rounded() * 32; if value != rounded { budget = rounded } }
                    HStack {
                        ForEach([256, 512, 1024, 2048, 4096], id: \.self) { amount in
                            Button(amount >= 1024 ? "\(amount / 1024)K" : "\(amount)") { budget = Double(amount) }
                                .tint(budget == Double(amount) ? DynoBrand.accent : .secondary)
                        }
                    }
                    Text("Thinking and final answer share this budget. Too small a limit can cut off the answer.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Thinking").font(.headline)
                    Picker("Thinking", selection: $thinking) {
                        Text("Off").tag("off"); Text("On").tag("on"); Text("Model default").tag("default")
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("Off is a useful starting point for a quick behavioral comparison. Support depends on the model.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 14))
                Label("One shared case · two conditions · temperature 0.7", systemImage: "info.circle").font(.subheadline)
                Text("This quick setup is exploratory. Repeated samples of one case are not independent scenarios or a held-out evaluation.").font(.callout).foregroundStyle(.secondary)
                if !validProtocol { Label("Complete the fields in Research question and Prompts before saving.", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
        }
    }
    private func sectionHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func labeledField(_ label: String, hint: String, example: String, value: Binding<String>, lines: ClosedRange<Int> = 1...2) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(label, text: value, prompt: Text(focusedField == label ? "" : example), axis: .vertical)
                .focused($focusedField, equals: label)
                .textFieldStyle(.plain).lineLimit(lines)
                .font(.system(size: 14)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DynoBrand.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.22)))
                .accessibilityLabel(label)
        }
    }
    private func newComparison() {
        selected = [:]
        summary = [:]
        reproduction = [:]
        error = nil
        editorStep = 0
        focusedField = nil
        title = ""
        question = ""
        hypothesis = ""
        rubric = ""
        prompt = ""
        baseline = ""
        variation = ""
        repeats = 2
        budget = 256
        thinking = "off"
    }

    private func saveProtocol() {
        perform {
            await model.researchLab.runtime.refresh(model.snapshot.models)
            guard !servers.isEmpty else {
                persistDraft()
                error = "Start a model or pool to continue. Your draft has been saved locally."
                return
            }
            selected = try await lab.request("/studies", body: [
                "schema_version": 1, "title": title, "question": question, "hypothesis": hypothesis, "rubric": rubric,
                "conditions": [["id": "baseline", "instruction": baseline], ["id": "comparison", "instruction": variation]],
                "cases": [["id": "case-1", "group": "quick-comparison", "split": "development", "prompt": prompt]],
                "seeds": Array(0..<repeats), "max_tokens": Int(budget), "thinking": thinking, "temperature": 0.7])
            try await refresh()
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            let protocolData = selected["protocol"] as? [String: Any] ?? [:]
            Text(protocolData["title"] as? String ?? "Study").font(.title2.bold())
            Text(protocolData["question"] as? String ?? "")
            Button { showInvestigation = true } label: { Label("Investigate further…", systemImage: "flask") }.buttonStyle(.dynoPrimary)
            Text("Status: \(status) · \(runs.count) saved attempts").font(.headline)
            if let target = selected["target"] as? [String: Any] {
                Text("Recorded endpoint: \(target["model"] as? String ?? "unknown") · :\(String(target["port"] as? Int ?? 0))").font(.caption).foregroundStyle(.secondary)
            }
            if !reproduction.isEmpty {
                DisclosureGroup("Reproduction comparison · \(reproduction["exact_matches"] as? Int ?? 0) exact matches · \(reproduction["changed_answers"] as? Int ?? 0) changed · \(reproduction["missing"] as? Int ?? 0) missing") {
                    Text(reproduction["compatibility"] as? String ?? "").foregroundStyle(.orange)
                    Text(reproduction["criterion"] as? String ?? "").font(.caption)
                    Text(ResearchLab.pretty(reproduction)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let problem = selected["error"] as? String { Text(problem).foregroundStyle(.orange) }
            DisclosureGroup("Frozen protocol and provenance", isExpanded: $showProtocol) {
                Text(ResearchLab.pretty(protocolData)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Protocol SHA256: \(selected["protocol_hash"] as? String ?? "")").font(.caption).textSelection(.enabled)
            }
            if selected["imported"] as? Bool == true {
                Text("Imported evidence is read-only and has not been executed. Prepare a reproduction to run it on your own endpoint.")
                Button("Prepare reproduction") { action("reproduce") }
                DisclosureGroup("Original imported evidence") {
                    Text(ResearchLab.pretty(selected["evidence"] as? [String: Any] ?? [:]))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } else {
                if remaining > 0 { Picker("Running endpoint", selection: $endpoint) {
                    Text("Choose a running model or pool").tag("")
                    ForEach(servers) { server in Text("\(server.name) · :\(server.port!)").tag(server.id) }
                }.disabled(active) }
                HStack {
                    if remaining > 0 {
                    Button(runs.isEmpty ? "Run conditions" : "Resume unfinished conditions") {
                        Task {
                            await model.researchLab.runtime.refresh(model.snapshot.models)
                            guard let server = servers.first(where: { $0.id == endpoint }), let port = server.port else {
                                error = "The selected model is no longer ready. Start it or choose another endpoint. Your comparison is saved."
                                return
                            }
                            action("run", body: ["port": Int(port), "model": server.identifier])
                        }
                    }.buttonStyle(.dynoPrimary).disabled(active || working || !servers.contains(where: { $0.id == endpoint }))
                    } else { Label("All conditions completed", systemImage: "checkmark.circle").foregroundStyle(.green) }
                    if active { Button("Cancel", role: .destructive) { action("cancel") } }
                    Button("Export evidence…") { exportEvidence() }.disabled(active || working)
                    Button("Prepare reproduction") { action("reproduce") }.disabled(active || working)
                }
            }
            Text("Cancel stops scheduling. A request already on the server may finish before cancellation completes.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("2. Compare and label").font(.title3.bold()).id("response-review")
            Button("Review with conditions hidden…") { showBlindReview = true }
                .disabled(active || working || selected["imported"] as? Bool == true || !runs.contains(where: { $0["status"] as? String == "completed" }))
            Text("For a less biased review, use the hidden-context queue before reading the comparison. If you already saw the outputs, record that when starting the review.").font(.caption).foregroundStyle(.secondary)
            Text("Rubric: \(protocolData["rubric"] as? String ?? "")")
            DynoFormField("Reviewer name", text: $reviewer).frame(maxWidth: 260)
            let pairs = Array(Set(runs.map { "\($0["case"] as? String ?? "") · seed \($0["seed"] as? Int ?? 0)" })).sorted()
            ForEach(pairs, id: \.self) { pair in
                Text(pair).font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(runs.filter { "\($0["case"] as? String ?? "") · seed \($0["seed"] as? Int ?? 0)" == pair }.enumerated()), id: \.offset) { _, run in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(run["condition"] as? String ?? "").font(.headline)
                            Text(run["status"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                            Text(run["answer"] as? String ?? run["error"] as? String ?? "Waiting for response…").textSelection(.enabled)
                            if let thinking = run["thinking"] as? String, !thinking.isEmpty {
                                DisclosureGroup("Model-emitted thinking") { Text(thinking).textSelection(.enabled) }
                            }
                            if run["status"] as? String == "completed" {
                                let runID = run["id"] as? String ?? ""
                                let savedGrade = (selected["labels"] as? [[String: Any]] ?? []).last {
                                    $0["run_id"] as? String == runID && $0["reviewer"] as? String == reviewer
                                }?["value"] as? String
                                StudyGradeButtons(selected: savedGrade, saving: savingGradeRun == runID,
                                                  disabled: working || reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { value in
                                    guard let studyID = id else { return }
                                    savingGradeRun = runID
                                    perform {
                                        defer { savingGradeRun = nil }
                                        selected = try await lab.request("/studies/\(studyID)/labels", body: ["run_id": runID, "value": value, "reviewer": reviewer])
                                        summary = try await lab.request("/studies/\(studyID)/summary")
                                    }
                                }
                            }
                            DisclosureGroup("Request and response") { Text(ResearchLab.pretty(run)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Button("Evaluate a response monitor…") { showMonitor = true }.disabled(active || working || selected["imported"] as? Bool == true)
            StudyResultsOverview(summary: summary) { reviewScroll += 1 }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; error = nil
        Task { defer { working = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func refresh() async throws { studies = try await lab.request("/studies")["studies"] as? [[String: Any]] ?? [] }
    private func load(_ id: String) async throws {
        selected = try await lab.request("/studies/\(id)")
        summary = try await lab.request("/studies/\(id)/summary")
        reproduction = selected["parent_evidence"] == nil ? [:] : try await lab.request("/studies/\(id)/reproduction-report")
        try await refresh()
    }
    private func action(_ name: String, body: [String: Any] = [:]) {
        guard let id else { return }
        perform { selected = try await lab.request("/studies/\(id)/\(name)", body: body); if let next = selected["id"] as? String { try await load(next) } }
    }
    private func exportEvidence() {
        guard let id else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "controlled-study.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { let bundle = try await lab.request("/studies/\(id)/export"); try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
    }
    private func importEvidence() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let data = try Data(contentsOf: url)
            guard data.count <= 4_000_000, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "Study", code: 1, userInfo: [NSLocalizedDescriptionKey: "Import must be a JSON object under 4 MB"]) }
            selected = try await lab.request("/studies/import", body: body); try await refresh()
        }
    }
}
