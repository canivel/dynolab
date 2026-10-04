import AppKit
import DynoKit
import SwiftUI
import UniformTypeIdentifiers

struct MonitorEvaluationView: View {
    var model: MonitorModel
    let sourceID: String
    var initialEvaluationID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [[String: Any]] = []
    @State private var evaluation: [String: Any] = [:]
    @State private var report: [String: Any] = [:]
    @State private var title = "Response monitor comparison"
    @State private var view = "answer"
    @State private var mode = "exploratory"
    @State private var threshold = 0.5
    @State private var budget = 256.0
    @State private var endpoint = ""
    @State private var working = false
    @State private var error: String?
    private var lab: ResearchLab { model.researchLab }
    private var id: String? { evaluation["id"] as? String }
    private var active: Bool { ["running", "cancelling"].contains(evaluation["status"] as? String ?? "") }
    private var servers: [LLMModel] { model.snapshot.models.filter { $0.port != nil } }
    private var configuration: [String: Any] { evaluation["config"] as? [String: Any] ?? [:] }
    private var hasPendingItems: Bool {
        let completed = Set((evaluation["runs"] as? [[String:Any]] ?? []).filter { $0["status"] as? String == "completed" }.compactMap { $0["item_id"] as? String })
        return (evaluation["items"] as? [[String:Any]] ?? []).contains { item in
            (item["excluded"] == nil || item["excluded"] is NSNull) && !completed.contains(item["id"] as? String ?? "")
        }
    }
    private var endpointReady: Bool {
        servers.contains { Int($0.port ?? 0) == configuration["port"] as? Int }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Evaluate a response monitor", systemImage: "checkmark.shield").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Compare a model’s scores with saved reference judgments. Positive means the response fails your rubric.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                VStack(alignment: .leading) {
                    Button("New evaluation") { evaluation = [:]; report = [:] }.disabled(active || working)
                    List(Array(saved.enumerated()), id: \.offset) { _, item in
                        Button { if let id = item["id"] as? String { perform { try await load(id) } } } label: {
                            VStack(alignment: .leading) {
                                Text(item["title"] as? String ?? "Evaluation")
                                Text("\(item["view"] as? String ?? "") · \(item["status"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).disabled(working)
                    }
                    Text("Saved reports stay available with no model running.").font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 200, idealWidth: 230, maxWidth: 270)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if id == nil { editor } else { results }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 600)
            }
        }.padding(22).frame(minWidth: 940, minHeight: 700).background(DynoBrand.background).dynoTheme()
        .task {
            do {
                let health = try await lab.request("/health")
                guard health["monitor_evaluations"] as? Int == 1 else {
                    error = "Restart the local preview’s Lab service to enable monitor evaluations. Saved studies remain intact."
                    return
                }
                try await refresh()
                if let initialEvaluationID { try await load(initialEvaluationID) }
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    if let id, !working { try await load(id) }
                }
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Choose the evidence and monitor").font(.title3.bold())
            Text("First save pass/fail judgments on the study’s responses. Uncertain or conflicting references are excluded. Local reviewer identities are self-reported.")
            DynoFormField("Evaluation title", text: $title)
            Picker("Evidence shown to the monitor", selection: $view) {
                Text("Final answer only").tag("answer")
                Text("Model-emitted thinking only").tag("thinking")
                Text("Answer and thinking").tag("combined")
            }
            Text("Missing thinking is excluded. Thinking text is not verified reasoning. The shared prompt and rubric are included; condition names, reference labels and target identity are hidden.").font(.caption).foregroundStyle(.secondary)
            Picker("Monitor model or pool", selection: $endpoint) {
                Text("Select a running endpoint").tag("")
                ForEach(servers) { server in Text("\(server.name) · :\(server.port!)").tag(server.id) }
            }
            Picker("Evaluation mode", selection: $mode) {
                Text("Exploratory · development cases only").tag("exploratory")
                Text("Held-out · separate development and test groups").tag("held-out")
            }
            Text("Failure score threshold: \(threshold, specifier: "%.2f")")
            Slider(value: $threshold, in: 0...1, step: 0.05)
            Text("Fixed before execution. To change this later, create another evaluation. Reusing test data across evaluations must be disclosed; this app cannot make reused data unseen.").font(.caption).foregroundStyle(.secondary)
            Text("Maximum output per judgment: \(Int(budget)) tokens")
            Slider(value: $budget, in: 32...992, step: 32)
            Button("Prepare and review budget") {
                guard let server = servers.first(where: { $0.id == endpoint }), let port = server.port else { return }
                perform {
                    evaluation = try await lab.request("/monitors", body: ["source_id": sourceID, "config": ["title": title, "port": Int(port), "model": server.identifier, "view": view, "mode": mode, "threshold": threshold, "max_tokens": Int(budget)]])
                    try await refresh()
                    if let id { try await load(id) }
                }
            }.buttonStyle(.dynoPrimary).disabled(working || endpoint.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Preparation saves a snapshot. It does not send inference requests or change the original labels.").font(.caption)
        }
    }

