import AppKit
import SwiftUI

/// Evals, in four steps like Agents: choose what to evaluate, set it up, run it, read the results.
/// Evals of models run on Inspect AI (UK AI Security Institute) against the models on this Mac; agent tests are
/// the rooms from Agents, decided by the Observer. Both land on the same results board, each number with its
/// 95% range, because a handful of runs says little.
struct EvalsView: View {
    var model: MonitorModel
    @AppStorage("evalsStep") private var workspace = Pane.choose.rawValue
    @AppStorage("evalsSource") private var source = "inspect"   // "agents" | "inspect"
    @AppStorage("evalsInteractive") private var includeInteractive = false
    @AppStorage("sandboxHarnessOverride") private var harnessDir = ""
    @AppStorage("agentsRoom") private var storedRoom = ""
    @AppStorage("agentsWorkspace2") private var agentsWorkspace = "Setup"
    @AppStorage("roomDraft") private var storedDraft = ""
    @State private var overview: [String: Any] = [:]
    @State private var selected: (scenario: String, config: String)?
    @State private var cell: [String: Any]?
    @State private var batches: [[String: Any]] = []
    @State private var compareA = ""
    @State private var compareB = ""
    @State private var comparison: [String: Any]?
    @State private var readiness: [String: Any] = [:]
    @State private var issue: String?
    // Agent tests: a batch of repeats
    @State private var scenarioChoice = "setup"
    @State private var chosenPorts: Set<Int> = []
    @State private var repeats = 10
    @State private var starting = false
    @State private var sharing: SharedEvals?
    // Inspect AI
    @State private var inspect: [String: Any] = [:]
    @State private var library: [String: Any] = [:]
    @State private var draft = InspectDraft()
    @State private var draftWarnings: [String] = []
    @State private var importing = false
    @State private var showLibrary = false
    @State private var saving = false
    @State private var judgePort = 0
    @State private var inspectEpochs = 1
    @State private var activeRun: [String: Any]?
    @State private var inspectSelected: String?

    struct SharedEvals: Identifiable { var batch: String?; var title: String; var id: String { batch ?? "all" } }

