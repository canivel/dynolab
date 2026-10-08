import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The eval being built

/// One sample row in the dataset editor.
struct SampleRow: Identifiable, Equatable {
    var id = UUID()
    var input = ""
    var target = ""
    var choices = ""   // "a | b | c"
}

/// An Inspect eval definition as the editor holds it. Mirrors `inspect_runs.save_def`.
struct InspectDraft: Equatable {
    var id: String?
    var kind = "dataset"
    var title = ""
    var description = ""
    var epochs = 1
    var rows: [SampleRow] = [SampleRow()]
    var solver = "generate"
    var systemPrompt = ""
    var scorer = "includes"
    var ignoreCase = true
    var pattern = ""
    var instructions = ""
    var taskFile = "task.py"
    var taskCode = ""
    var taskName = ""
    var tasks: [String] = []
    var library = ""
    var limit = 0

    init() {}

    init(def d: [String: Any]) {
        id = d["id"] as? String
        kind = d["kind"] as? String ?? "dataset"
        title = d["title"] as? String ?? ""
        description = d["description"] as? String ?? ""
        epochs = d["epochs"] as? Int ?? 1
        rows = (d["dataset"] as? [[String: Any]] ?? []).map { s in
            let t = s["target"]
            return SampleRow(input: s["input"] as? String ?? "",
                             target: (t as? String) ?? ((t as? [String])?.joined(separator: " | ") ?? ""),
                             choices: (s["choices"] as? [String] ?? []).joined(separator: " | "))
        }
        if rows.isEmpty { rows = [SampleRow()] }
        let sv = d["solver"] as? [String: Any] ?? [:], sc = d["scorer"] as? [String: Any] ?? [:]
        solver = sv["kind"] as? String ?? "generate"
        systemPrompt = sv["system_prompt"] as? String ?? ""
        scorer = sc["kind"] as? String ?? "includes"
        ignoreCase = sc["ignore_case"] as? Bool ?? true
        pattern = sc["pattern"] as? String ?? ""
        instructions = sc["instructions"] as? String ?? ""
        let tf = d["task_file"] as? [String: Any] ?? [:]
        taskFile = tf["name"] as? String ?? "task.py"
        taskCode = tf["code"] as? String ?? ""
        taskName = tf["task"] as? String ?? ""
        tasks = d["tasks"] as? [String] ?? (taskName.isEmpty ? [] : [taskName])
        let lib = d["library"] as? [String: Any] ?? [:]
        library = lib["id"] as? String ?? ""
        limit = lib["limit"] as? Int ?? 0
    }

