import AppKit
import DynoKit
import SwiftUI
import UniformTypeIdentifiers

/// The Research Lab's Neurons workspace: start neuron jobs on the left, read the selected job on the right.
struct NeuronsView: View {
    var model: MonitorModel
    @State private var showSetup = !(CommandLine.arguments.contains("--snapshot") && ProcessInfo.processInfo.environment["DYNO_NEURON_SETUP"] == "0")
    private var lab: ResearchLab { model.researchLab }
    private var neurons: NeuronLab { lab.neurons }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "circle.hexagongrid").foregroundStyle(DynoBrand.violet)
                Text("Neurons").font(.headline)
                Text(lab.connected ? "Local API :\(String(lab.port))" : "Service stopped").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !lab.connected { Button("Start lab") { Task { await lab.start(); await neurons.refresh() } } }
                Button(showSetup ? "Hide setup" : "Show setup") { showSetup.toggle() }
                    .help("Give the selected job the whole width.")
                JournalAttachButton(value: neurons.job, title: "Neuron job")
                Button("Export job") { neurons.export(neurons.job, name: "dyno-neurons-\(neurons.job["operation"] as? String ?? "job").json") }
                    .disabled(neurons.job.isEmpty)
            }.padding(14)
            Text("Neuron-level analysis · capture activations on a corpus, read each unit's strongest examples, then test them · measurements, not explanations")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 10)
            if let error = neurons.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { neurons.error = nil }.controlSize(.small)
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                if showSetup {
                    NeuronSetupPanel(model: model).frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                }
                NeuronJobDetail(model: model).frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Viewing the tab never starts the service; it follows it once the user has.
            if CommandLine.arguments.contains("--snapshot") { return }
            if !lab.connected, (try? await lab.request("/health")) != nil { lab.connected = true }
            while !Task.isCancelled {
                if lab.connected { await neurons.refresh(); neurons.openBrowserIfAtlas() }
                do { try await Task.sleep(for: .seconds(neurons.running ? 1 : 3)) } catch { break }
            }
        }
    }
}

// MARK: - Setup

private struct NeuronSetupPanel: View {
    var model: MonitorModel
    private var lab: ResearchLab { model.researchLab }
    private var neurons: NeuronLab { lab.neurons }
    private var servers: [LLMModel] { model.snapshot.models.filter { $0.port != nil } }