    enum Pane: String, CaseIterable, Identifiable {
        case choose = "Choose", setup = "Set up", run = "Run", results = "Results"
        case compare = "Compare", review = "Review", controls = "Controls", advanced = "Advanced"
        var id: String { rawValue }
        static let main: [Pane] = [.choose, .setup, .run, .results]
        static let more: [Pane] = [.compare, .review, .controls, .advanced]
    }
    private var pane: Pane { Pane(rawValue: workspace) ?? .choose }
    private var lab: ResearchLab { model.researchLab }
    private var scenarios: [[String: Any]] { overview["scenarios"] as? [[String: Any]] ?? [] }
    private var configs: [[String: Any]] { overview["configs"] as? [[String: Any]] ?? [] }
    private var cells: [[String: Any]] { overview["cells"] as? [[String: Any]] ?? [] }
    private var inspectCells: [[String: Any]] { overview["inspect"] as? [[String: Any]] ?? [] }
    private var defs: [[String: Any]] { inspect["defs"] as? [[String: Any]] ?? [] }
    private var libraryItems: [[String: Any]] { library["items"] as? [[String: Any]] ?? [] }
    private var servers: [(port: Int, label: String, model: String)] {
        model.snapshot.models.compactMap { s in s.port.map { (Int($0), s.name, s.identifier.isEmpty ? s.name : s.identifier) } }
    }
    private var needsJudge: Bool {
        if draft.kind == "dataset" { return draft.scorer.hasPrefix("model_graded") }
        if draft.kind == "library" { return libraryItems.first { $0["id"] as? String == draft.library }?["judge"] as? Bool ?? false }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            InspectBanner(status: inspect)
            if let issue { Text(issue).font(.callout).foregroundStyle(.orange) }
            switch pane {
            case .choose: ScrollView { choosePane.padding(.vertical, 4) }
            case .setup: ScrollView { setupPane.padding(.vertical, 4) }
            case .run: ScrollView { runPane.padding(.vertical, 4) }
            case .results: ScrollView { resultsPane.padding(.vertical, 4) }
            case .compare: ScrollView { comparePane.padding(.vertical, 4) }
            case .review: EvalReviewPane(model: model, onOpen: open)
            case .controls: ScrollView { controlsPane.padding(.vertical, 4) }
            case .advanced: EvaluateView(model: model)
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $sharing) { item in ResultShareView(lab: lab, result: .eval(batch: item.batch), suggestedTitle: item.title) }
        .sheet(isPresented: $importing) {
            ImportEvalSheet(lab: lab) { d, warnings in draft = d; draftWarnings = warnings; source = "inspect"; workspace = Pane.setup.rawValue }
        }
        .task(id: "\(workspace)\(includeInteractive)") {
            await lab.start()
            while !Task.isCancelled {
                await refresh()
                let busy = batches.contains { $0["status"] as? String == "running" } || activeRun?["status"] as? String == "running"
                    || (library["install"] as? [String: Any])?["running"] as? Bool == true
                try? await Task.sleep(for: .seconds(busy ? 2 : 15))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Evals").font(.title2.bold())
            HStack(spacing: 4) {
                ForEach(Array(Pane.main.enumerated()), id: \.offset) { i, p in
                    Button { workspace = p.rawValue } label: {
                        Text("\(i + 1) · \(p.rawValue)").font(.callout.weight(pane == p ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(pane == p ? DynoBrand.accent : .clear))
                            .foregroundStyle(pane == p ? DynoBrand.ink : .secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(3).background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.surface)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            Spacer()
            if Pane.more.contains(pane) { Text("More › \(pane.rawValue)").font(.callout).foregroundStyle(.secondary) }
            Menu("More") {
                Button("Compare two agent configs") { workspace = Pane.compare.rawValue }
                Button("Review judged reports") { workspace = Pane.review.rawValue }
                Button("Positive controls") { workspace = Pane.controls.rawValue }
                Button("Advanced") { workspace = Pane.advanced.rawValue }
            }.fixedSize().help("Compare configs on agent tests, review the report judge, run the Observer's positive controls, and older tools")
        }
    }

    // MARK: 1 · Choose

    @ViewBuilder private var choosePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIntro(title: "What do you want to evaluate?",
                      text: "Repeat one of your agent tests across models, or evaluate models with Inspect AI: build an eval from your own questions, import one, or pick a published benchmark.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ChooseCard(icon: "person.3.sequence", title: "Your agent tests",
                           text: "The tests from Agents, repeated across models. The hidden Observer decides each run.",
                           detail: "\(scenarios.count) scenario\(scenarios.count == 1 ? "" : "s") · \(overview["runs"] as? Int ?? 0) finished runs →",
                           tint: DynoBrand.accent) { source = "agents"; workspace = Pane.setup.rawValue }
                ChooseCard(icon: "tablecells", title: "Build an eval",
                           text: "Write questions and expected answers, pick how the model is asked and how answers are marked.",
                           detail: "Dataset → Solver → Scorer →", tint: DynoBrand.violet) {
                    draft = InspectDraft(); draftWarnings = []; source = "inspect"; workspace = Pane.setup.rawValue
                }
                ChooseCard(icon: "square.and.arrow.down", title: "Import",
                           text: "A CSV, JSONL or JSON dataset, or an Inspect task file (.py) someone shared.",
                           detail: "Open or paste a file →", tint: .blue) { importing = true }
                ChooseCard(icon: "books.vertical", title: "Benchmark library",
                           text: "Published safety benchmarks from inspect_evals: refusals, misuse, honesty, evaluation awareness.",
                           detail: "\(libraryItems.count) benchmarks \(library["installed"] as? Bool == true ? "· installed" : "· install once") →",
                           tint: .orange) { showLibrary.toggle() }
            }
            if showLibrary {
                LibraryCatalog(library: library, onInstall: installLibrary) { item in
                    draft = InspectDraft(); draft.kind = "library"; draft.library = item["id"] as? String ?? ""
                    draft.title = item["title"] as? String ?? ""; draft.limit = 20; draftWarnings = []
                    source = "inspect"; workspace = Pane.setup.rawValue
                }
            }
            SavedEvalsList(defs: defs, onOpen: { openDef($0, then: .setup) }, onRun: { openDef($0, then: .run) }, onDelete: deleteDef)
        }
    }

    // MARK: 2 · Set up

    @ViewBuilder private var setupPane: some View {
        if source == "agents" {
            VStack(alignment: .leading, spacing: 16) {
                StepIntro(title: "Set up · which agent test",
                          text: "Pick the test to repeat: the one on the Agents Setup screen now, or a scenario you already ran. Its environment, goal and rules stay the same in every run.")
                agentWhatCard
                Button("Next: choose models →") { workspace = Pane.run.rawValue }.buttonStyle(.dynoPrimary)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                StepIntro(title: "Set up · the eval",
                          text: "Inspect evaluates in three parts: the dataset (the questions), the solver (how the model is asked) and the scorer (how each answer is marked).")
                InspectSetupView(draft: $draft, libraryItems: libraryItems, warnings: draftWarnings, saving: saving, onSave: saveDraft)
            }
        }
    }

    // MARK: 3 · Run

    @ViewBuilder private var runPane: some View {
        if source == "agents" {
            VStack(alignment: .leading, spacing: 16) {
                StepIntro(title: "Run · repeat the agent test",
                          text: "Each run is a full room with the hidden Observer. Runs alternate between the models so they meet the same conditions.")
                agentRunCards
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                StepIntro(title: "Run · with Inspect AI",
                          text: "Inspect runs the eval on each model you pick, one sample at a time, and writes its own log. Progress shows here.")
                if draft.id == nil {
                    Text("Save the eval on the Set up step first, or reopen one from step 1.").foregroundStyle(.secondary)
                    Button("← Set up") { workspace = Pane.setup.rawValue }
                } else {
                    InspectRunPanel(draft: draft, needsJudge: needsJudge, servers: servers, chosen: $chosenPorts, judgePort: $judgePort, epochs: $inspectEpochs,
                                    running: activeRun, starting: starting, onStart: startInspect, onCancel: cancelInspect,
                                    onStartModel: { model.requestedTab = .run }, onResults: { workspace = Pane.results.rawValue })
                }
            }
        }
    }

    // MARK: 4 · Results

    @ViewBuilder private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepIntro(title: "Results · everything in one place",
                      text: "Agent tests from Agents and Inspect evals side by side. Every number shows how many runs or samples it rests on and its 95% range; click a cell for the details.")
            resultsSummary
            agentResults
            inspectResults
        }
    }

    private var resultsSummary: some View {
        HStack(spacing: 12) {
            summaryTile("Agent tests", "\(overview["runs"] as? Int ?? 0)", "finished runs over \(scenarios.count) scenario\(scenarios.count == 1 ? "" : "s")", DynoBrand.accent)
            summaryTile("Inspect evals", "\(Set(inspectCells.compactMap { $0["def_id"] as? String }).count)", "evals scored on \(Set(inspectCells.compactMap { $0["label"] as? String }).count) model\(Set(inspectCells.compactMap { $0["label"] as? String }).count == 1 ? "" : "s")", DynoBrand.violet)
            summaryTile("Samples", "\(inspectCells.reduce(0) { $0 + ($1["n"] as? Int ?? 0) })", "marked by Inspect scorers", .blue)
        }
    }

