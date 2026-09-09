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
    @State private var restoringSettings = false
    @State private var captureSource = "serving"
    @State private var servingPort: UInt16?
    @State private var capability: [String: Any] = [:]
    @State private var capabilityError: String?
    private var usingServing: Bool { operation == "inspect" && captureSource == "serving" }
    private var displayJob: [String: Any] { usingServing ? lab.servingResult : lab.job }
    private var servingModels: [LLMModel] { model.snapshot.models.filter { $0.port != nil } }
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
                Text(usingServing ? "Resident model · no extra copy" : (lab.connected ? "Local API :\(String(lab.port))" : "Service stopped")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !usingServing && !lab.connected { Button("Start lab") { Task { await lab.start(); await lab.refresh() } } }
                Button("Export experiment") { lab.export(displayJob) }.disabled(displayJob.isEmpty)
            }.padding(14)
            Text(usingServing ? "Read-only serving capture · raw text · automatically saved on this Mac" : "Isolated experiments · raw text inputs · results saved locally · measurements, not safety certifications")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 10)
            if let error = lab.error { Text(error).foregroundStyle(.red).font(.caption).padding(8) }
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("NEW EXPERIMENT").font(.caption).foregroundStyle(.secondary)
                        Picker("Method", selection: $operation) { ForEach(operations, id: \.self) { Text(name($0)).tag($0) } }.disabled(lab.capturing)
                        if operation == "inspect" {
                            Picker("Capture mode", selection: $captureSource) {
                                Text("Inspect serving model").tag("serving")
                                Text("Isolated experiment").tag("isolated")
                            }.disabled(lab.capturing)
                        }
                        if usingServing {
                            Picker("Serving endpoint", selection: $servingPort) {
                                Text("Choose endpoint").tag(Optional<UInt16>.none)
                                ForEach(servingModels) { item in Text("\(item.name) · :\(String(item.port!))").tag(item.port) }
                            }.disabled(lab.capturing)
                            Button("Refresh endpoint") { Task { await loadCapability() } }.font(.caption).disabled(lab.capturing)
                            if let capabilityError {
                                Text(capabilityError).font(.caption).foregroundStyle(.orange)
                                Text("No capture flag is required. Start the endpoint with the updated Dyno app. In Models, stop the old endpoint when you are ready, then start it again on the same port.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Open Models") { model.openModels(for: servingModels.first { $0.port == servingPort }) }
                            }
                        } else {
                            Text("This method runs in an isolated worker with a separate model copy. It does not reuse the serving model’s loaded weights.")
                                .font(.callout).foregroundStyle(.secondary)
                            Picker("Local model", selection: $modelPath) {
                                Text("Choose model").tag("")
                                ForEach(model.localModels) { item in Text(item.shortName).tag(item.path) }
                            }
                        }
                        if !usingServing {
                            Button("Manage running models") { model.openModels(for: servingModels.first { $0.port == servingPort }) }
                                .font(.caption)
                            Text("Choose a downloaded model above or use Models to stop serving when ready. Dyno will not stop an endpoint automatically.")
                                .font(.caption).foregroundStyle(.secondary)
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
                                if usingServing, let port = servingPort, let resident = capability["model"] as? String {
                                    Task { await lab.captureServing(port: port, model: resident, parameters: parameters) }
                                } else {
                                    Task { await lab.submit(model: modelPath, operation: operation, configuration: configuration) }
                                }
                            }
                                .buttonStyle(.borderedProminent).disabled(lab.capturing || !resources.canRun || (usingServing ? (capability["serving_activations"] as? Bool != true || capability["model"] as? String == nil) : (!lab.connected || lab.busy || modelPath.isEmpty)))
                            if lab.busy { Button("Cancel") { Task { await lab.cancel() } }.disabled(!["queued", "running"].contains(lab.job["status"] as? String ?? "")) }
                        }
                        Text(usingServing ? "Reuses loaded weights. Capture waits for a generation scheduling boundary, then runs a fresh bounded forward pass. It can delay inference. No weights or serving caches are changed. Results and settings are saved automatically on this Mac." : "Loads a separate model copy. Serving stays running, but experiments share GPU and memory bandwidth.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Thinking is useful when studying model-emitted reasoning in chat or token analysis. Activation captures, probes and SAEs do not require thinking mode; raw-text experiments bypass the chat template.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = lab.archiveError { Text(error).font(.caption).foregroundStyle(.orange) }
                        Text("SAVED ACTIVATION CAPTURES").font(.caption).foregroundStyle(.secondary)
                        ForEach(lab.savedCaptures.indices, id: \.self) { i in
                            let saved = lab.savedCaptures[i]
                            Button {
                                restoringSettings = operation != "inspect"
                                operation = "inspect"; captureSource = "serving"
                                lab.servingResult = saved
                                if let config = saved["config"] as? [String: Any] { configuration = ResearchLab.pretty(config) }
                                if let port = saved["port"] as? Int { servingPort = UInt16(exactly: port) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text((saved["config"] as? [String: Any])?["prompt"] as? String ?? "Activation capture").lineLimit(1)
                                    Text("\(runDate(saved)) · \(saved["status"] as? String ?? "")").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).disabled(lab.capturing)
                        }
                        Text("Open a saved capture to restore its settings and results. Rerunning creates a new saved run.").font(.caption).foregroundStyle(.secondary)
                        Text("ISOLATED EXPERIMENT HISTORY").font(.caption).foregroundStyle(.secondary)
                        ForEach(lab.jobs.compactMap { $0["id"] as? String }, id: \.self) { id in
                            if let item = lab.jobs.first(where: { $0["id"] as? String == id }) {
                                Button {
                                    captureSource = "isolated"; lab.selected = id
                                    Task {
                                        await lab.refresh()
                                        guard lab.selected == id, let config = lab.job["config"] as? [String: Any] else { return }
                                        let method = config["operation"] as? String ?? "inspect"
                                        restoringSettings = operation != method
                                        operation = method
                                        modelPath = config["model"] as? String ?? ""
                                        configuration = ResearchLab.pretty(config)
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(name(item["operation"] as? String ?? ""))
                                            Text(runDate(item)).font(.caption2).foregroundStyle(.secondary)
                                        }
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
                        if displayJob.isEmpty {
                            Text("Turn a question into an experiment.").font(.title2)
                            Text("Inspect activations, train a labeled probe, change a representation, and compare the outcome. Choose a method to load an editable example.").foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text(name(displayJob["operation"] as? String ?? "")).font(.title2)
                                Spacer()
                                Text(displayJob["status"] as? String ?? "").foregroundStyle(.secondary)
                                Toggle("JSON", isOn: $raw).toggleStyle(.checkbox)
                            }
                            Text("Experiment submitted \(runDate(displayJob))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = displayJob["error"] as? String {
                                Text(usingServing ? "Serving capture failed. The inference server was not stopped or replaced." : "This error belongs to the saved experiment shown above. Starting the Lab service does not rerun it.")
                                    .font(.callout).foregroundStyle(.secondary)
                                DisclosureGroup("Saved error details") {
                                    Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                                }
                            }
                            if ["running", "queued"].contains(displayJob["status"] as? String ?? "") {
                                ProgressView(usingServing ? "Waiting for scheduler / capturing activations…" : "Loading model / running experiment…")
                            }
                            if raw { Text(ResearchLab.pretty(displayJob)).font(.caption.monospaced()).textSelection(.enabled) }
                            else if let result = displayJob["result"] as? [String: Any] { resultView(result) }
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 400)
            }
        }
        .onAppear {
            if CommandLine.arguments.contains("--snapshot"), ProcessInfo.processInfo.environment["DYNO_LAB_RESULT_FIXTURE"] != nil {
                let saved = lab.servingResult
                let method = saved["operation"] as? String ?? "inspect"
                restoringSettings = operation != method
                operation = method
                captureSource = "isolated"
                if let config = saved["config"] as? [String: Any] { configuration = ResearchLab.pretty(config); modelPath = config["model"] as? String ?? "" }
            }
            selectServingModel()
            if servingPort == nil { servingPort = servingModels.first(where: { $0.name != "default_model" })?.port ?? servingModels.first?.port }
            if CommandLine.arguments.contains("--snapshot"), let value = ProcessInfo.processInfo.environment["DYNO_SERVING_PORT"], let port = UInt16(value) { servingPort = port }
            if let draft = lab.draftPrompt, !draft.isEmpty {
                configuration = ResearchLab.pretty(["prompt": draft, "layers": [4, 8], "max_input_tokens": 256])
                operation = "inspect"
                if let match = model.localModels.first(where: { $0.name == lab.draftModel || $0.path == lab.draftModel }) { modelPath = match.path }
                lab.draftPrompt = nil; lab.draftModel = nil
            }
        }
        .onChange(of: usingServing) { _, _ in selectServingModel() }
        .onChange(of: model.localModels) { _, _ in selectServingModel() }
        .onChange(of: model.snapshot.models) { _, _ in
            selectServingModel()
            if !lab.capturing && !servingModels.contains(where: { $0.port == servingPort }) {
                servingPort = servingModels.first(where: { $0.name != "default_model" })?.port ?? servingModels.first?.port
            }
        }
        .task(id: servingPort) { await loadCapability() }
        .onChange(of: operation) { _, value in
            if restoringSettings { restoringSettings = false; return }
            configuration = Self.template(value); advanced = value == "probe" || value == "sae" }
        .task {
            // The user explicitly starts the service; viewing the tab never loads a model.
            while !Task.isCancelled {
                if lab.connected { await lab.refresh() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    private func loadCapability() async {
            capability = [:]; capabilityError = nil
            guard let port = servingPort else { return }
            do {
                let value = try await lab.servingRequest(port: port, path: "capabilities")
                guard !Task.isCancelled, servingPort == port else { return }
                capability = value
                selectServingModel()
                if value["serving_activations"] as? Bool != true { capabilityError = "This server does not support resident activation capture." }
            } catch { if !Task.isCancelled, servingPort == port { capabilityError = error.localizedDescription } }
    }
    private func runDate(_ item: [String: Any]) -> String {
        guard let timestamp = item["created"] as? Double else { return "Unknown date" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .standard)
    }
    private func isServing(_ item: LocalModel) -> Bool {
        model.snapshot.models.contains {
            $0.identifier == item.path || $0.identifier == item.name ||
            $0.name == item.name || $0.name == item.shortName
        }
    }
    private func selectServingModel() {
        guard modelPath.isEmpty else { return }
        // Servers may advertise default_model while capabilities carries the actual path.
        if let current = LabModelSelection.match(capability["model"] as? String, in: model.localModels) {
            modelPath = current.path; return
        }
        if let endpoint = servingModels.first(where: { $0.port == servingPort }),
           let current = LabModelSelection.match(endpoint.identifier, in: model.localModels) {
            modelPath = current.path; return
        }
        if let current = model.selectedModel, model.localModels.contains(current) {
            modelPath = current.path; return
        }
        let matches = model.localModels.filter { isServing($0) }
        if matches.count == 1 { modelPath = matches[0].path }
    }
    private var resources: LabResources {
        LabResources(weightBytes: model.localModels.first(where: { $0.path == modelPath })?.sizeBytes,
            memory: model.snapshot.memory, gpuBusy: model.snapshot.gpu.busyPercent,
            activeRequests: model.snapshot.models.reduce(0) { $0 + ($1.stats?.activeRequests ?? 0) },
            fresh: model.snapshot.interval > 0 && Date().timeIntervalSince(model.snapshot.date) < 10,
            maxInputTokens: parameters["max_input_tokens"] as? Int ?? 256, reuseServingModel: usingServing)
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
            if !usingServing && model.localModels.first(where: { $0.path == modelPath }) == nil {
                Text("Additional memory estimate: select a model first")
            } else {
                Text("Additional memory estimate: \(Format.bytes(resources.estimatedBytes))")
            }
            Text("Available after reserve: \(Format.bytes(resources.availableBytes))")
            Text("GPU: \(Int(model.snapshot.gpu.busyPercent))% · Reserve: \(Format.bytes(resources.reserveBytes)) · Swap: \(Format.bytes(model.snapshot.memory.swapUsed))")
            Text(resources.blockedReason ?? (usingServing ? "Workspace headroom available. Capture is scheduled on the serving thread and can briefly delay requests." : "Headroom available; no busy GPU or active requests detected."))
                .foregroundStyle(resources.canRun ? Color.secondary : Color.orange)
            Text(usingServing ? "Workspace estimate only: already-loaded weights are not counted again. Maximum 256 input tokens and 4 layers. Peak allocation varies." : "Estimate includes 35% weight overhead, workspace and an input-length margin. This is not a resource reservation.")
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
        default: return usingServing ? "Capture token-by-layer activation norms from the loaded model. Up to 4 layers and 256 input tokens; zero-indexed layers. Raw text, no chat template." : "Inspect token-by-layer activation norms and raw logit-lens predictions. Layer indices start at zero."
        }
    }
    @ViewBuilder private func resultView(_ result: [String: Any]) -> some View {
        if let layers = result["layers"] as? [[String: Any]], let tokens = result["tokens"] as? [String] {
            activationResult(result, layers: layers, tokens: tokens)
        } else if let note = result["note"] as? String {
            Text(note).font(.callout).foregroundStyle(.secondary)
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
            Text(usingServing ? "Saved on this Mac in ~/.mlx-dyno/research-history/. Export to share a copy." : "Local artifacts: ~/.mlx-dyno/lab/<job ID>/").font(.caption)
        }
    }
    private func visibleToken(_ token: String) -> String {
        token.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
    }

    @ViewBuilder private func activationResult(_ result: [String: Any], layers: [[String: Any]], tokens: [String]) -> some View {
        let peak = layers.flatMap { $0["norms"] as? [Double] ?? [] }.max() ?? 1
        Text("What does the model predict next?").font(.headline)
        Text(tokens.joined()).font(.body.monospaced()).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        if let predictions = result["next_tokens"] as? [[String: Any]], !predictions.isEmpty {
            Text("Next-token probabilities · final model output").font(.caption).foregroundStyle(.secondary)
            ForEach(predictions.indices, id: \.self) { i in
                let prediction = predictions[i]
                let probability = prediction["probability"] as? Double ?? 0
                HStack(spacing: 12) {
                    Text(visibleToken(prediction["token"] as? String ?? ""))
                        .font(.body.monospaced()).frame(width: 120, alignment: .leading)
                    ProgressView(value: probability, total: 1).tint(.blue)
                    Text(String(format: "%.2f%%", probability * 100)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
            Text("These are candidate next tokens, not a generated answer. · marks a space; ↵ marks a newline. The displayed candidates may not sum to 100%.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("This saved result has no next-token probabilities. Run a new capture to see the prediction.").font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("How strong are the internal representations?").font(.headline)
        Text("Each cell measures the length (L2 norm) of the hidden-state vector after one layer, at one input token. Brighter means a larger vector—not more attention, importance, or confidence.")
            .font(.callout).foregroundStyle(.secondary)
        HStack {
            Text("0").font(.caption.monospaced())
            LinearGradient(colors: [Color.purple.opacity(0.1), Color.purple.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 10).clipShape(Capsule())
            Text(String(format: "%.2f · shared scale across all shown layers", peak)).font(.caption)
        }
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("Layer").frame(width: 65)
                    ForEach(tokens.indices, id: \.self) { i in
                        VStack {
                            Text("#\(i)").foregroundStyle(.secondary)
                            Text(visibleToken(tokens[i])).lineLimit(1)
                        }.font(.caption.monospaced()).frame(width: 85)
                            .help("Token \(i): \(tokens[i])")
                    }
                }
                ForEach(layers.indices, id: \.self) { i in
                    let values = layers[i]["norms"] as? [Double] ?? []
                    HStack(spacing: 4) {
                        Text("L\(layers[i]["layer"] as? Int ?? 0)").frame(width: 65)
                        ForEach(values.indices, id: \.self) { j in
                            Text(String(format: "%.2f", values[j]))
                                .font(.caption.monospaced()).frame(width: 85, height: 38)
                                .background(Color.purple.opacity(0.1 + 0.7 * max(0, values[j]) / max(peak, 0.001)))
                                .help("Layer \(layers[i]["layer"] as? Int ?? 0), token \(j), L2 norm \(values[j])")
                        }
                    }
                }
            }
        }
        Text("Layer and token indices start at zero. Only the selected layers are captured. These aggregate values do not identify individual neurons, concepts, or the model’s reasoning.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(layers.indices, id: \.self) { i in
            if let predictions = layers[i]["predictions"] as? [[[String: Any]]], let last = predictions.last {
                Text("Layer \(layers[i]["layer"] as? Int ?? 0) · intermediate logit-lens candidates: " + last.map { visibleToken($0["token"] as? String ?? "") }.joined(separator: " · ")).font(.caption.monospaced())
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("What to try next").font(.headline)
            Text("Change ‘France’ to ‘Japan’ and rerun. Check whether the next-token prediction changes as expected. A change in activation magnitude alone does not explain why the prediction changed.")
            Text("To test whether a representation affects the output, choose the intervention comparison method in an isolated experiment. Use labeled probes or SAEs to investigate representations beyond their overall magnitude.")
        }.font(.callout).padding(12).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        if let note = result["note"] as? String {
            Text(note).font(.caption).foregroundStyle(.secondary)
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
        if operation == "inspect" { config["prompt"] = "The capital of France is"; config.removeValue(forKey: "seed") }
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
