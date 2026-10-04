import SwiftUI
import DynoKit

struct StudyInvestigationPicker: View {
    let lab: ResearchLab
    var initialStudyID: String? = nil
    var initialEntryID: UUID? = nil
    var onPrepared: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var studies: [[String: Any]] = []
    @State private var study: [String: Any] = [:]
    @State private var selection = ""
    @State private var method = "probe"
    @State private var condition = ""
    @State private var error: String?
    @State private var notebookEntries: [ResearchEntry] = []
    @State private var selectedEntries: Set<UUID> = []
    private var isNotebook: Bool { selection.hasPrefix("notebook:") }
    private var pickedEntries: [ResearchEntry] { notebookEntries.filter { selectedEntries.contains($0.id) } }
    private var protocolData: [String: Any] { study["protocol"] as? [String: Any] ?? [:] }
    private var conditions: [[String: Any]] { protocolData["conditions"] as? [[String: Any]] ?? [] }
    private var cases: [[String: Any]] { protocolData["cases"] as? [[String: Any]] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Investigate further", systemImage: "flask").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            Text("Use a saved study as the source for an internal analysis. The original study stays unchanged.").foregroundStyle(.secondary)
            Picker("Saved study", selection: $selection) {
                Text("Choose a study").tag("")
                ForEach(lab.journal.studies) { item in Text("Notebook · " + item.title).tag("notebook:" + item.id.uuidString) }
                ForEach(Array(studies.enumerated()), id: \.offset) { _, item in Text(item["title"] as? String ?? "Study").tag(item["id"] as? String ?? "") }
            }
            Picker("Analysis", selection: $method) {
                Text("Probes").tag("probe")
                Text("Activations").tag("inspect")
                Text("Interventions").tag("compare")
                Text("SAE sandbox").tag("sae")
            }.pickerStyle(.segmented)
            if isNotebook {
                Text("Select saved prompt entries").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notebookEntries) { entry in
                            Toggle(isOn: Binding(get: { selectedEntries.contains(entry.id) }, set: { if $0 { selectedEntries.insert(entry.id) } else { selectedEntries.remove(entry.id) } })) {
                                VStack(alignment: .leading) {
                                    Text(entry.title).font(.subheadline.bold())
                                    Text(entry.iteration?.prompt ?? "").font(.caption).lineLimit(2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if notebookEntries.isEmpty { Text("No saved prompt entries available in this notebook.").foregroundStyle(.secondary) }
                    }
                }.frame(height: 140)
                Text(method == "probe" ? "Define what labels 0 and 1 mean, label each example, and assign independent scenario groups to train/validation/test in Analyze. Notebook titles and answers are not automatically treated as labels." : "Activations and interventions use the first selected entry. SAE uses all selected entries.").font(.callout)
                Text("System instructions and conversation context are copied as role-labeled text. This does not reproduce the original model's chat template.").font(.caption).foregroundStyle(.secondary)
            } else if method == "probe" {
                Text("Probe question: can representations distinguish the conditions?").font(.headline)
                Text("Labels identify the first two conditions, not Pass/Fail or sycophancy. Each source case contributes one prompt per condition. Repeated runs are not duplicated as new examples.")
                Text("\(cases.count) source cases · \(cases.count * min(2, conditions.count)) prompt examples").font(.headline)
                Text("This prepares a dataset draft. Assign whole scenario groups to train, validation and test, and add independent scenarios. Each split needs at least four examples and both labels. No splits or new evidence are invented.").foregroundStyle(.secondary)
            } else {
                Picker("Source instruction", selection: $condition) {
                    ForEach(Array(conditions.enumerated()), id: \.offset) { _, item in Text(item["id"] as? String ?? "").tag(item["id"] as? String ?? "") }
                }
                Text(method == "sae" ? "Copies source prompts into an SAE dataset draft. A few prompts are insufficient for meaningful feature discovery." : "Copies the first source case with the selected instruction. Review the layers and settings in Analyze before running.")
            }
            Text("Captures use raw text in a fresh forward pass. They are not recordings of the original generation or its chat template. Choose a compatible model in Analyze; nothing runs automatically.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            Spacer()
            HStack { Text("Source study and entry references will be included in the analysis settings.").font(.caption).foregroundStyle(.secondary); Spacer()
                Button("Prepare analysis") { prepare() }.buttonStyle(.dynoPrimary).disabled(isNotebook ? pickedEntries.isEmpty : (study.isEmpty || cases.isEmpty || (method == "probe" && conditions.count != 2)))
            }
        }.padding(24).frame(width: 710, height: 680).background(DynoBrand.background).dynoTheme()
        .task {
            do { lab.journal.reload(); await lab.start(); studies = try await lab.request("/studies")["studies"] as? [[String: Any]] ?? []; selection = initialStudyID ?? "" }
            catch { self.error = error.localizedDescription }
        }
        .task(id: selection) {
            study = [:]; notebookEntries = []; selectedEntries = []
            guard !selection.isEmpty else { return }
            do {
                if isNotebook, let id = UUID(uuidString: String(selection.dropFirst("notebook:".count))) {
                    let entries = try ResearchNotebook().entries(id)
                    let hidden = ResearchTimelineArchive.hiddenIDs(in: entries)
                    notebookEntries = entries.filter { entry in
                        guard entry.iteration != nil, !hidden.contains(entry.id) else { return false }
                        if entry.kind == "result" { return true }
                        return entry.kind == "iteration" && !entries.contains { $0.parent == entry.id && $0.kind == "result" }
                    }
                    if let initialEntryID, notebookEntries.contains(where: { $0.id == initialEntryID }) { selectedEntries = [initialEntryID] }
                    return
                }
                let value = try await lab.request("/studies/\(selection)")
                guard !Task.isCancelled else { return }
                study = value; condition = conditions.first?["id"] as? String ?? ""
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func prepare() {
        if isNotebook { prepareNotebook(); return }
        var config: [String: Any] = ["source_study_id": selection, "source_study_title": study["title"] as? String ?? "", "source_protocol_hash": study["protocol_hash"] as? String ?? "", "layers": [4, 8], "max_input_tokens": 256]
        let chosen = conditions.first { $0["id"] as? String == condition } ?? conditions.first ?? [:]
        func input(_ item: [String: Any], _ instruction: [String: Any]) -> String {
            (item["prompt"] as? String ?? "") + "\n\n" + (instruction["instruction"] as? String ?? "")
        }
        if method == "probe" {
            config["probe_validation"] = true
            config["label_meaning"] = Dictionary(uniqueKeysWithValues: conditions.prefix(2).enumerated().map { (String($0.offset), $0.element["id"] as? String ?? "") })
            config["examples"] = cases.flatMap { item in conditions.prefix(2).enumerated().map { index, c in
                ["text": input(item, c), "label": index, "group": item["group"] as? String ?? item["id"] as? String ?? "source", "split": "unassigned"] as [String: Any]
            } }
        } else if method == "sae" {
            config["examples"] = cases.map { ["text": input($0, chosen)] }
        } else { config["prompt"] = input(cases[0], chosen) }
        lab.investigationDraft = .init(operation: method, configuration: ResearchLab.pretty(config))
        lab.tokenAnalysis = false
        dismiss(); onPrepared()
    }
    private func prepareNotebook() {
        let sourceID = String(selection.dropFirst("notebook:".count))
        let title = lab.journal.studies.first { $0.id.uuidString == sourceID }?.title ?? "Notebook"
        func input(_ entry: ResearchEntry) -> String {
            entry.iteration?.messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n") ?? ""
        }
        var config: [String: Any] = ["source_study_id": sourceID, "source_study_kind": "notebook", "source_study_title": title,
            "source_entry_ids": pickedEntries.map { $0.id.uuidString }, "layers": [4, 8], "max_input_tokens": 256]
        if method == "probe" {
            config["probe_validation"] = true
            config["label_meaning"] = ["0": "Define negative class", "1": "Define positive class"]
            config["examples"] = pickedEntries.map { ["text": input($0), "label": -1, "group": sourceID, "split": "unassigned"] as [String: Any] }
        } else if method == "sae" { config["examples"] = pickedEntries.map { ["text": input($0)] } }
        else if let entry = pickedEntries.first { config["prompt"] = input(entry) }
        lab.investigationDraft = .init(operation: method, configuration: ResearchLab.pretty(config))
        lab.tokenAnalysis = false
        dismiss(); onPrepared()
    }

}