    var json: [String: Any] {
        var d: [String: Any] = ["kind": kind, "title": title, "description": description, "epochs": epochs]
        if let id { d["id"] = id }
        switch kind {
        case "dataset":
            d["dataset"] = rows.filter { !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { r -> [String: Any] in
                var s: [String: Any] = ["input": r.input, "target": r.target]
                let ch = r.choices.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !ch.isEmpty { s["choices"] = ch }
                return s
            }
            d["solver"] = ["kind": solver, "system_prompt": systemPrompt]
            d["scorer"] = ["kind": scorer, "ignore_case": ignoreCase, "pattern": pattern, "instructions": instructions]
        case "task_file":
            d["task_file"] = ["name": taskFile, "code": taskCode, "task": taskName]
        default:
            var lib: [String: Any] = ["id": library]
            if limit > 0 { lib["limit"] = limit }
            d["library"] = lib
        }
        return d
    }

    var filledRows: Int { rows.filter { !$0.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
}

let inspectSolvers: [(String, String, String)] = [
    ("generate", "Ask once", "The model answers each input directly."),
    ("chain_of_thought", "Think, then answer", "The model reasons step by step before its answer."),
    ("multiple_choice", "Multiple choice", "The model picks one of each sample's choices (A, B, C…)."),
]

let inspectScorers: [(String, String, String)] = [
    ("includes", "Contains the target", "Correct when the answer contains the target text."),
    ("match", "Starts or ends with it", "Correct when the answer begins or ends with the target."),
    ("exact", "Exactly the target", "Correct only when the answer is exactly the target."),
    ("pattern", "Regular expression", "Pulls the answer out with a pattern, then compares it to the target."),
    ("choice", "Right choice", "For multiple choice: correct when the chosen letter is the target."),
    ("model_graded_qa", "A judge model grades it", "A second model reads the answer and the target and marks it, following your instructions."),
    ("model_graded_fact", "A judge checks the fact", "A judge model checks that the answer contains the fact in the target."),
]

func inspectKindLabel(_ kind: String?) -> String {
    switch kind {
    case "task_file": return "Inspect task file"
    case "library": return "Benchmark"
    default: return "Dataset"
    }
}

// MARK: - Header: it runs Inspect AI

struct InspectBanner: View {
    var status: [String: Any]

    var body: some View {
        let available = status["available"] as? Bool
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(available == false ? .orange : DynoBrand.accent)
                    Text("Runs on Inspect AI").font(.headline)
                    if let v = status["version"] as? String { pill("v\(v)") }
                    Link("inspect.aisi.org.uk ↗", destination: URL(string: "https://inspect.aisi.org.uk")!).font(.caption)
                }
                Text(available == false
                     ? "Inspect AI isn't installed in this Dyno runtime, so evals can't run. Agent test results still appear below."
                     : "Evals runs on Inspect AI, the open-source evaluation framework from the UK AI Security Institute, on the models running on this Mac. Agent tests from the Agents tab sit in the same results.")
                    .font(.caption).foregroundStyle(available == false ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                partCard("tablecells", "Dataset", "the questions")
                arrow
                partCard("brain", "Solver", "how it's asked")
                arrow
                partCard("checkmark.circle", "Scorer", "how it's marked")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [DynoBrand.violet.opacity(0.14), DynoBrand.accent.opacity(0.08)], startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DynoBrand.violet.opacity(0.35)))
    }

    private var arrow: some View { Image(systemName: "arrow.right").font(.caption.bold()).foregroundStyle(.secondary) }

    private func pill(_ text: String) -> some View {
        Text(text).font(.caption2.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(DynoBrand.violet.opacity(0.22)))
    }

    private func partCard(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

/// A short "what this step does" line, like the Agents tab.
struct StepIntro: View {
    var title: String
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.bold())
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1 · Choose

struct ChooseCard: View {
    var icon: String
    var title: String
    var text: String
    var detail: String
    var tint: Color
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint)
                    .frame(width: 42, height: 42).background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.14)))
                Text(title).font(.headline)
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(detail).font(.caption.weight(.semibold)).foregroundStyle(tint)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(DynoBrand.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? tint : Color.secondary.opacity(0.2), lineWidth: hover ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SavedEvalsList: View {
    var defs: [[String: Any]]
    var onOpen: (String) -> Void
    var onRun: (String) -> Void
    var onDelete: (String) -> Void

    var body: some View {
        EvalCard(title: "Your evals") {
            if defs.isEmpty {
                Text("None yet. Build one, import one, or add a benchmark: it's saved here to run again.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(defs.indices, id: \.self) { i in
                row(defs[i])
                if i < defs.count - 1 { Divider() }
            }
        }
    }

    private func row(_ d: [String: Any]) -> some View {
        let id = d["id"] as? String ?? ""
        return HStack(spacing: 10) {
            Image(systemName: d["kind"] as? String == "library" ? "books.vertical" : d["kind"] as? String == "task_file" ? "chevron.left.forwardslash.chevron.right" : "tablecells")
                .foregroundStyle(DynoBrand.violet).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(d["title"] as? String ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                Text(summary(d)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Edit") { onOpen(id) }
            Button("Run →") { onRun(id) }.buttonStyle(.dynoPrimary)
            Button { onDelete(id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete this eval (its results are kept)")
        }
    }

    private func summary(_ d: [String: Any]) -> String {
        var parts = [inspectKindLabel(d["kind"] as? String)]
        if let n = d["samples"] as? Int { parts.append("\(n) sample\(n == 1 ? "" : "s")") }
        if let lib = d["library"] as? String { parts.append(lib) }
        if let s = d["scorer"] as? String, let label = inspectScorers.first(where: { $0.0 == s })?.1 { parts.append(label) }
        if let e = d["epochs"] as? Int, e > 1 { parts.append("\(e) epochs") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Import

struct ImportEvalSheet: View {
    var lab: ResearchLab
    var onUse: (InspectDraft, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var draft: InspectDraft?
    @State private var warnings: [String] = []
    @State private var issue: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(DynoBrand.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import an eval").font(.title3.bold())
                    Text("A dataset (CSV, JSONL or JSON with input and target, or question and answer columns) or an Inspect task file (.py with @task).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Open file…", action: openFile)
                Text(name.isEmpty ? "or paste below" : name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(working ? "Reading…" : "Preview", action: preview).disabled(text.isEmpty || working)
            }
            TextEditor(text: $text).font(.system(size: 11, design: .monospaced)).frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let issue { Text(issue).font(.callout).foregroundStyle(.orange) }
            if let draft { previewCard(draft) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use it →") { if let draft { onUse(draft, warnings); dismiss() } }.buttonStyle(.dynoPrimary).disabled(draft == nil)
            }
        }
        .padding(20).frame(minWidth: 680, idealWidth: 760, minHeight: 520).background(DynoBrand.background)
    }

    private func previewCard(_ d: InspectDraft) -> some View {
        EvalCard(title: "Preview") {
            Text(d.title.isEmpty ? "Untitled" : d.title).font(.headline)
            if d.kind == "task_file" {
                Text("Inspect task file · task “\(d.taskName)”\(d.tasks.count > 1 ? " (of \(d.tasks.count))" : "")").font(.callout)
            } else {
                Text("\(d.filledRows) sample\(d.filledRows == 1 ? "" : "s") · scored by \(inspectScorers.first { $0.0 == d.scorer }?.1 ?? d.scorer)").font(.callout)
                ForEach(d.rows.prefix(3)) { r in
                    Text("“\(r.input.prefix(120))” → \(r.target.prefix(60))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ForEach(warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .pythonScript, .plainText, UTType(filenameExtension: "jsonl") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let t = try? String(contentsOf: url, encoding: .utf8) else { return }
        name = url.lastPathComponent; text = t; preview()
    }

    private func preview() {
        working = true; issue = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let r = try await lab.request("/sandbox/evals/inspect/import", body: ["name": name.isEmpty ? "Imported eval" : name, "text": text], timeout: 60)
                draft = InspectDraft(def: r["draft"] as? [String: Any] ?? [:])
                warnings = r["warnings"] as? [String] ?? []
            } catch { draft = nil; issue = error.localizedDescription }
        }
    }
}

// MARK: - Benchmark library

struct LibraryCatalog: View {
    var library: [String: Any]
    var onInstall: () -> Void
    var onPick: ([String: Any]) -> Void

    var body: some View {
        let installed = library["installed"] as? Bool == true
        let install = library["install"] as? [String: Any] ?? [:]
        EvalCard(title: "Benchmark library · inspect_evals") {
            HStack(spacing: 10) {
                if installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(DynoBrand.accent).font(.callout.weight(.semibold))
                } else if install["running"] as? Bool == true {
                    DynoSpinner(); Text("Installing inspect_evals…").font(.callout)
                } else {
                    Button("Install the library", action: onInstall).buttonStyle(.dynoPrimary)
                    Text("Downloads the inspect_evals package once (needs internet).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let e = install["error"] as? String, !e.isEmpty { Text(e).font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(4) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach((library["items"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                    item((library["items"] as? [[String: Any]] ?? [])[i], installed: installed)
                }
            }
        }
    }

    private func item(_ it: [String: Any], installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((it["area"] as? String ?? "").uppercased()).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(DynoBrand.violet)
            Text(it["title"] as? String ?? "").font(.headline)
            Text(it["what"] as? String ?? "").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let n = it["samples"] as? Int { badge("\(n) samples", .secondary) }
                if it["judge"] as? Bool == true { badge("judge model", .orange) }
                if it["gated"] as? Bool == true { badge("gated · Hugging Face login", .purple) }
            }
            Spacer(minLength: 0)
            Button("Use this benchmark →") { onPick(it) }.disabled(!installed)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }
}

// MARK: - 2 · Set up

struct InspectSetupView: View {
    @Binding var draft: InspectDraft
    var libraryItems: [[String: Any]]
    var warnings: [String]
    var saving: Bool
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EvalCard(title: "Name") {
                TextField("What this eval measures", text: $draft.title).textFieldStyle(.roundedBorder).frame(maxWidth: 520)
                TextField("Description (optional)", text: $draft.description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                Text(inspectKindLabel(draft.kind)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            switch draft.kind {
            case "task_file": TaskFileCard(draft: $draft)
            case "library": libraryCard
            default:
                SamplesEditor(rows: $draft.rows)
                SolverCard(draft: $draft)
                ScorerCard(draft: $draft)
            }
            EvalCard(title: "Epochs") {
                Stepper("Run every sample \(draft.epochs) time\(draft.epochs == 1 ? "" : "s")", value: $draft.epochs, in: 1...20).frame(maxWidth: 320)
                Text("More epochs show how consistent a model is; the results count every attempt.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(saving ? "Saving…" : "Save and continue →", action: onSave).buttonStyle(.dynoPrimary)
                    .disabled(saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty || (draft.kind == "dataset" && draft.filledRows == 0))
                if draft.kind == "dataset" { Text("\(draft.filledRows) sample\(draft.filledRows == 1 ? "" : "s") ready").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var libraryCard: some View {
        let it = libraryItems.first { $0["id"] as? String == draft.library } ?? [:]
        return EvalCard(title: "Benchmark") {
            Text(it["title"] as? String ?? draft.library).font(.headline)
            Text(it["what"] as? String ?? "").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(draft.library).font(.caption.monospaced()).foregroundStyle(.secondary)
            if it["judge"] as? Bool == true { Label("A judge model marks the answers: you choose it on the next step.", systemImage: "scale.3d").font(.caption) }
            Label("The first run downloads its dataset (from Hugging Face or the benchmark's source).", systemImage: "arrow.down.circle").font(.caption)
            if it["gated"] as? Bool == true { GatedDatasetNotice(page: it["hf"] as? String) }
            Stepper(draft.limit == 0 ? "All samples" : "First \(draft.limit) samples", value: $draft.limit, in: 0...5000, step: 10).frame(maxWidth: 320)
            Text("Try a small limit first: a full benchmark on a local model can take hours.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SamplesEditor: View {
    @Binding var rows: [SampleRow]
    private let shown = 200

    var body: some View {
        EvalCard(title: "Dataset · the questions") {
            Text("Each row is one sample: what the model is asked, and the answer you expect. For multiple choice, list the choices separated by |.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Input").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                Text("Target").font(.caption.bold()).frame(width: 220, alignment: .leading)
                Text("Choices").font(.caption.bold()).frame(width: 160, alignment: .leading)
                Color.clear.frame(width: 22)
            }.foregroundStyle(.secondary)
            ForEach($rows.prefix(shown)) { $row in
                HStack(alignment: .top) {
                    TextField("What is the capital of France?", text: $row.input, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                    TextField("Paris", text: $row.target, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3).frame(width: 220)
                    TextField("optional", text: $row.choices).textFieldStyle(.roundedBorder).frame(width: 160)
                    Button { rows.removeAll { $0.id == row.id }; if rows.isEmpty { rows = [SampleRow()] } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).frame(width: 22)
                }
            }
            if rows.count > shown { Text("Showing the first \(shown) of \(rows.count) samples. All of them are saved and run.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button { rows.append(SampleRow()) } label: { Label("Add a sample", systemImage: "plus") }
                Button { pasteTSV() } label: { Label("Paste rows", systemImage: "doc.on.clipboard") }
                    .help("Paste rows copied from a spreadsheet: input, target and optional choices, separated by tabs.")
            }
        }
    }

    private func pasteTSV() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let pasted = text.split(whereSeparator: \.isNewline).compactMap { line -> SampleRow? in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let first = cols.first, !first.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return SampleRow(input: first, target: cols.count > 1 ? cols[1] : "", choices: cols.count > 2 ? cols[2] : "")
        }
        if rows.count == 1, rows[0].input.isEmpty { rows = [] }
        rows += pasted
        if rows.isEmpty { rows = [SampleRow()] }
    }
}

struct SolverCard: View {
    @Binding var draft: InspectDraft
    var body: some View {
        EvalCard(title: "Solver · how the model is asked") {
            OptionGrid(options: inspectSolvers, selection: $draft.solver)
            TextField("System prompt (optional): instructions the model sees before every sample", text: $draft.systemPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6)
        }
    }
}

struct ScorerCard: View {
    @Binding var draft: InspectDraft
    var body: some View {
        EvalCard(title: "Scorer · how the answer is marked") {
            OptionGrid(options: inspectScorers, selection: $draft.scorer)
            if ["includes", "match"].contains(draft.scorer) { Toggle("Ignore upper and lower case", isOn: $draft.ignoreCase).toggleStyle(.checkbox) }
            if draft.scorer == "pattern" {
                TextField("Regular expression with one group, e.g. ANSWER: (\\w+)", text: $draft.pattern).textFieldStyle(.roundedBorder).frame(maxWidth: 520)
            }
            if draft.scorer.hasPrefix("model_graded") {
                TextField("Instructions for the judge (optional)", text: $draft.instructions, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                Label("You choose the judge model on the Run step. It can be a different model from the one tested.", systemImage: "scale.3d").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Options as small cards with a one-line explanation each.
struct OptionGrid: View {
    var options: [(String, String, String)]
    @Binding var selection: String
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
            ForEach(options, id: \.0) { key, title, detail in
                let on = selection == key
                Button { selection = key } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? DynoBrand.accent : .secondary)
                            Text(title).font(.callout.weight(.semibold))
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(on ? DynoBrand.accent.opacity(0.10) : DynoBrand.background))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? DynoBrand.accent : Color.secondary.opacity(0.2)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct TaskFileCard: View {
    @Binding var draft: InspectDraft
    var body: some View {
        EvalCard(title: "Inspect task file") {
            Label("This is Python code. It runs on your Mac with your permissions when you start the eval. Read it first.", systemImage: "exclamationmark.shield")
                .font(.callout).foregroundStyle(.orange)
            if draft.tasks.count > 1 {
                Picker("Task", selection: $draft.taskName) { ForEach(draft.tasks, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 320)
            } else {
                Text("Task: \(draft.taskName)").font(.callout.monospaced())
            }
            ScrollView {
                Text(draft.taskCode).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.background)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }
}

// MARK: - 3 · Run

struct InspectRunPanel: View {
    var draft: InspectDraft
    var needsJudge: Bool
    var servers: [(port: Int, label: String, model: String)]
    @Binding var chosen: Set<Int>
    @Binding var judgePort: Int
    @Binding var epochs: Int
    var running: [String: Any]?
    var starting: Bool
    var onStart: () -> Void
    var onCancel: (String) -> Void
    var onStartModel: () -> Void
    var onResults: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EvalCard(title: "Eval") {
                Text(draft.title.isEmpty ? "Untitled" : draft.title).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            EvalCard(title: "Which models") {
                if servers.isEmpty {
                    Text("No model is running.").foregroundStyle(.secondary)
                    Button("Start a model in Models…", action: onStartModel).buttonStyle(.link)
                }
                ForEach(servers, id: \.port) { s in
                    Toggle("\(s.label) · :\(String(s.port))", isOn: Binding(get: { chosen.contains(s.port) }, set: { on in if on { chosen.insert(s.port) } else { chosen.remove(s.port) } }))
                        .toggleStyle(.checkbox)
                }
                Text("Each model runs the whole eval in turn, through Inspect's OpenAI-compatible provider pointed at its local server.").font(.caption).foregroundStyle(.secondary)
            }
            if needsJudge {
                EvalCard(title: "Judge model") {
                    Picker("Judge", selection: $judgePort) {
                        Text("Choose…").tag(0)
                        ForEach(servers, id: \.port) { s in Text("\(s.label) · :\(String(s.port))").tag(s.port) }
                    }.frame(maxWidth: 420)
                    Text("Inspect calls it the grader. It reads each answer and marks it. Using the model under test as its own judge is allowed, but a different model is fairer.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            EvalCard(title: "Epochs") {
                Stepper("\(epochs) per sample", value: $epochs, in: 1...20).frame(maxWidth: 260)
            }
            HStack {
                Button(starting ? "Starting…" : "Start with Inspect →", action: onStart).buttonStyle(.dynoPrimary)
                    .disabled(starting || chosen.isEmpty || (needsJudge && judgePort == 0) || running?["status"] as? String == "running")
                if running?["status"] as? String == "running" { Text("An Inspect run is in progress.").font(.caption).foregroundStyle(.secondary) }
            }
            if let running { RunProgressCard(run: running, onCancel: onCancel, onResults: onResults) }
        }
    }

    private var summary: String {
        switch draft.kind {
        case "task_file": return "Inspect task “\(draft.taskName)” from \(draft.taskFile)"
        case "library": return "Benchmark \(draft.library)\(draft.limit > 0 ? " · first \(draft.limit) samples" : "")"
        default:
            let solver = inspectSolvers.first { $0.0 == draft.solver }?.1 ?? draft.solver
            let scorer = inspectScorers.first { $0.0 == draft.scorer }?.1 ?? draft.scorer
            return "\(draft.filledRows) samples · \(solver) · \(scorer)"
        }
    }
}

struct RunProgressCard: View {
    var run: [String: Any]
    var onCancel: (String) -> Void
    var onResults: () -> Void

    var body: some View {
        let status = run["status"] as? String ?? ""
        EvalCard(title: "Inspect run · \(status)") {
            Text(run["title"] as? String ?? "").font(.headline)
            ForEach((run["models"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                modelRow((run["models"] as? [[String: Any]] ?? [])[i])
            }
            HStack {
                if status == "running", let id = run["id"] as? String { Button("Cancel") { onCancel(id) } }
                if status != "running" { Button("See the results →", action: onResults).buttonStyle(.dynoPrimary) }
            }
        }
    }

    private func modelRow(_ m: [String: Any]) -> some View {
        let done = m["done"] as? Int ?? 0, total = m["total"] as? Int ?? 0, st = m["status"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(m["label"] as? String ?? "").font(.callout.weight(.semibold)).frame(width: 220, alignment: .leading).lineLimit(1)
                if st == "running" { DynoSpinner() }
                DynoProgressBar(value: Double(done), total: Double(max(total, 1)), width: 200)
                Text(total > 0 ? "\(done)/\(total)" : st).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if st == "done" {
                    Text("\(evalPercent(m["accuracy"])) correct").font(.callout.bold()).foregroundStyle(evalColor(m["accuracy"] as? Double))
                }
            }
            if let e = m["error"] as? String, !e.isEmpty { Text(e).font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(4) }
        }
    }
}

// MARK: - 4 · Results: Inspect evals

struct InspectRateCell: View {
    var cell: [String: Any]
    var selected: Bool
    var body: some View {
        let rate = cell["rate"] as? Double, n = cell["n"] as? Int ?? 0
        let color = n < 5 ? Color.secondary : evalColor(rate)
        let ci = cell["ci"] as? [Double] ?? []
        VStack(alignment: .leading, spacing: 2) {
            Text(evalPercent(rate) + " correct").font(.title3.bold()).foregroundStyle(color)
            Text(ci.count == 2 ? "95%: \(Int((ci[0] * 100).rounded()))–\(Int((ci[1] * 100).rounded()))%" : "").font(.caption2).foregroundStyle(.secondary)
            Text("\(cell["pass"] as? Int ?? 0) of \(n) samples").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).frame(width: 170, height: 64, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(selected ? 0.22 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? color : color.opacity(0.35), lineWidth: selected ? 2 : 1))
    }
}

struct InspectResultsBoard: View {
    var cells: [[String: Any]]
    @Binding var selected: String?   // "def|label"

    private var evals: [(id: String, title: String, kind: String)] {
        var seen = Set<String>(), out: [(String, String, String)] = []
        for c in cells { let id = c["def_id"] as? String ?? ""; if seen.insert(id).inserted { out.append((id, c["title"] as? String ?? "", c["kind"] as? String ?? "")) } }
        return out
    }
    private var labels: [String] {
        var seen = Set<String>(), out: [String] = []
        for c in cells { let l = c["label"] as? String ?? ""; if seen.insert(l).inserted { out.append(l) } }
        return out
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Eval").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                    ForEach(labels, id: \.self) { l in Text(l).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 170, alignment: .leading).lineLimit(2) }
                }
                ForEach(evals, id: \.id) { e in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.callout.weight(.semibold)).lineLimit(2)
                            Text(inspectKindLabel(e.kind)).font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 260, alignment: .leading)
                        ForEach(labels, id: \.self) { l in cellView(e.id, l) }
                    }
                }
            }.padding(2)
        }
    }

    @ViewBuilder private func cellView(_ id: String, _ label: String) -> some View {
        if let c = cells.first(where: { $0["def_id"] as? String == id && $0["label"] as? String == label }) {
            Button { selected = "\(id)|\(label)" } label: { InspectRateCell(cell: c, selected: selected == "\(id)|\(label)") }.buttonStyle(.plain)
        } else {
            Text("not run").font(.caption).foregroundStyle(.tertiary).frame(width: 170, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

/// One eval × model: the latest run's samples, and Inspect's own viewer.
struct InspectCellDetail: View {
    var lab: ResearchLab
    var cell: [String: Any]
    @State private var run: [String: Any]?
    @State private var filter = "all"
    @State private var issue: String?
    @State private var opening = false

    var body: some View {
        let model = (run?["models"] as? [[String: Any]] ?? []).first { $0["label"] as? String == cell["label"] as? String }
        let samples = (model?["samples"] as? [[String: Any]] ?? []).filter { filter == "all" || (filter == "failed") == !($0["passed"] as? Bool ?? false) }
        EvalCard(title: "\(cell["title"] as? String ?? "") · \(cell["label"] as? String ?? "")") {
            HStack(spacing: 14) {
                stat("Correct", evalPercent(cell["rate"]), evalColor(cell["rate"] as? Double))
                stat("Samples", "\(cell["pass"] as? Int ?? 0) of \(cell["n"] as? Int ?? 0)", .primary)
                stat("Runs", "\(cell["runs"] as? Int ?? 1)", .primary)
                Spacer()
                Button(opening ? "Opening…" : "Open in Inspect View ↗", action: openViewer).buttonStyle(.dynoPrimary).disabled(opening)
                    .help("Inspect's own log viewer: every message, score and judge explanation.")
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            Picker("", selection: $filter) { Text("All").tag("all"); Text("Failed").tag("failed"); Text("Passed").tag("passed") }
                .pickerStyle(.segmented).frame(width: 260)
            if run == nil { HStack { DynoSpinner(); Text("Loading samples…").font(.caption) } }
            ForEach(samples.prefix(100).indices, id: \.self) { i in SampleResultRow(sample: samples[i]) }
            if samples.count > 100 { Text("Showing 100 of \(samples.count). Inspect View shows them all.").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: cell["run"] as? String) { await load() }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(color)
        }
    }

    private func load() async {
        guard let id = cell["run"] as? String else { return }
        do { run = try await lab.request("/sandbox/evals/inspect/runs/\(id)", timeout: 30) } catch { issue = error.localizedDescription }
    }

    private func openViewer() {
        opening = true
        Task { @MainActor in
            defer { opening = false }
            do {
                let r = try await lab.request("/sandbox/evals/inspect/view", body: ["run": cell["run"] as? String ?? ""], timeout: 60)
                if let s = r["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) } else { issue = "Inspect View didn't start." }
            } catch { issue = error.localizedDescription }
        }
    }
}

struct SampleResultRow: View {
    var sample: [String: Any]
    @State private var expanded = false

    var body: some View {
        let ok = sample["passed"] as? Bool ?? false, partial = sample["partial"] as? Bool ?? false
        let color: Color = ok ? DynoBrand.accent : partial ? .orange : .red
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : partial ? "circle.lefthalf.filled" : "xmark.circle.fill").foregroundStyle(color)
                Text((sample["input"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).font(.callout).lineLimit(expanded ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
                if let e = sample["epoch"] as? Int { Text("epoch \(e)").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EXPECTED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(sample["target"] as? String ?? "").font(.caption).lineLimit(expanded ? nil : 2)
                }.frame(width: 200, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MODEL ANSWERED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text((sample["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).font(.caption).lineLimit(expanded ? nil : 3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, 24)
            if expanded, let ex = sample["explanation"] as? String, !ex.isEmpty {
                Text("Scorer: \(ex)").font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3)))
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .copyable("\(sample["input"] as? String ?? "")\n\nExpected: \(sample["target"] as? String ?? "")\n\nAnswer: \(sample["output"] as? String ?? "")")
    }
}


/// A gated Hugging Face dataset: accept its terms there, then give Dyno a token (kept in the Keychain).
struct GatedDatasetNotice: View {
    var page: String?
    @State private var token = ""
    @State private var saved = HuggingFaceToken.load() != nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Its dataset is gated on Hugging Face. Accept the terms on its page while logged in, then add an access token.", systemImage: "lock")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if let page, let url = URL(string: page) { Link("Accept the terms ↗", destination: url).font(.caption) }
                Link("Create a read token ↗", destination: URL(string: "https://huggingface.co/settings/tokens")!).font(.caption)
            }
            if saved {
                HStack {
                    Label("Hugging Face token saved in the Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(DynoBrand.accent)
                    Button("Forget") { HuggingFaceToken.delete(); saved = false }.buttonStyle(.link).font(.caption)
                }
            } else {
                HStack {
                    SecureField("hf_…", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Button("Save") { if HuggingFaceToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) { saved = true; token = "" } }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("It is sent only with a run, to the process that downloads the dataset, and never saved with the run.").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))
    }
}