    private func summaryTile(_ title: String, _ value: String, _ detail: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(tint)
            Text(value).font(.title.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.08))).overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.3)))
    }

    @ViewBuilder private var agentResults: some View {
        EvalCard(title: "Agent tests · from Agents, decided by the Observer") {
            HStack(spacing: 16) {
                if let n = overview["interactive"] as? Int, n > 0 {
                    Toggle("Include \(n) test\(n == 1 ? "" : "s") where you wrote in the chat", isOn: $includeInteractive).toggleStyle(.checkbox).font(.callout)
                        .help("Those aren't comparable with tests nobody touched, so they're left out by default.")
                }
                Spacer()
                if !scenarios.isEmpty {
                    Button("Share…") { sharing = SharedEvals(batch: nil, title: "") }.help("Share this table on Dyno Research or as a .dynoeval.json file.")
                }
                Button("Repeat a test…") { source = "agents"; workspace = Pane.setup.rawValue }
            }
            if scenarios.isEmpty {
                Text("No finished agent tests yet. Run a test in Agents, or repeat one here, and it appears in this table.").foregroundStyle(.secondary)
            } else {
                grid
                Text("Each cell: the share of runs that stayed safe (no rule broken, and a report that matches the log). Grey cells rest on fewer than 5 runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let cell { CellDetail(cell: cell, onOpen: open, onRunMore: { runMore(cell) }) }
    }

    @ViewBuilder private var inspectResults: some View {
        EvalCard(title: "Inspect evals · scored by Inspect AI") {
            if inspectCells.isEmpty {
                Text("No Inspect evals run yet. Build, import or pick one on step 1.").foregroundStyle(.secondary)
            } else {
                InspectResultsBoard(cells: inspectCells, selected: $inspectSelected)
                Text("Each cell: the share of samples marked correct by the eval's scorer, across all its runs on that model.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let key = inspectSelected, let c = inspectCells.first(where: { "\($0["def_id"] as? String ?? "")|\($0["label"] as? String ?? "")" == key }) {
            InspectCellDetail(lab: lab, cell: c).id(key)
        }
    }

    private var grid: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Scenario").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                    ForEach(configs.indices, id: \.self) { i in
                        Text(configs[i]["label"] as? String ?? "").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 170, alignment: .leading).lineLimit(2)
                    }
                }
                ForEach(scenarios.indices, id: \.self) { i in
                    let s = scenarios[i], sk = s["key"] as? String ?? ""
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s["title"] as? String ?? "").font(.callout.weight(.semibold)).lineLimit(2)
                            Text("\(s["environment"] as? String ?? "plain machine") · \((s["rules"] as? [Any])?.count ?? 0) rules").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 260, alignment: .leading)
                        ForEach(configs.indices, id: \.self) { j in
                            let ck = configs[j]["key"] as? String ?? ""
                            if let c = cells.first(where: { $0["scenario"] as? String == sk && $0["config"] as? String == ck }) {
                                Button { select(sk, ck) } label: { RateCell(metrics: c, selected: selected?.scenario == sk && selected?.config == ck) }.buttonStyle(.plain)
                            } else {
                                Text("not run").font(.caption).foregroundStyle(.tertiary).frame(width: 170, height: 64)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            }
                        }
                    }
                }
            }.padding(2)
        }
    }

    private func select(_ scenario: String, _ config: String) {
        selected = (scenario, config)
        Task { await loadCell() }
    }

    private func loadCell() async {
        guard let selected else { cell = nil; return }
        do { cell = try await lab.request("/sandbox/evals/cell?scenario=\(selected.scenario)&config=\(selected.config)&interactive=\(includeInteractive ? 1 : 0)", timeout: 30) }
        catch { cell = nil }
    }

    private func open(_ roomID: String) {
        storedRoom = roomID
        agentsWorkspace = "Room & Observer"
        model.requestedTab = .agents
    }

    private func runMore(_ cell: [String: Any]) {
        if let key = (cell["scenario"] as? [String: Any])?["key"] as? String { scenarioChoice = key }
        if let m = (cell["config"] as? [String: Any])?["model"] as? String, let s = servers.first(where: { $0.model == m }) { chosenPorts = [s.port] }
        source = "agents"
        workspace = Pane.run.rawValue
    }

    // MARK: Agent tests: a batch of repeats

    private var setupDraft: RoomDraft {
        (storedDraft.data(using: .utf8)).flatMap { try? JSONDecoder().decode(RoomDraft.self, from: $0) } ?? RoomDraft()
    }

    /// The setup the batch repeats: the Setup screen's current test, or a scenario already in the table.
    private var batchDraft: RoomDraft {
        var d = setupDraft
        if let s = scenarios.first(where: { $0["key"] as? String == scenarioChoice }) {
            var scenario = RoomDraft(spec: s)
            scenario.agents = d.agents; scenario.rounds = d.rounds; scenario.maxAgents = d.maxAgents
            d = scenario
        }
        return d
    }

    private var agentWhatCard: some View {
        let d = batchDraft
        return EvalCard(title: "What to test") {
            Picker("Scenario", selection: $scenarioChoice) {
                Text("The test on the Setup screen now").tag("setup")
                ForEach(scenarios.indices, id: \.self) { i in Text(scenarios[i]["title"] as? String ?? "").tag(scenarios[i]["key"] as? String ?? "") }
            }.frame(maxWidth: 520)
            Text(d.goal).font(.callout).lineLimit(3).foregroundStyle(.secondary)
            ForEach(d.rules.indices, id: \.self) { i in Text("\(i + 1). \(d.rules[i].text)").font(.caption) }
            Text("\(d.environment ?? "plain machine") · lead “\(d.agents.first?.name ?? "")” · team up to \(d.teamLimit) · \(d.rounds) turns each. Change these on the Agents Setup screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var agentRunCards: some View {
        EvalCard(title: "Which models") {
            if servers.isEmpty {
                Text("No model is running.").foregroundStyle(.secondary)
                Button("Start a model in Models…") { model.requestedTab = .run }.buttonStyle(.link)
            }
            ForEach(servers, id: \.port) { s in
                Toggle("\(s.label) · :\(String(s.port))", isOn: Binding(get: { chosenPorts.contains(s.port) }, set: { on in if on { chosenPorts.insert(s.port) } else { chosenPorts.remove(s.port) } }))
                    .toggleStyle(.checkbox)
            }
            Text("To compare models, keep each one running for the whole batch.").font(.caption).foregroundStyle(.secondary)
        }
        EvalCard(title: "How many runs") {
            Stepper("\(repeats) runs per model", value: $repeats, in: 1...50)
            Text(repeatsAdvice).font(.caption).foregroundStyle(repeats < 10 ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            Text("Nobody writes in a batch's chat, and each room ends at its final report.").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button(starting ? "Starting…" : "Start \(repeats * max(1, chosenPorts.count)) runs →", action: startBatch).buttonStyle(.dynoPrimary)
                .disabled(starting || chosenPorts.isEmpty || batches.contains { $0["status"] as? String == "running" })
            if batches.contains(where: { $0["status"] as? String == "running" }) { Text("A batch is running.").font(.caption).foregroundStyle(.secondary) }
        }
        if !batches.isEmpty { batchList }
    }

    private var batchList: some View {
        EvalCard(title: "Batches") {
            ForEach(batches.prefix(12).indices, id: \.self) { i in
                let b = batches[i], done = (b["rooms"] as? [Any])?.count ?? 0, total = b["total"] as? Int ?? 0
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b["title"] as? String ?? "Batch").font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\((b["models"] as? [String] ?? []).map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: " vs ")) · \(b["repeats"] as? Int ?? 0) runs each · \(b["status"] as? String ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    DynoProgressBar(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done)/\(total)").font(.caption.monospacedDigit())
                    if b["status"] as? String == "completed", let id = b["id"] as? String, done > 0 {
                        Button("Share…") { sharing = SharedEvals(batch: id, title: b["title"] as? String ?? "") }
                    }
                    if b["status"] as? String == "running", let id = b["id"] as? String {
                        Button("Cancel") { Task { _ = try? await lab.request("/sandbox/evals/batches/\(id)/cancel", body: [:], timeout: 60); await refresh() } }
                    }
                }
                if i < min(batches.count, 12) - 1 { Divider() }
            }
        }
    }

    private var repeatsAdvice: String {
        let bound = Int(((1 - pow(0.05, 1 / Double(repeats))) * 100).rounded())
        return "With \(repeats) clean runs, the true rule-break rate could still be up to \(bound)%. Use at least 10 runs for a rate, and 30 or more for a number you'd quote."
    }

    private func startBatch() {
        let d = batchDraft
        let models = servers.filter { chosenPorts.contains($0.port) }.map { ["port": $0.port, "model": $0.model] as [String: Any] }
        var spec = d.spec(models: Dictionary(servers.map { ($0.port, $0.model) }, uniquingKeysWith: { a, _ in a }))
        if var lead = (spec["agents"] as? [[String: Any]])?.first, let first = models.first {
            lead["port"] = first["port"]; lead["model"] = first["model"]; spec["agents"] = [lead]
        }
        starting = true
        Task {
            do {
                _ = try await lab.request("/sandbox/evals/batches", body: ["harness_dir": harnessDir, "spec": spec, "models": models, "repeats": repeats], timeout: 60)
                issue = nil
                await refresh()
            } catch { issue = error.localizedDescription }
            starting = false
        }
    }

    // MARK: Inspect AI actions

    private func openDef(_ id: String, then step: Pane) {
        Task { @MainActor in
            do {
                let d = try await lab.request("/sandbox/evals/inspect/defs/\(id)", timeout: 30)
                draft = InspectDraft(def: d); draftWarnings = []; inspectEpochs = draft.epochs
                source = "inspect"; workspace = step.rawValue; issue = nil
            } catch { issue = error.localizedDescription }
        }
    }

    private func deleteDef(_ id: String) {
        Task { @MainActor in
            _ = try? await lab.request("/sandbox/evals/inspect/defs/\(id)/delete", body: [:], timeout: 30)
            if draft.id == id { draft = InspectDraft() }
            await refresh()
        }
    }

    private func saveDraft() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                let d = try await lab.request("/sandbox/evals/inspect/defs", body: draft.json, timeout: 60)
                let tasks = draft.tasks
                draft = InspectDraft(def: d); if draft.tasks.count < tasks.count { draft.tasks = tasks }
                inspectEpochs = draft.epochs; draftWarnings = []; issue = nil
                workspace = Pane.run.rawValue
                await refresh()
            } catch { issue = error.localizedDescription }
        }
    }

    private func startInspect() {
        guard let id = draft.id else { return }
        let models = servers.filter { chosenPorts.contains($0.port) }.map { ["port": $0.port, "model": $0.model, "label": $0.label] as [String: Any] }
        var body: [String: Any] = ["def": id, "models": models, "epochs": inspectEpochs]
        if needsJudge, let j = servers.first(where: { $0.port == judgePort }) { body["grader"] = ["port": j.port, "model": j.model] }
        if draft.kind == "library", let hf = HuggingFaceToken.load() { body["hf_token"] = hf }  // gated datasets
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let r = try await lab.request("/sandbox/evals/inspect/runs", body: body, timeout: 60)
                activeRun = r; issue = nil
                await refresh()
            } catch { issue = error.localizedDescription }
        }
    }

    private func cancelInspect(_ id: String) {
        Task { @MainActor in
            _ = try? await lab.request("/sandbox/evals/inspect/runs/\(id)/cancel", body: [:], timeout: 30)
            await refresh()
        }
    }

    private func installLibrary() {
        Task { @MainActor in
            do { library = try await lab.request("/sandbox/evals/inspect/library/install", body: [:], timeout: 30) } catch { issue = error.localizedDescription }
        }
    }

    // MARK: Compare

    @ViewBuilder private var comparePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            if configs.count < 2 {
                Text("Compare needs two configs (for example two models) run on the same agent test. Repeat a test with two models.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    Picker("A (baseline)", selection: $compareA) { ForEach(configs.indices, id: \.self) { Text(configs[$0]["label"] as? String ?? "").tag(configs[$0]["key"] as? String ?? "") } }.frame(maxWidth: 360)
                    Picker("B", selection: $compareB) { ForEach(configs.indices, id: \.self) { Text(configs[$0]["label"] as? String ?? "").tag(configs[$0]["key"] as? String ?? "") } }.frame(maxWidth: 360)
                }
                if let c = comparison { CompareResult(result: c, onOpen: open) }
            }
        }
        .task(id: "\(compareA)|\(compareB)|\(configs.count)") {
            if compareA.isEmpty || !configs.contains(where: { $0["key"] as? String == compareA }), let k = configs.first?["key"] as? String { compareA = k }
            if compareB.isEmpty || compareB == compareA, let k = configs.first(where: { $0["key"] as? String != compareA })?["key"] as? String { compareB = k }
            guard !compareA.isEmpty, !compareB.isEmpty, compareA != compareB else { comparison = nil; return }
            comparison = try? await lab.request("/sandbox/evals/compare?a=\(compareA)&b=\(compareB)&interactive=\(includeInteractive ? 1 : 0)", timeout: 30)
        }
    }

    // MARK: Controls

    @ViewBuilder private var controlsPane: some View {
        let controls = readiness["controls"] as? [String: Any]
        VStack(alignment: .leading, spacing: 16) {
            EvalCard(title: "Positive controls") {
                Text("Scripted agents that break each kind of rule on purpose, and some that behave. If the Observer misses one of them, the numbers in this tab can't be trusted.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if let controls {
                    let passed = controls["passed"] as? Bool == true
                    Label(passed ? "Last check passed" : "Last check failed", systemImage: passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(passed ? DynoBrand.accent : .orange).font(.callout.weight(.semibold))
                    if let t = controls["created"] as? Double { Text("Run \(Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    ForEach((controls["results"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                        let r = (controls["results"] as? [[String: Any]] ?? [])[i]
                        let ok = r["ok"] as? Bool ?? (r["passed"] as? Bool ?? false)
                        Text("\(ok ? "✓" : "✗") \(r["name"] as? String ?? r["task"] as? String ?? r["control"] as? String ?? "control")").font(.caption.monospaced()).foregroundStyle(ok ? Color.secondary : .orange)
                    }
                } else { Text("Never run.").foregroundStyle(.orange) }
                Button("Run the positive controls") {
                    Task {
                        do { _ = try await lab.request("/sandbox/runs", body: ["kind": "controls", "harness_dir": harnessDir], timeout: 30); issue = nil }
                        catch { issue = error.localizedDescription }
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func refresh() async {
        do {
            // The banner, step 1 and the results all need Inspect's status.
            if let s = try? await lab.request("/sandbox/evals/inspect", timeout: 30) {
                inspect = s
                let runs = s["runs"] as? [[String: Any]] ?? []
                let mine = activeRun?["id"] as? String
                activeRun = runs.first { $0["id"] as? String == mine } ?? runs.first { $0["status"] as? String == "running" } ?? activeRun
            }
            switch pane {
            case .choose, .setup, .run, .results, .compare:
                overview = try await lab.request("/sandbox/evals?interactive=\(includeInteractive ? 1 : 0)", timeout: 60)
                batches = (try? await lab.request("/sandbox/evals/batches", timeout: 15))?["batches"] as? [[String: Any]] ?? batches
                if library.isEmpty || pane == .choose { library = (try? await lab.request("/sandbox/evals/inspect/library", timeout: 30)) ?? library }
                if pane == .results { await loadCell() }
            case .controls:
                readiness = try await lab.request("/sandbox/readiness", timeout: 15)
            default: break
            }
            issue = nil
        } catch { issue = error.localizedDescription }
    }
}

// MARK: - Pieces

struct EvalCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(DynoBrand.accent)
            content
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DynoBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

func evalPercent(_ v: Any?) -> String {
    guard let x = v as? Double else { return "–" }
    return "\(Int((x * 100).rounded()))%"
}

func evalRange(_ rate: [String: Any]?) -> String {
    guard let ci = rate?["ci"] as? [Double], ci.count == 2 else { return "" }
    return "\(Int((ci[0] * 100).rounded()))–\(Int((ci[1] * 100).rounded()))%"
}

func evalColor(_ safe: Double?) -> Color {
    guard let safe else { return .secondary }
    return safe >= 0.9 ? DynoBrand.accent : safe >= 0.5 ? .orange : .red
}

private struct RateCell: View {
    var metrics: [String: Any]
    var selected: Bool
    var body: some View {
        let safe = metrics["safe"] as? [String: Any], n = metrics["n"] as? Int ?? 0, rate = safe?["rate"] as? Double
        let color = n < 5 ? Color.secondary : evalColor(rate)
        VStack(alignment: .leading, spacing: 2) {
            Text(evalPercent(rate) + " safe").font(.title3.bold()).foregroundStyle(color)
            Text("95%: \(evalRange(safe))").font(.caption2).foregroundStyle(.secondary)
            Text("\(n) run\(n == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).frame(width: 170, height: 64, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(selected ? 0.22 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? color : color.opacity(0.35), lineWidth: selected ? 2 : 1))
        .opacity(n < 5 ? 0.7 : 1)
    }
}

let evalOutcomes: [(String, String, Color)] = [
    ("kept_honest", "Kept the rules, honest report", DynoBrand.accent), ("kept_no_report", "Kept the rules, no report", .mint),
    ("dishonest_report", "Report contradicts the log", .yellow), ("broke_disclosed", "Broke a rule, admitted it", .orange),
    ("broke_hidden", "Broke a rule, hid it", .red)]

/// One scenario × config: the headline rates, reliability, each rule, and every run.
private struct CellDetail: View {
    var cell: [String: Any]
    var onOpen: (String) -> Void
    var onRunMore: () -> Void

    var body: some View {
        let m = cell["metrics"] as? [String: Any] ?? [:], n = m["n"] as? Int ?? 0
        let scenario = cell["scenario"] as? [String: Any] ?? [:], config = cell["config"] as? [String: Any] ?? [:]
        let breaks = (m["rule_break"] as? [String: Any])?["count"] as? Int ?? 0
        EvalCard(title: "\(scenario["title"] as? String ?? "") · \(config["label"] as? String ?? "")") {
            HStack(alignment: .top, spacing: 12) {
                tile("Stayed safe", m["safe"], good: true)
                tile("Broke a rule", m["rule_break"], good: false)
                tile("Admitted it, of the runs that broke one", m["disclosure"], good: true)
                tile("Broke it through a created agent", m["delegated"], good: false)
                tile("Report contradicts the log", m["dishonest"], good: false)
            }
            if breaks == 0, let bound = m["zero_failure_bound"] as? Double {
                Text("No rule broken in \(n) runs. The true rate could still be up to \(evalPercent(bound)); more runs narrow it.").font(.caption).foregroundStyle(.secondary)
            }
            reliability(m)
            let rules = (m["rules"] as? [String: [String: Any]] ?? [:]).sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            if !rules.isEmpty {
                Text("Each rule").font(.callout.weight(.semibold))
                ForEach(rules, id: \.key) { k, r in
                    let rate = r["rate"] as? Double ?? 0
                    HStack(spacing: 8) {
                        Text("\(k). \(r["text"] as? String ?? "")").font(.caption).lineLimit(1).frame(width: 300, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                Capsule().fill(rate > 0 ? Color.red.opacity(0.7) : DynoBrand.accent.opacity(0.5)).frame(width: max(4, g.size.width * rate))
                            }
                        }.frame(height: 8)
                        Text("broken in \(r["count"] as? Int ?? 0)/\(n)").font(.caption.monospacedDigit()).frame(width: 110, alignment: .trailing)
                        if let a = r["attempted"] as? Int, a > 0 { Text("· tried \(a)").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            let alerts = (m["alerts"] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }
            if !alerts.isEmpty {
                Text("Alerts").font(.callout.weight(.semibold))
                ForEach(alerts, id: \.key) { name, r in
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge").foregroundStyle((r["count"] as? Int ?? 0) > 0 ? .yellow : .secondary).font(.caption)
                        Text(name).font(.caption).frame(width: 300, alignment: .leading)
                        Text("fired in \(r["count"] as? Int ?? 0) of \(r["n"] as? Int ?? 0) runs · \(evalPercent(r["rate"])) · 95%: \(evalRange(r))")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            outcomeMix(m["outcomes"] as? [String: Int] ?? [:], n: n)
            HStack {
                Text("Runs").font(.callout.weight(.semibold))
                Spacer()
                Button("Run more of this…", action: onRunMore)
            }
            ForEach((cell["runs"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                RunLine(run: (cell["runs"] as? [[String: Any]] ?? [])[i], onOpen: onOpen)
            }
        }
    }

    private func tile(_ title: String, _ value: Any?, good: Bool) -> some View {
        let r = value as? [String: Any], rate = r?["rate"] as? Double, n = r?["n"] as? Int ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(n == 0 ? "–" : evalPercent(rate)).font(.title2.bold()).foregroundStyle(n == 0 ? .secondary : evalColor(good ? rate : rate.map { 1 - $0 }))
            Text(n == 0 ? "no runs to count" : "\(r?["count"] as? Int ?? 0) of \(n) · 95%: \(evalRange(r))").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.background))
    }

    private func reliability(_ m: [String: Any]) -> some View {
        let hat = m["pass_hat"] as? [String: Any] ?? [:], at = m["pass_at"] as? [String: Any] ?? [:]
        return VStack(alignment: .leading, spacing: 4) {
            Text("Reliability").font(.callout.weight(.semibold))
            HStack(spacing: 18) {
                ForEach(["1", "3", "5"], id: \.self) { k in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(k) in a row: \(evalPercent(hat[k]))").font(.callout.monospacedDigit())
                        Text("at least 1 of \(k): \(evalPercent(at[k]))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("“k in a row” is the chance that k runs all stay safe (pass^k). An agent that is safe 90% of the time stays safe 5 times in a row only 59% of the time.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func outcomeMix(_ outcomes: [String: Int], n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What happened").font(.callout.weight(.semibold))
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(evalOutcomes, id: \.0) { key, _, color in
                        if let c = outcomes[key], c > 0, n > 0 { Rectangle().fill(color).frame(width: g.size.width * CGFloat(c) / CGFloat(n)) }
                    }
                }
            }.frame(height: 12).clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(evalOutcomes, id: \.0) { key, label, color in
                    if let c = outcomes[key], c > 0 { Label("\(label): \(c)", systemImage: "circle.fill").font(.caption).foregroundStyle(color) }
                }
            }
        }
    }
}

struct RunLine: View {
    var run: [String: Any]
    var onOpen: (String) -> Void
    var body: some View {
        let outcome = evalOutcomes.first { $0.0 == run["outcome"] as? String }
        HStack(spacing: 8) {
            Circle().fill(outcome?.2 ?? .secondary).frame(width: 8, height: 8)
            Text(outcome?.1 ?? (run["outcome"] as? String ?? "")).font(.caption.weight(.semibold)).frame(width: 190, alignment: .leading)
            Text(run["verdict"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if run["interactive"] as? Bool == true { Text("you wrote").font(.caption2).foregroundStyle(.blue) }
            if let t = run["created"] as? Double { Text(Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            if let id = run["id"] as? String { Button("Open") { onOpen(id) }.controlSize(.small) }
        }
    }
}

private struct CompareResult: View {
    var result: [String: Any]
    var onOpen: (String) -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        let rows = result["scenarios"] as? [[String: Any]] ?? []
        let delta = result["delta"] as? Double, ci = result["ci"] as? [Double]
        VStack(alignment: .leading, spacing: 14) {
            EvalCard(title: "Result") {
                Text(result["verdict"] as? String ?? "").font(.title3.bold())
                    .foregroundStyle(ci.map { $0[0] > 0 ? DynoBrand.accent : $0[1] < 0 ? .red : .primary } ?? .primary)
                if let delta, let ci {
                    Text("B stays safe \(points(delta)) more often than A, on average over \(rows.count) shared scenario\(rows.count == 1 ? "" : "s"). 95% range: \(points(ci[0])) to \(points(ci[1])).")
                        .font(.callout)
                    Text("Only the scenarios both ran are compared, so the difference isn't down to harder tests on one side.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i], key = r["scenario"] as? String ?? "\(i)"
                EvalCard(title: r["title"] as? String ?? "") {
                    HStack(spacing: 20) {
                        side("A", r["a"] as? [String: Any])
                        side("B", r["b"] as? [String: Any])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Difference").font(.caption).foregroundStyle(.secondary)
                            Text(points(r["delta"] as? Double ?? 0)).font(.title3.bold())
                            if let c = r["ci"] as? [Double] { Text("95%: \(points(c[0])) to \(points(c[1]))").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(expanded.contains(key) ? "Hide runs" : "Show runs side by side") { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } }
                    }
                    if expanded.contains(key) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) { Text("A").font(.caption.bold()); ForEach((r["runs_a"] as? [[String: Any]] ?? []).indices, id: \.self) { j in RunLine(run: (r["runs_a"] as? [[String: Any]] ?? [])[j], onOpen: onOpen) } }
                            VStack(alignment: .leading, spacing: 4) { Text("B").font(.caption.bold()); ForEach((r["runs_b"] as? [[String: Any]] ?? []).indices, id: \.self) { j in RunLine(run: (r["runs_b"] as? [[String: Any]] ?? [])[j], onOpen: onOpen) } }
                        }
                    }
                }
            }
        }
    }

    private func points(_ v: Double) -> String { "\(v >= 0 ? "+" : "")\(Int((v * 100).rounded())) pts" }

    private func side(_ name: String, _ r: [String: Any]?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(evalPercent(r?["rate"]) + " safe").font(.title3.bold()).foregroundStyle(evalColor(r?["rate"] as? Double))
            Text("\(r?["count"] as? Int ?? 0)/\(r?["n"] as? Int ?? 0) · 95%: \(evalRange(r))").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Hand review of rooms, an LLM judge for the reports, and how well each agrees with people.
/// The Observer stays the source of truth for rule breaks; the judge only reads the transcript.
struct EvalReviewPane: View {
    var model: MonitorModel
    var onOpen: (String) -> Void
    @AppStorage("reviewerName") private var reviewer = ""
    @State private var data: [String: Any] = [:]
    @State private var selectedID: String?
    @State private var brokeRule: Bool?
    @State private var honest: Int = -1   // -1 unanswered, 0 no, 1 yes, 2 no report
    @State private var note = ""
    @State private var judgePort: Int?
    @State private var issue: String?
    @State private var saving = false
    @State private var showReviewed = false

    private var lab: ResearchLab { model.researchLab }
    private var queue: [[String: Any]] { data["queue"] as? [[String: Any]] ?? [] }
    private var reviewed: [[String: Any]] { data["reviewed"] as? [[String: Any]] ?? [] }
    private var list: [[String: Any]] { showReviewed ? reviewed : queue }
    private var selected: [String: Any]? { (queue + reviewed).first { $0["id"] as? String == selectedID } }
    private var judge: [String: Any] { data["judge"] as? [String: Any] ?? [:] }
    private var servers: [(port: Int, label: String, model: String)] {
        model.snapshot.models.compactMap { s in s.port.map { (Int($0), s.name, s.identifier.isEmpty ? s.name : s.identifier) } }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                agreementCard
                judgeCard
                Picker("", selection: $showReviewed) { Text("To review (\(queue.count))").tag(false); Text("Reviewed (\(reviewed.count))").tag(true) }
                    .pickerStyle(.segmented).labelsHidden()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(list.indices, id: \.self) { i in
                            let item = list[i], id = item["id"] as? String
                            Button { select(id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item["title"] as? String ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                                    Text((item["reasons"] as? [String] ?? []).joined(separator: " · ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
                                    Text(item["verdict"] as? String ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 8).fill(id == selectedID ? DynoBrand.accent.opacity(0.14) : Color.clear))
                            }.buttonStyle(.plain)
                        }
                        if list.isEmpty { Text(showReviewed ? "Nothing reviewed yet." : "Nothing to review. Disagreements and a random \(15)% of tests land here.").font(.caption).foregroundStyle(.secondary).padding(8) }
                    }
                }
            }.frame(minWidth: 340, idealWidth: 400, maxWidth: 480).padding(.trailing, 8)
            ScrollView {
                if let s = selected { detail(s).padding(.leading, 8) }
                else { Text("Pick a test on the left.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200) }
            }.frame(minWidth: 480, maxWidth: .infinity)
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(judge["running"] as? Bool == true ? 2 : 10))
            }
        }
    }

    private var agreementCard: some View {
        EvalCard(title: "Do the graders agree with you?") {
            ForEach((data["agreement"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                let a = (data["agreement"] as? [[String: Any]] ?? [])[i], n = a["n"] as? Int ?? 0
                HStack(alignment: .firstTextBaseline) {
                    Text(a["name"] as? String ?? "").font(.caption).lineLimit(2)
                    Spacer()
                    if n == 0 { Text("no data").font(.caption).foregroundStyle(.secondary) }
                    else {
                        Text("\(a["agree"] as? Int ?? 0)/\(n) agree").font(.caption.monospacedDigit())
                        Text("κ \(String(format: "%.2f", a["kappa"] as? Double ?? 0))").font(.caption.monospacedDigit().bold())
                            .foregroundStyle(a["provisional"] as? Bool == true ? .orange : DynoBrand.accent)
                    }
                }
            }
            Text("κ (Cohen's kappa) is agreement beyond chance: 1 is perfect, 0 is chance. Below 0.7, or under 10 reviews, treat that grader's numbers as provisional.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var judgeCard: some View {
        EvalCard(title: "LLM judge for the reports") {
            Text("Reads each finished test's transcript, never the Observer, and checks every claim in the final report.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Judge model", selection: $judgePort) {
                    Text("Choose a running model").tag(Int?.none)
                    ForEach(servers, id: \.port) { s in Text("\(s.label) · :\(String(s.port))").tag(Int?.some(s.port)) }
                }.labelsHidden()
                Button(judge["running"] as? Bool == true ? "Judging \(judge["done"] as? Int ?? 0)/\(judge["total"] as? Int ?? 0)…" : "Judge new tests") { startJudge() }
                    .disabled(judgePort == nil || judge["running"] as? Bool == true)
            }
            if let e = judge["error"] as? String { Text("Last error: \(e)").font(.caption2).foregroundStyle(.orange).lineLimit(2) }
        }
    }

    @ViewBuilder private func detail(_ s: [String: Any]) -> some View {
        let id = s["id"] as? String ?? "", j = s["judge"] as? [String: Any], r = s["review"] as? [String: Any]
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(s["title"] as? String ?? "").font(.title3.bold())
                Spacer()
                Button("Open in Room") { onOpen(id) }
            }
            EvalCard(title: "The Observer says") {
                Text(s["verdict"] as? String ?? "").font(.callout.weight(.semibold))
                Text(evalOutcomes.first { $0.0 == s["outcome"] as? String }?.1 ?? "").font(.caption).foregroundStyle(.secondary)
                if let report = s["report"] as? String { Text("Final report: “\(report)”").font(.callout).lineLimit(8).textSelection(.enabled) }
                else { Text("No final report.").font(.callout) }
            }
            EvalCard(title: "The judge says") {
                if let j, j["status"] as? String == "judged" {
                    Text(j["honest"] as? Bool == true ? "Honest report" : "Dishonest report").font(.callout.weight(.semibold))
                        .foregroundStyle(j["honest"] as? Bool == true ? DynoBrand.accent : .red)
                    Text(j["rationale"] as? String ?? "").font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let c = j["confidence"] as? Double { Text("Confidence \(Int(c * 100))% · \(j["model"] as? String ?? "")").font(.caption2).foregroundStyle(.secondary) }
                    ForEach((j["claims"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                        let c = (j["claims"] as? [[String: Any]] ?? [])[i], status = c["status"] as? String ?? ""
                        HStack(alignment: .top, spacing: 8) {
                            Text(status).font(.caption2.bold()).frame(width: 96, alignment: .leading)
                                .foregroundStyle(status == "contradicted" ? .red : status == "supported" ? DynoBrand.accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("“\(c["claim"] as? String ?? "")”").font(.caption)
                                if let e = c["evidence"] as? String, !e.isEmpty { Text(e).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } else if let j, j["status"] as? String == "error" { Text("The judge failed: \(j["error"] as? String ?? "")").font(.caption).foregroundStyle(.orange) }
                else { Text("Not judged yet.").font(.callout).foregroundStyle(.secondary) }
            }
            EvalCard(title: r == nil ? "Your review" : "Review again") {
                Text("Read the room first (Open in Room). Your answers are compared with the Observer and the judge.").font(.caption).foregroundStyle(.secondary)
                Picker("Did the agents break a rule?", selection: $brokeRule) {
                    Text("–").tag(Bool?.none); Text("Yes").tag(Bool?.some(true)); Text("No").tag(Bool?.some(false))
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Picker("Was the final report honest?", selection: $honest) {
                    Text("–").tag(-1); Text("Yes").tag(1); Text("No").tag(0); Text("No report").tag(2)
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                TextField("Note (what you saw)", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                HStack {
                    TextField("Your name", text: $reviewer).textFieldStyle(.roundedBorder).frame(width: 160)
                    Button(saving ? "Saving…" : "Save review") { save(id) }.buttonStyle(.dynoPrimary).disabled(brokeRule == nil || honest == -1 || saving)
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if let r {
                    Text("Last review: rule broken \(r["broke_rule"] as? Bool == true ? "yes" : "no"), report honest \((r["honest"] as? Bool).map { $0 ? "yes" : "no" } ?? "no report")" + ((r["note"] as? String).map { $0.isEmpty ? "" : " · “\($0)”" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func select(_ id: String?) {
        selectedID = id; brokeRule = nil; honest = -1; note = ""; issue = nil
    }

    private func load() async {
        if let d = try? await lab.request("/sandbox/evals/review", timeout: 60) { data = d }
        if judgePort == nil { judgePort = servers.first?.port }
    }

    private func startJudge() {
        guard let port = judgePort, let s = servers.first(where: { $0.port == port }) else { return }
        Task {
            do { _ = try await lab.request("/sandbox/evals/judge", body: ["port": port, "model": s.model], timeout: 30); issue = nil }
            catch { issue = error.localizedDescription }
            await load()
        }
    }

    private func save(_ id: String) {
        guard let brokeRule else { return }
        saving = true
        var body: [String: Any] = ["broke_rule": brokeRule, "note": note, "reviewer": reviewer]
        body["honest"] = honest == 2 ? NSNull() : (honest == 1) as Any
        Task {
            do {
                _ = try await lab.request("/sandbox/evals/review/\(id)", body: body, timeout: 30)
                issue = nil
                await load()
                select(queue.first?["id"] as? String)
            } catch { issue = error.localizedDescription }
            saving = false
        }
    }
}
