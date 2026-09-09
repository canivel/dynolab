import AppKit
import Charts
import DynoKit
import SwiftUI

struct ResearchLabView: View {
    var model: MonitorModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("Lab workspace", selection: Binding(
                get: { model.researchLab.tokenAnalysis },
                set: { model.researchLab.tokenAnalysis = $0 }
            )) {
                Text("Experiments").tag(false)
                Text("Token analysis").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            Divider()
            if model.researchLab.tokenAnalysis {
                TokenAnalysisView(model: model)
            } else {
                ResearchExperimentView(model: model)
            }
        }
        .onAppear { if model.researchLab.draftPrompt != nil { model.researchLab.tokenAnalysis = false } }
        .onChange(of: model.researchLab.draftPrompt) { _, value in
            if value != nil { model.researchLab.tokenAnalysis = false }
        }
    }
}

private struct ResearchExperimentView: View {
    var model: MonitorModel
    @State private var operation = "inspect"
    @State private var modelPath = ""
    @State private var configuration = Self.template("inspect")
    @State private var raw = false
    @State private var advanced = false
    private var lab: ResearchLab { model.researchLab }
    private let operations = ["inspect", "compare", "probe", "sae"]
    private func name(_ value: String) -> String {
        ["inspect": "Activations", "compare": "Interventions", "probe": "Probes", "sae": "SAE sandbox"][value] ?? value
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "flask").foregroundStyle(.purple)
                Text("Research Lab").font(.headline)
                Text(lab.connected ? "Local API :\(String(lab.port))" : "Service stopped").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !lab.connected { Button("Start lab") { Task { await lab.start(); await lab.refresh() } } }
                Button("Export experiment") { lab.export() }.disabled(lab.job.isEmpty)
            }.padding(14)
            Text("Isolated experiments · raw text inputs · results saved locally · measurements, not safety certifications")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 10)
            if let error = lab.error { Text(error).foregroundStyle(.red).font(.caption).padding(8) }
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("NEW EXPERIMENT").font(.caption).foregroundStyle(.secondary)
                        Picker("Method", selection: $operation) { ForEach(operations, id: \.self) { Text(name($0)).tag($0) } }
                        Picker("Local model", selection: $modelPath) {
                            Text("Choose model").tag("")
                            ForEach(model.localModels) { item in Text(item.shortName + (isServing(item) ? " · Serving now" : "")).tag(item.path) }
                        }
                        resourceStatus
                        Text(description).font(.caption).foregroundStyle(.secondary)
                        if operation == "inspect" || operation == "compare" {
                            TextField("Prompt", text: Binding(get: { parameters["prompt"] as? String ?? "" }, set: { setParameter("prompt", $0) }), axis: .vertical)
                                .lineLimit(3...5).textFieldStyle(.roundedBorder)
                            if operation == "compare" {
                                Picker("Intervention", selection: Binding(get: { parameters["intervention"] as? String ?? "scale" }, set: { setParameter("intervention", $0) })) {
                                    Text("Scale").tag("scale"); Text("Ablate").tag("ablate"); Text("Patch").tag("patch"); Text("Steer").tag("steer")
                                }
                                if parameters["intervention"] as? String == "patch" {
                                    TextField("Donor prompt", text: Binding(get: { parameters["donor_prompt"] as? String ?? "" }, set: { setParameter("donor_prompt", $0) })).textFieldStyle(.roundedBorder)
                                }
                                if parameters["intervention"] as? String == "steer" {
                                    TextField("Positive example", text: Binding(get: { parameters["positive"] as? String ?? "" }, set: { setParameter("positive", $0) })).textFieldStyle(.roundedBorder)
                                    TextField("Negative example", text: Binding(get: { parameters["negative"] as? String ?? "" }, set: { setParameter("negative", $0) })).textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        HStack {
                            Text("Parameters & dataset").font(.subheadline)
                            Spacer()
                            Button("Import JSON") { importJSON() }.font(.caption)
                        }
                        DisclosureGroup("Edit layers, settings & examples", isExpanded: $advanced) {
                            TextEditor(text: $configuration).font(.system(size: 11, design: .monospaced))
                                .frame(height: 260).border(Color.secondary.opacity(0.2))
                        }
                        HStack {
                            Button("Run experiment") {
                                // Re-evaluate live conditions at the moment of submission.
                                let check = resources
                                guard check.canRun else { lab.error = check.blockedReason; return }
                                Task { await lab.submit(model: modelPath, operation: operation, configuration: configuration) }
                            }
                                .buttonStyle(.borderedProminent).disabled(!lab.connected || lab.busy || modelPath.isEmpty || !resources.canRun)
                            if lab.busy { Button("Cancel") { Task { await lab.cancel() } }.disabled(!["queued", "running"].contains(lab.job["status"] as? String ?? "")) }
                        }
                        Text("The experiment loads a separate copy, even for the serving model. Serving stays running. Shared GPU and memory bandwidth mean concurrent work can still slow inference; future requests may arrive after this check.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("EXPERIMENT HISTORY").font(.caption).foregroundStyle(.secondary)
                        ForEach(lab.jobs.compactMap { $0["id"] as? String }, id: \.self) { id in
                            if let item = lab.jobs.first(where: { $0["id"] as? String == id }) {
                                Button {
                                    lab.selected = id; Task { await lab.refresh() }
                                } label: {
                                    HStack {
                                        Text(name(item["operation"] as? String ?? ""))
                                        Spacer()
                                        Text(item["status"] as? String ?? "").foregroundStyle(.secondary)
                                    }.font(.caption).padding(7)
                                        .background(lab.selected == id ? Color.accentColor.opacity(0.12) : .clear)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(16)
                }.frame(minWidth: 300, idealWidth: 350, maxWidth: 420)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if lab.job.isEmpty {
                            Text("Turn a question into an experiment.").font(.title2)
                            Text("Inspect activations, train a labeled probe, change a representation, and compare the outcome. Choose a method to load an editable example.").foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text(name(lab.job["operation"] as? String ?? "")).font(.title2)
                                Spacer()
                                Text(lab.job["status"] as? String ?? "").foregroundStyle(.secondary)
                                Toggle("JSON", isOn: $raw).toggleStyle(.checkbox)
                            }
                            if let error = lab.job["error"] as? String { Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
                            if ["running", "queued"].contains(lab.job["status"] as? String ?? "") {
                                ProgressView("Loading model / running experiment…")
                            }
                            if raw { Text(ResearchLab.pretty(lab.job)).font(.caption.monospaced()).textSelection(.enabled) }
                            else if let result = lab.job["result"] as? [String: Any] { resultView(result) }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 400)
            }
        }
        .onAppear {
            selectServingModel()
            if let draft = lab.draftPrompt, !draft.isEmpty {
                configuration = ResearchLab.pretty(["prompt": draft, "layers": [4, 8], "max_input_tokens": 256])
                operation = "inspect"
                if let match = model.localModels.first(where: { $0.name == lab.draftModel || $0.path == lab.draftModel }) { modelPath = match.path }
                lab.draftPrompt = nil; lab.draftModel = nil
            }
        }
        .onChange(of: model.localModels) { _, _ in selectServingModel() }
        .onChange(of: model.snapshot.models) { _, _ in selectServingModel() }
        .onChange(of: operation) { _, value in configuration = Self.template(value); advanced = value == "probe" || value == "sae" }
        .task {
            // The user explicitly starts the service; viewing the tab never loads a model.
            while !Task.isCancelled {
                if lab.connected { await lab.refresh() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    private func isServing(_ item: LocalModel) -> Bool {
        model.snapshot.models.contains {
            $0.identifier == item.path || $0.identifier == item.name ||
            $0.name == item.name || $0.name == item.shortName
        }
    }
    private func selectServingModel() {
        guard modelPath.isEmpty else { return }
        if let current = model.localModels.first(where: { isServing($0) }) { modelPath = current.path }
    }
    private var resources: LabResources {
        LabResources(weightBytes: model.localModels.first(where: { $0.path == modelPath })?.sizeBytes,
            memory: model.snapshot.memory, gpuBusy: model.snapshot.gpu.busyPercent,
            activeRequests: model.snapshot.models.reduce(0) { $0 + ($1.stats?.activeRequests ?? 0) },
            fresh: model.snapshot.interval > 0 && Date().timeIntervalSince(model.snapshot.date) < 10,
            maxInputTokens: parameters["max_input_tokens"] as? Int ?? 256)
    }
    @ViewBuilder private var resourceStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SERVING NOW").font(.caption2).foregroundStyle(.secondary)
            if model.snapshot.models.isEmpty {
                Text("No serving model detected.").font(.caption)
            } else {
                ForEach(model.snapshot.models) { running in
                    Text("\(running.name) · \(running.stats?.activeRequests ?? 0) active requests" +
                        (running.stats == nil ? " (request count unavailable)" : ""))
                        .font(.caption).textSelection(.enabled)
                }
            }
            Divider()
            Text("EXPERIMENT READINESS").font(.caption2).foregroundStyle(.secondary)
            Text("Additional memory estimate: \(Format.bytes(resources.estimatedBytes))")
            Text("Available after reserve: \(Format.bytes(resources.availableBytes))")
            Text("GPU: \(Int(model.snapshot.gpu.busyPercent))% · Reserve: \(Format.bytes(resources.reserveBytes)) · Swap: \(Format.bytes(model.snapshot.memory.swapUsed))")
            Text(resources.blockedReason ?? "Headroom available; no busy GPU or active requests detected.")
                .foregroundStyle(resources.canRun ? Color.secondary : Color.orange)
            Text("Estimate includes 35% weight overhead, workspace and an input-length margin. Peak use varies by model and experiment; this is not a resource reservation.")
                .font(.caption2).foregroundStyle(.secondary)
        }.font(.caption).padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
    private var parameters: [String: Any] {
        guard let data = configuration.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func setParameter(_ key: String, _ value: Any) {
        var config = parameters; config[key] = value
        configuration = ResearchLab.pretty(config)
    }
    private var description: String {
        switch operation {
        case "probe": return "Train a regularized linear classifier on last-token activations. Supply explicit train/test labels. The example is a small sentiment demo, not a validated safety detector."
        case "sae": return "Train a small ReLU sparse autoencoder. Explore feature activations and held-out reconstruction; semantic feature labels are not inferred."
        case "compare": return "Scale, ablate, patch or steer a block's final-token activation. Compare identical-prefix probabilities and greedy continuations."
        default: return "Inspect token-by-layer activation norms and raw logit-lens predictions. Layer indices start at zero."
        }
    }
    @ViewBuilder private func resultView(_ result: [String: Any]) -> some View {
        if let note = result["note"] as? String { Text(note).font(.callout).foregroundStyle(.secondary) }
        if let layers = result["layers"] as? [[String: Any]], let tokens = result["tokens"] as? [String] {
            Text("Activation magnitude · layer × token").font(.headline)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(layers.indices, id: \.self) { index in
                        let values = layers[index]["norms"] as? [Double] ?? []
                        let peak = values.max() ?? 1
                        HStack(spacing: 3) {
                            Text("L\(layers[index]["layer"] as? Int ?? 0)").frame(width: 35)
                            ForEach(values.indices, id: \.self) { position in
                                Text(position < tokens.count ? tokens[position].replacingOccurrences(of: "\n", with: "↵") : "")
                                    .font(.caption.monospaced()).lineLimit(1).frame(width: 55, height: 32)
                                    .background(Color.purple.opacity(0.1 + 0.7 * values[position] / max(peak, 0.001)))
                                    .help("Activation norm: \(values[position])")
                            }
                        }
                    }
                }
            }
            Text("Each row is normalized independently; hover a token for its raw norm.").font(.caption).foregroundStyle(.secondary)
            ForEach(layers.indices, id: \.self) { i in
                if let predictions = layers[i]["predictions"] as? [[[String: Any]]], let last = predictions.last {
                    Text("Layer \(layers[i]["layer"] as? Int ?? 0) · next-token readout: " + last.map { $0["token"] as? String ?? "" }.joined(separator: " · ")).font(.caption.monospaced())
                }
            }
        }
        if let trials = result["trials"] as? [[String: Any]] {
            Text("Change in target-token probability").font(.headline)
            Chart(trials.indices, id: \.self) { i in
                BarMark(x: .value("Trial", String(i+1)), y: .value("Probability change", trials[i]["delta"] as? Double ?? 0)).foregroundStyle(.purple)
            }.frame(height: 180)
            ForEach(trials.indices, id: \.self) { i in
                let row = trials[i]
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trial \(i+1) · strength \(row["strength"] as? Double ?? 0) · target ‘\(row["target_token"] as? String ?? "")’").font(.headline)
                    Text(row["prompt"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        output("Baseline", row["baseline"] as? String ?? "")
                        output("Intervention", row["output"] as? String ?? "")
                    }
                }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        if let reports = result["reports"] as? [[String: Any]] {
            ForEach(reports.indices, id: \.self) { i in
                let report = reports[i]
                Text("Layer \(report["layer"] as? Int ?? 0)").font(.headline)
                if let scores = report["scores"] as? [[String: Any]] {
                    Text(String(format: "Held-out accuracy %.2f · AUROC %.2f · Brier %.3f", report["accuracy"] as? Double ?? 0, report["auc"] as? Double ?? 0, report["brier"] as? Double ?? 0)).font(.callout)
                    Text(String(format: "Controls: majority %.2f · shuffled labels %.2f", report["majority_accuracy"] as? Double ?? 0, report["shuffled_label_accuracy"] as? Double ?? 0)).font(.caption).foregroundStyle(.secondary)
                    Chart(scores.indices, id: \.self) { j in
                        BarMark(x: .value("Example", String(j+1)), y: .value("Probe score", scores[j]["score"] as? Double ?? 0))
                            .foregroundStyle(by: .value("Split", scores[j]["split"] as? String ?? ""))
                    }.chartYScale(domain: 0...1).frame(height: 180)
                    ForEach(scores.indices, id: \.self) { j in
                        Text("\(j+1). [\(scores[j]["split"] as? String ?? "")] \(scores[j]["text"] as? String ?? "")").font(.caption)
                    }
                }
                if let losses = report["losses"] as? [[String: Any]] {
                    Chart(losses.indices, id: \.self) { j in
                        LineMark(x: .value("Step", losses[j]["step"] as? Int ?? 0), y: .value("Loss", losses[j]["loss"] as? Double ?? 0)).foregroundStyle(.purple)
                    }.frame(height: 180)
                    Text(String(format: "Held-out MSE %.3f · mean active %.1f · dead feature fraction %.2f", report["held_out_mse"] as? Double ?? 0, report["mean_active"] as? Double ?? 0, report["dead_fraction"] as? Double ?? 0)).font(.caption)
                    if let features = report["features"] as? [[String: Any]] {
                        ForEach(features.indices, id: \.self) { j in
                            DisclosureGroup("Feature \(features[j]["feature"] as? Int ?? 0)") {
                                Text(ResearchLab.pretty(features[j]["examples"] ?? [])).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        DisclosureGroup("Provenance & artifacts") {
            Text(ResearchLab.pretty(result["provenance"] ?? [:]) + "\n" + ResearchLab.pretty(result["artifacts"] ?? []))
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("Local artifacts: ~/.mlx-dyno/lab/<job ID>/").font(.caption)
        }
    }
    private func output(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(text.isEmpty ? "No visible output (end of sequence)." : text).font(.system(size: 12)).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func importJSON() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { configuration = try String(contentsOf: url, encoding: .utf8) } catch { lab.error = error.localizedDescription }
        }
    }
    private static func template(_ operation: String) -> String {
        var config: [String: Any] = ["layers": [4, 8], "seed": 0, "max_input_tokens": 256]
        if operation == "inspect" { config["prompt"] = "The capital of France is" }
        else if operation == "compare" {
            config.merge(["layers": [8], "prompt": "The capital of France is", "intervention": "scale", "strengths": [0, 0.5, 1, 1.5], "max_tokens": 24]) { _, new in new }
        } else {
            config["layers"] = [8]
            let positive = ["I love this book.", "What a wonderful day.", "This meal is delicious.", "A delightful surprise.", "I enjoyed the concert.", "The service was excellent."]
            let negative = ["I hate this book.", "What a terrible day.", "This meal is disgusting.", "A dreadful surprise.", "I disliked the concert.", "The service was awful."]
            config["examples"] = (0..<6).flatMap { i in [
                ["text": positive[i], "label": 1, "split": i < 4 ? "train" : "test"],
                ["text": negative[i], "label": 0, "split": i < 4 ? "train" : "test"]
            ] }
            if operation == "sae" { config["features"] = 64; config["steps"] = 100 }
        }
        return ResearchLab.pretty(config)
    }
}