    var body: some View {
        @Bindable var neurons = neurons
        let draft = neurons.draft
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("NEW NEURON JOB").font(.caption).foregroundStyle(.secondary)
                Picker("Job", selection: $neurons.draft.operation) {
                    ForEach(NeuronDraft.operations, id: \.self) { Text(NeuronDraft.name($0)).tag($0) }
                }
                Text(Self.explanation(draft.operation)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                form($neurons.draft)
                HStack {
                    Button(neurons.submitting ? "Starting…" : (lab.connected ? "Run job" : "Start lab & run job")) {
                        Task { await neurons.submit() }
                    }.buttonStyle(.dynoPrimary).disabled(blockedReason != nil)
                    if neurons.running {
                        Button("Cancel") { Task { await neurons.cancel() } }
                            .disabled(!["queued", "running"].contains(neurons.job["status"] as? String ?? ""))
                    }
                }
                if let reason = blockedReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Configuration sent to the Lab") {
                    Text((try? draft.configuration()).map(ResearchLab.pretty) ?? "Complete the form to see the configuration.")
                        .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
                Text("The Lab runs one job at a time in a separate process. Jobs load their own model copy and share GPU and memory with serving. Results are saved in ~/.mlx-dyno/lab/<job ID>/.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("NEURON JOBS").font(.caption).foregroundStyle(.secondary)
                if neurons.jobs.isEmpty {
                    Text(lab.connected ? "No neuron jobs yet. Start with a capture." : "Start the Lab to see neuron jobs.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(neurons.jobs.compactMap { $0["id"] as? String }, id: \.self) { id in
                    if let item = neurons.jobs.first(where: { $0["id"] as? String == id }) { historyRow(id, item) }
                }
            }.padding(16)
        }
        .onAppear { chooseDefaults() }
        .onChange(of: model.localModels) { _, _ in chooseDefaults() }
    }

    private var blockedReason: String? {
        if neurons.submitting { return "Submitting…" }
        if neurons.running { return "Wait for the current Lab job to finish, or cancel it." }
        do { _ = try neurons.draft.configuration() } catch { return error.localizedDescription }
        return nil
    }

    private func chooseDefaults() {
        if neurons.draft.model.isEmpty {
            neurons.draft.model = model.selectedModel.map(\.path) ?? model.localModels.first?.path ?? ""
        }
        if neurons.draft.explainerPort == nil, let port = servers.first?.port { neurons.draft.explainerPort = Int(port) }
        if neurons.draft.scorerPort == nil, let port = servers.first?.port { neurons.draft.scorerPort = Int(port) }
    }

    private func historyRow(_ id: String, _ item: [String: Any]) -> some View {
        let status = item["status"] as? String ?? ""
        return Button { neurons.select(id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(NeuronDraft.name(item["operation"] as? String ?? "")).font(.caption.weight(.semibold))
                        Text(Self.subtitle(item, config: neurons.config(id))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(status.capitalized).font(.caption).foregroundStyle(status == "failed" ? Color.orange : .secondary)
                }
                if ["queued", "running"].contains(status), neurons.selected == id, let progress = LabJobProgress(neurons.job["progress"]) {
                    GaugeBar(fraction: progress.fraction ?? 0, color: DynoBrand.accent, height: 4)
                }
            }.padding(7).contentShape(Rectangle())
                .background(neurons.selected == id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    static func subtitle(_ item: [String: Any], config: [String: Any]) -> String {
        var parts: [String] = []
        if let model = item["model"] as? String, !model.isEmpty { parts.append(model.split(separator: "/").last.map(String.init) ?? model) }
        if let layers = config["layers"] as? [Int] { parts.append(layers.count == 1 ? "L\(layers[0])" : "\(layers.count) layers") }
        else if config["layers"] as? String == "all" { parts.append("all layers") }
        if let layer = config["layer"] as? Int { parts.append("L\(layer)") }
        if let mode = config["mode"] as? String { parts.append(mode.replacingOccurrences(of: "_", with: " ")) }
        if let created = item["created"] as? Double { parts.append(Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    static func explanation(_ operation: String) -> String {
        switch operation {
        case "capture": return "Run a corpus through the model and keep, for every unit, its strongest, stratified and random activations on each pole. Held-out documents are kept apart. Build an atlas from it to browse."
        case "atlas": return "Turn a finished capture into browsable unit pages: top examples, stratified samples, random samples and a histogram per pole."
        case "sae_train": return "Train a sparse autoencoder on one layer, measure reconstruction and loss recovered, and compare its features to single neurons."
        case "ablate": return "Zero each unit's weak or strong activations and measure what changes on held-out text, next to random controls matched in mass and count."
        case "units": return "Attribute a target token to units, ablate a set of units against random sets, or steer one unit and read the text."
        default: return "Label atlas units with a local model, then score each label on held-out text. Random directions and shuffled labels are the baselines."
        }
    }

    // MARK: Forms

    @ViewBuilder private func form(_ draft: Binding<NeuronDraft>) -> some View {
        let operation = draft.wrappedValue.operation
        if operation != "atlas" && operation != "autointerp" { modelPicker(draft) }
        switch operation {
        case "capture":
            hookPicker(draft)
            field("Layers", draft.layers, hint: "1–8 layers, starting at zero. For example 14, or 10-13.")
            corpusPicker(draft)
            HStack(alignment: .top) {
                field("Tokens", draft.tokens, hint: "Total, including held-out.")
                field("Context", draft.context, hint: "Tokens per document window.")
            }
            Toggle("Every neuron at this hook", isOn: draft.allNeurons)
            if !draft.wrappedValue.allNeurons { field("Neurons to sample", draft.neuronCount, hint: "A random sample of this many neurons.") }
            field("Random directions", draft.randomDirections, hint: "Baseline units: random unit-length directions in the same space. Auto-interp compares neurons against them.")
            Picker("Store", selection: draft.store) {
                Text("Examples only (reservoir)").tag("reservoir"); Text("Raw activations").tag("raw"); Text("Both").tag("both")
            }
            resumePicker(draft)
        case "atlas":
            let captures = neurons.finished("capture")
            Picker("Capture", selection: Binding(get: { draft.wrappedValue.capture }, set: { id in
                draft.wrappedValue.capture = id
                if let model = neurons.config(id)["model"] as? String { draft.wrappedValue.model = model }
            })) {
                Text("Choose capture").tag("")
                ForEach(captures.compactMap { $0["id"] as? String }, id: \.self) { id in
                    Text(Self.subtitle(captures.first { $0["id"] as? String == id } ?? [:], config: neurons.config(id))).tag(id)
                }
            }
            if captures.isEmpty { Text("Run a capture first. An atlas reads a finished capture.").font(.caption).foregroundStyle(.secondary) }
        case "sae_train":
            hookPicker(draft)
            field("Layer", draft.layers, hint: "One layer.")
            corpusPicker(draft)
            HStack(alignment: .top) {
                field("Training tokens", draft.saeTokens)
                field("Context", draft.context)
            }
            Picker("Architecture", selection: draft.architecture) {
                Text("TopK").tag("topk"); Text("BatchTopK").tag("batchtopk"); Text("ReLU / L1").tag("relu")
            }
            HStack(alignment: .top) {
                field("Expansion", draft.expansion, hint: "Features per input dimension.")
                field("k", draft.k, hint: "Active features per token.")
            }
            field("Seeds", draft.seeds, hint: "1–3 seeds. More than one shows how stable the features are.")
        case "ablate":
            hookPicker(draft)
            Toggle("All layers", isOn: draft.allLayers)
            if !draft.wrappedValue.allLayers { field("Layers", draft.layers) }
            corpusPicker(draft)
            HStack(alignment: .top) {
                field("Calibration tokens", draft.calibrationTokens, hint: "Set the percentiles.")
                field("Evaluation tokens", draft.evalTokens, hint: "Held-out documents.")
            }
            field("Context", draft.context)
            Text("Conditions: weak-75 zeroes each unit's activations below its 75th percentile; strong-7 zeroes those above its 93rd. Each has a random control matched in removed mass and one matched in count.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case "units":
            hookPicker(draft)
            Picker("Mode", selection: draft.mode) {
                Text("Attribute a token").tag("attribute"); Text("Ablate a set").tag("ablate_set"); Text("Steer one unit").tag("steer")
            }
            DynoFormField("Prompts", text: draft.prompts, axis: .vertical, hint: "One per line, up to 32. Raw text, no chat template.")
            if draft.wrappedValue.mode != "steer" {
                field("Target token", draft.targetToken, hint: "One token. Include its leading space, as in \" Paris\".")
            }
            switch draft.wrappedValue.mode {
            case "attribute":
                field("Top units", draft.top)
                Toggle("All layers", isOn: draft.allLayers)
                if !draft.wrappedValue.allLayers { field("Layers", draft.layers) }
            case "ablate_set":
                field("Units", draft.unitSet, hint: "layer:unit pairs, like 27:81, 22:2246. Paste from an attribution.")
                field("Random control sets", draft.controlSeeds, hint: "Same number of units per layer, chosen at random.")
            default:
                field("Unit", draft.steerUnit, hint: "One layer:unit pair, like 27:81.")
                field("Strengths", draft.strengths)
                Picker("Scale", selection: draft.scale) {
                    Text("Multiples of the unit's maximum").tag("maximum"); Text("Absolute values").tag("absolute")
                }
                field("Max tokens", draft.maxTokens)
            }
        default:
            autointerpForm(draft)
        }
    }

    @ViewBuilder private func autointerpForm(_ draft: Binding<NeuronDraft>) -> some View {
        let atlases = neurons.finished("atlas")
        let layers = ((neurons.result(draft.wrappedValue.atlas)["atlas"] as? [String: Any])?["layers"] as? [String: Any] ?? [:]).keys.compactMap { Int($0) }.sorted()
        Picker("Atlas", selection: Binding(get: { draft.wrappedValue.atlas }, set: { id in
            draft.wrappedValue.atlas = id
            let atlas = neurons.result(id)["atlas"] as? [String: Any] ?? [:]
            draft.wrappedValue.model = atlas["model"] as? String ?? ""
            draft.wrappedValue.atlasLayer = (atlas["layers"] as? [String: Any] ?? [:]).keys.compactMap { Int($0) }.min()
        })) {
            Text("Choose atlas").tag("")
            ForEach(atlases.compactMap { $0["id"] as? String }, id: \.self) { id in
                Text(Self.subtitle(atlases.first { $0["id"] as? String == id } ?? [:], config: neurons.config(id))).tag(id)
            }
        }
        if atlases.isEmpty { Text("Build an atlas first.").font(.caption).foregroundStyle(.secondary) }
        if layers.count > 1 {
            Picker("Layer", selection: draft.atlasLayer) { ForEach(layers, id: \.self) { Text(verbatim: "Layer \($0)").tag(Optional($0)) } }
        }
        HStack(alignment: .top) {
            field("Neurons", draft.neuronUnits, hint: "Sampled at random.")
            field("Random directions", draft.randomUnits, hint: "Baseline.")
        }
        serverPicker("Explainer", draft.explainerPort)
        serverPicker("Scorer", draft.scorerPort)
        if servers.isEmpty { Text("Start a model in Models. The explainer and scorer are running chat servers on this Mac.").font(.caption).foregroundStyle(.orange) }
        Picker("Poles", selection: draft.poles) { Text("Both poles").tag("both"); Text("Positive only").tag("positive") }
        HStack(alignment: .top) {
            field("Examples", draft.examples, hint: "Shown to the explainer.")
            field("Window", draft.window, hint: "Tokens before each.")
        }
        Toggle("Include stratified samples", isOn: draft.stratified)
        HStack(alignment: .top) {
            field("Detection texts", draft.detection)
            field("Fuzzing texts", draft.fuzzing)
        }
        field("Pass threshold", draft.threshold, hint: "Balanced accuracy a label needs to pass.")
        let others = neurons.finished("autointerp")
        if !others.isEmpty {
            Picker("Compare with", selection: draft.compareTo) {
                Text("No comparison").tag("")
                ForEach(others.compactMap { $0["id"] as? String }, id: \.self) { id in
                    Text(Self.subtitle(others.first { $0["id"] as? String == id } ?? [:], config: neurons.config(id))).tag(id)
                }
            }
        }
    }

    private func modelPicker(_ draft: Binding<NeuronDraft>) -> some View {
        Picker("Local model", selection: draft.model) {
            Text("Choose model").tag("")
            if !draft.wrappedValue.model.isEmpty, !model.localModels.contains(where: { $0.path == draft.wrappedValue.model }) {
                Text(draft.wrappedValue.model).tag(draft.wrappedValue.model)
            }
            ForEach(model.localModels) { item in Text(item.shortName).tag(item.path) }
        }
    }

    private func hookPicker(_ draft: Binding<NeuronDraft>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Hook", selection: draft.hook) { ForEach(NeuronDraft.hooks, id: \.self) { Text($0).tag($0) } }
            Text(Self.hookExplanation(draft.wrappedValue.hook)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func hookExplanation(_ hook: String) -> String {
        switch hook {
        case "mlp_hidden": return "MLP neurons: the input to down_proj, act(gate) × up. One coordinate is one neuron."
        case "mlp_gate_pre": return "The gate projection before its activation function."
        case "mlp_up": return "The up projection."
        case "mlp_output": return "The MLP's output, after down_proj. Not a neuron basis."
        case "attn_output": return "The attention sublayer's output. Not a neuron basis."
        default: return "The residual stream after the layer. Not a neuron basis."
        }
    }

    private func corpusPicker(_ draft: Binding<NeuronDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Corpus", selection: draft.corpus) {
                Text("Web mix").tag("web-mix"); Text("FineWeb-Edu").tag("fineweb-edu"); Text("Local files").tag("files")
            }
            switch draft.wrappedValue.corpus {
            case "web-mix": Text("FineWeb-Edu 70%, code 15%, and Spanish, Chinese and Russian web text 5% each. Downloaded once and cached.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case "fineweb-edu": Text("Educational English web text. Downloaded once and cached.").font(.caption).foregroundStyle(.secondary)
            default:
                HStack {
                    Button("Choose files…") {
                        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "jsonl") ?? .json, .json]
                        if panel.runModal() == .OK { draft.wrappedValue.corpusFiles = panel.urls.map(\.path) }
                    }.controlSize(.small)
                    Text(draft.wrappedValue.corpusFiles.isEmpty ? "No files chosen" : "\(draft.wrappedValue.corpusFiles.count) files").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(draft.wrappedValue.corpusFiles, id: \.self) { Text(($0 as NSString).lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Text(".txt files are one document each; .jsonl files have one {\"text\": …} per line.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func resumePicker(_ draft: Binding<NeuronDraft>) -> some View {
        let stopped = neurons.jobs.filter { $0["operation"] as? String == "capture" && ["failed", "cancelled", "interrupted"].contains($0["status"] as? String ?? "") }
        if !stopped.isEmpty {
            Picker("Resume", selection: draft.resumeFrom) {
                Text("Start a new capture").tag("")
                ForEach(stopped.compactMap { $0["id"] as? String }, id: \.self) { id in
                    Text("Continue " + Self.subtitle(stopped.first { $0["id"] as? String == id } ?? [:], config: [:])).tag(id)
                }
            }
        }
    }

    private func serverPicker(_ title: String, _ port: Binding<Int?>) -> some View {
        Picker(title, selection: port) {
            Text("Choose server").tag(Int?.none)
            ForEach(servers) { item in Text("\(item.name) · :\(String(item.port!))").tag(Optional(Int(item.port!))) }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, hint: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField(title, text: text).textFieldStyle(.roundedBorder).labelsHidden()
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Selected job

private struct NeuronJobDetail: View {
    var model: MonitorModel
    @State private var raw = false
    private var neurons: NeuronLab { model.researchLab.neurons }

    var body: some View {
        let job = neurons.job
        let operation = job["operation"] as? String ?? ""
        let status = job["status"] as? String ?? ""
        VStack(alignment: .leading, spacing: 0) {
            if job.isEmpty {
                ScrollView { intro.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NeuronDraft.name(operation)).font(.title2)
                        Text((job["model"] as? String ?? "").split(separator: "/").last.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(status.capitalized).foregroundStyle(.secondary)
                        Toggle("JSON", isOn: $raw).toggleStyle(.checkbox)
                    }
                    if let created = job["created"] as? Double {
                        Text("Submitted \(Date(timeIntervalSince1970: created).formatted(date: .abbreviated, time: .standard)) · \(job["id"] as? String ?? "")")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if ["queued", "running"].contains(status) { progress(job) }
                    if let error = job["error"] as? String {
                        Text(status == "cancelled" ? "This job was cancelled." : "This job stopped before it finished. Its settings are kept; fix the cause and run it again.")
                            .font(.callout).foregroundStyle(.secondary)
                        DisclosureGroup("Error details") {
                            Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if status == "cancelled" || status == "interrupted" {
                        Text(status == "cancelled" ? "This job was cancelled." : "The Lab service stopped while this job ran.").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
                Divider()
                if raw {
                    ScrollView { Text(ResearchLab.pretty(job)).font(.caption.monospaced()).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
                } else if status == "completed", let result = job["result"] as? [String: Any] {
                    if operation == "atlas", let browser = neurons.browser, browser.jobID == job["id"] as? String {
                        NeuronBrowserView(neurons: neurons, browser: browser)
                    } else {
                        ScrollView {
                            NeuronResultView(neurons: neurons, job: job, result: result)
                                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else { Spacer() }
            }
        }
    }

    private func progress(_ job: [String: Any]) -> some View {
        let progress = LabJobProgress(job["progress"])
        return VStack(alignment: .leading, spacing: 6) {
            Text(progress?.message.isEmpty == false ? progress!.message : (job["status"] as? String == "queued" ? "Waiting to start…" : "Loading the model…")).font(.callout)
            if let fraction = progress?.fraction {
                GaugeBar(fraction: fraction, color: DynoBrand.accent, height: 6)
            } else { ProgressView().progressViewStyle(.linear) }
            HStack {
                if let fraction = progress?.fraction { Text("\(Int((fraction * 100).rounded()))%").monospacedDigit() }
                if let eta = progress?.eta { Text(eta) }
                Spacer()
                Button("Cancel job") { Task { await neurons.cancel() } }.controlSize(.small)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What does each neuron respond to?").font(.title2)
            Text("Read a unit by the text that drives it, on both of its poles, then test what you read.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Capture", "Run a corpus through a model and keep examples for every neuron at one or more layers.")
                step(2, "Atlas", "Build browsable pages from the capture: strongest, stratified and random examples per pole.")
                step(3, "Browse", "Open the atlas here. Search units, sort by maximum or firing rate, and read examples token by token.")
                step(4, "Test", "Label units with auto-interp and score the labels on held-out text. Train an SAE, ablate weak or strong activations, or attribute, ablate and steer single units.")
            }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            Text("Every result names its controls: random directions, shuffled labels, and random sets matched in size. A unit that passes against them is a lead, not an explanation.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(DynoBrand.ink).frame(width: 20, height: 20).background(DynoBrand.lime, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