    @State private var priorTestExposure = false
    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(configuration["title"] as? String ?? "Monitor evaluation").font(.title2.bold())
            Text("\(evaluation["status"] as? String ?? "") · \(configuration["view"] as? String ?? "") · \(configuration["mode"] as? String ?? "")")
            Text("Monitor: \(configuration["model"] as? String ?? "unknown") · :\(configuration["port"] as? Int ?? 0)")
            if let target = evaluation["target"] as? [String: Any] { Text("Target: \(target["model"] as? String ?? "unknown")") }
            if let issue = evaluation["error"] as? String { Text(issue).foregroundStyle(.orange) }
            let cost = evaluation["budget"] as? [String: Any] ?? [:]
            Text("Prepared budget: \(cost["requests"] as? Int ?? 0) requests · up to \(cost["max_output_tokens"] as? Int ?? 0) output tokens").font(.headline)
            Text("Input tokens and runtime overhead are additional. Requests use the selected endpoint serially and can delay other inference.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if hasPendingItems { Button("Run / resume monitor") { action("run") }.buttonStyle(.dynoPrimary).disabled(active || working || !endpointReady) }
                if active { Button("Cancel", role: .destructive) { action("cancel") } }
                Button("Export report…") { exportReport() }.disabled(active || working)
            }
            if hasPendingItems && !endpointReady { Text("Start a runtime on the saved port to run this evaluation. Confirm that it serves the intended model; model revisions are not automatically verified. The report remains readable offline.").foregroundStyle(.orange) }
            Text("\((evaluation["runs"] as? [Any] ?? []).count) recorded attempts. Cancellation stops scheduling; an in-flight request may finish first.").font(.caption)
            ForEach(Array((report["rows"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, row in
                reportSection(row)
            }
            if !active { thresholdSelection }
            Text(evaluation["threshold_policy"] as? String ?? "").font(.caption)
            DisclosureGroup("Frozen protocol, input evidence and attempt history") {
                Text(ResearchLab.pretty(evaluation)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text(report["limitation"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var thresholdSelection: some View {
        DisclosureGroup("Select threshold using development predictions") {
            Text("Tests thresholds 0.1 through 0.9 for minimum balanced error on development predictions. Requires both reference classes and separate labeled test groups. Creates a new evaluation without running it.")
            Toggle("I have already inspected or used the test results",isOn:$priorTestExposure)
            Button("Prepare evaluation with selected threshold") { selectThreshold() }.disabled(working)
        }
    }
    private func selectThreshold() {
        guard let id else { return }
        perform {
            let child = try await lab.request("/monitors/\(id)/select-threshold",body:["candidates":(1...9).map { Double($0)/10 },"prior_test_exposure":priorTestExposure])
            if let childID=child["id"] as? String { try await load(childID) }
            try await refresh()
        }
    }

    private func reportSection(_ row: [String: Any]) -> some View {
        let m = row["metrics"] as? [String: Any] ?? [:]
        return VStack(alignment: .leading, spacing: 10) {
            Text("\((row["split"] as? String ?? "").capitalized) · \(m["n"] as? Int ?? 0) scored responses").font(.title3.bold())
            Text("Reference positives: \(m["positives"] as? Int ?? 0) · negatives: \(m["negatives"] as? Int ?? 0)")
            HStack {
                metric("True positives", m["tp"]); metric("False positives", m["fp"])
                metric("True negatives", m["tn"]); metric("Missed positives", m["fn"])
            }
            Text("Precision \(rate(m["precision"])) · Recall \(rate(m["recall"])) · False-positive rate \(rate(m["false_positive_rate"])) · Brier \(rate(m["brier_score"]))")
            let exclusions = row["exclusions"] as? [String: Int] ?? [:]
            Text(exclusions.isEmpty ? "No excluded responses" : "Excluded: " + exclusions.keys.sorted().map { "\($0.replacingOccurrences(of: "_", with: " ")): \(exclusions[$0] ?? 0)" }.joined(separator: " · ")).font(.caption)
            ForEach(Array((row["disagreements"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, item in
                DisclosureGroup("Disagreement · score \(rate(item["score"])) · reference \(item["reference"] as? Bool == true ? "failure" : "pass")") {
                    Text(ResearchLab.pretty(item)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func metric(_ title: String, _ value: Any?) -> some View {
        VStack(alignment: .leading) { Text("\(value as? Int ?? 0)").font(.title2.bold()); Text(title).font(.caption) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func rate(_ value: Any?) -> String { (value as? NSNumber).map { String(format: "%.3f", $0.doubleValue) } ?? "unavailable" }
    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }; working = true; error = nil
        Task { defer { working = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func refresh() async throws { saved = (try await lab.request("/monitors"))["evaluations"] as? [[String: Any]] ?? []; saved = saved.filter { $0["source_id"] as? String == sourceID } }
    private func load(_ id: String) async throws { evaluation = try await lab.request("/monitors/\(id)"); report = try await lab.request("/monitors/\(id)/report") }
    private func action(_ name: String) { guard let id else { return }; perform { _ = try await lab.request("/monitors/\(id)/\(name)", body: [:]); try await load(id); try await refresh() } }
    private func exportReport() {
        guard let id else { return }; let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "monitor-evaluation.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { let data = try await lab.request("/monitors/\(id)/export"); try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
    }
}
