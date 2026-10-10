import DynoKit
import SwiftUI

/// The app's window. It opens on Agents, the sandboxed agent tests; the research lab,
/// model serving and infrastructure tabs follow.
///
/// The menu bar popover stays the glanceable summary; this is where you
/// actually work — start a model, then see its throughput next to the machine
/// metrics that explain the number.
struct MainWindow: View {
    var model: MonitorModel

    @State private var tab: Tab
    /// Chat is a mode rather than a tab: it is reached from its own button and
    /// leaves the tab you were on selected, so going back lands where you were.
    @State private var showingChat = false
    /// The assistant panel beside every tab: open, or minimized to a rail. Remembered across launches.
    @AppStorage("assistantOpen") private var assistantOpen = true
    @AppStorage("assistantWidth") private var assistantWidth = 400.0
    @State private var dragStart: Double?
    @State private var poolSession = PoolSession()
    @State private var modelFormat = "MLX"

    init(model: MonitorModel, initialTab: Tab = .agents, chat: Bool = false, modelFormat: String = "MLX") {
        self.model = model
        _tab = State(initialValue: initialTab)
        _modelFormat = State(initialValue: modelFormat)
        _showingChat = State(initialValue: chat)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case agents = "Agents"
        case evaluate = "Evals"
        case lab = "Lab"
        case execution = "Execution"
        case run = "Models"
        case discover = "Discover"
        case router = "Router"
        case pools = "Pools"
        case observe = "Performance"
        var id: String { rawValue }
    }



    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { AppIdentity.showAbout() } label: {
                    VStack(spacing: 3) {
                        DynoBrandMark()
                        Text(AppIdentity.label).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary).fixedSize()
                    }
                }.buttonStyle(.plain).padding(.trailing, 8)
                    .accessibilityLabel("About Dyno Lab, \(AppIdentity.label)")
                    .help("About Dyno Lab · \(AppIdentity.label)")
                HStack(spacing: 3) {
                    ForEach(Tab.allCases) { item in
                        Button {
                            tab = item
                            showingChat = false
                        } label: {
                            Text(item.rawValue).font(.system(size: 12, weight: .medium))
                                .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 7)
                                .foregroundStyle(tab == item && !showingChat ? DynoBrand.ink : Color.primary)
                                .background(tab == item && !showingChat ? DynoBrand.lime : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(tab == item && !showingChat ? .isSelected : [])
                    }
                }.padding(4).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 9))
                .frame(width: 790)
                Spacer()
                AppUpdatesButton()
                RuntimeOverview(model: model, pool: poolSession)

                // Chat opens beside this window rather than replacing a tab,
                // so a conversation and the router's decisions can be watched
                // together. Coloured explicitly: .borderedProminent goes grey
                // whenever the window is not key.
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if showingChat { showingChat = false } else { assistantOpen.toggle() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showingChat
                              ? "chevron.left" : "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                        Text(showingChat ? "Back" : "Assistant")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(showingChat ? DynoBrand.accent : DynoBrand.ink)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(showingChat
                                  ? DynoBrand.accent.opacity(0.15) : DynoBrand.lime)
                            .shadow(color: Color.accentColor.opacity(showingChat ? 0 : 0.35),
                                    radius: 5, y: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("j", modifiers: .command)
                .help(showingChat ? "Back to the dashboard" : assistantOpen ? "Minimize the assistant (⌘J)" : "Open the assistant (⌘J)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            HStack(spacing: 0) {
                Group {
                    if showingChat { ChatView(model: model) } else { dashboard }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if assistantOpen {
                    AssistantPanel(model: model, onMinimize: { withAnimation(.easeInOut(duration: 0.12)) { assistantOpen = false } },
                                   onPlainChat: { showingChat = true })
                        .frame(width: assistantWidth)
                        .overlay(alignment: .leading) { resizeHandle }
                } else {
                    AssistantRail(model: model) { withAnimation(.easeInOut(duration: 0.12)) { assistantOpen = true } }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        .background(DynoBrand.background)
        .dynoTheme()
        .onAppear {
            AppUpdates.shared.stopPool = { poolSession.stop() }
            model.currentTab = tab
            // Actions the assistant takes in Dyno (open a screen, fill Agents → Setup) work even while it's minimized.
            model.assistant.onAction = { [model] e in AssistantActions.apply(e, model: model) }
        }
        .onChange(of: tab) { _, t in model.currentTab = t }
        // One view asking to show another — Chat sending you to Models when
        // nothing is loaded — goes through the model rather than reaching into
        // this view's state directly.
        .onChange(of: model.requestedTab) { _, requested in
            if let requested {
                tab = requested
                showingChat = false
                model.requestedTab = nil
            }
        }
        .onChange(of: model.wantsChat) { _, wanted in
            // "Chat" from the menu bar opens the assistant.
            if wanted {
                assistantOpen = true
                model.wantsChat = false
            }
        }
    }

    /// Drag the panel's left edge to make it wider or narrower.
    private var resizeHandle: some View {
        Color.clear.frame(width: 6).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let start = dragStart ?? assistantWidth
                    dragStart = start
                    assistantWidth = min(640, max(320, start - v.translation.width))
                }
                .onEnded { _ in dragStart = nil })
    }

    @ViewBuilder
    private var dashboard: some View {
        Group {
            switch tab {
            case .agents:
                AgentsView(model: model)
            case .evaluate:
                EvalsView(model: model)
            case .lab:
                ResearchLabView(model: model)
            case .execution:
                ExecutionView(model: model)
            case .router:
                RouterView(model: model)
            case .pools:
                PoolsView(session: poolSession, model: model)
            case .observe:
                PerformanceView(model: model, session: poolSession)
            case .run:
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Format", selection: $modelFormat) {
                            Text("MLX").tag("MLX")
                            Text("GGUF").tag("GGUF")
                        }.pickerStyle(.segmented).frame(width: 220)
                        Label(modelFormat == "MLX"
                              ? "MLX · Native Apple Silicon serving and Lab experiments. These model folders cannot be used by the GGUF pool."
                              : "GGUF · For the experimental llama.cpp pool. Select a file/quantization below. GGUF models cannot use Dyno’s MLX serving or Lab capture path.",
                              systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    Divider()
                    if modelFormat == "GGUF" {
                        GGUFModelsView(model: model) { path in
                            poolSession.selectModel(path)
                            tab = .pools
                        }
                    } else {
                        RunningModelsBar(model: model)
                        HStack(spacing: 0) {
                            ModelSidebar(model: model).frame(width: 240)
                            Divider()
                            RunPanel(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            case .discover:
                DiscoverView(model: model, useMLX: { repository in
                    if let local = model.localModels.first(where: { $0.name == repository }) { model.selectedModel = local }
                    modelFormat = "MLX"; tab = .run
                }, useGGUF: { path in
                    poolSession.selectModel(path); tab = .pools
                })
            }
        }
    }
}

// MARK: - Running models

/// Every model server running on this Mac, each with a Stop button, whatever is selected below.
private struct RunningModelsBar: View {
    var model: MonitorModel
    @State private var confirming: LLMModel?

    private var running: [LLMModel] { model.snapshot.models.filter { $0.port != nil } }

    var body: some View {
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUNNING NOW").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(.tertiary)
                ForEach(running, id: \.id) { m in
                    HStack(spacing: 10) {
                        Circle().fill(DynoBrand.accent).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(m.runtime) · 127.0.0.1:\(String(m.port ?? 0))\(model.isDynoEndpoint(m) ? "" : " · started outside Dyno")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.canStopEndpoint(m) || model.isDynoEndpoint(m) {
                            Button("Stop") {
                                if model.isDynoEndpoint(m) { model.stopEndpoint(m) } else { confirming = m }
                            }.accessibilityLabel("Stop \(m.name)")
                        } else {
                            Text("Stop it in \(m.runtime)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.serverActionError { Text(error).foregroundStyle(.orange).font(.caption) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DynoBrand.accent.opacity(0.06))
            .confirmationDialog("Stop \(confirming?.name ?? "this model")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                Button("Stop the server", role: .destructive) { if let m = confirming { model.stopEndpoint(m) }; confirming = nil }
                Button("Cancel", role: .cancel) { confirming = nil }
            } message: {
                Text("This server was started outside Dyno. Anything using it (a room, a script, another app) loses its model, and freeing it may take a few seconds.")
            }
            Divider()
        }
    }
}

// MARK: - Sidebar

private struct ModelSidebar: View {
    var model: MonitorModel
    @State private var deleting: ModelToDelete?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MODELS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                Spacer()
                Button {
                    model.rescanModels()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Rescan for models")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if model.localModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No MLX models found.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Dyno looks in the Hugging Face cache, the LM Studio cache and ~/models.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use Discover to download one.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.localModels) { candidate in
                            ModelRow(
                                candidate: candidate,
                                isSelected: model.selectedModel?.id == candidate.id,
                                isRunning: model.serverState.runningModel == candidate.name
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedModel = candidate }
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)]) }
                                Button("Move to Trash…", role: .destructive) { deleting = ModelToDelete(path: candidate.path, name: candidate.name) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer()
            Divider()
            Button {
                chooseFolder()
            } label: {
                Label("Add folder…", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(14)
        }
        .confirmsModelDeletion(model, item: $deleting)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a folder containing MLX models"
        if panel.runModal() == .OK, let url = panel.url {
            model.addModelFolder(url.path)
        }
    }
}

private struct ModelRow: View {
    var candidate: LocalModel
    var isSelected: Bool
    var isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRunning ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.shortName)
                    .font(.system(size: 12, weight: isRunning ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                Text([candidate.owner, Format.bytes(candidate.sizeBytes)]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
    }
}

// MARK: - Run panel

private struct RunPanel: View {
    var model: MonitorModel
    @State private var showingOptions = false

    private var snapshot: Snapshot { model.snapshot }
    private var served: LLMModel? {
        guard let selected = model.selectedModel else { return nil }
        return snapshot.models.first { $0.identifier == selected.path || $0.identifier == selected.name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                controls
                Text("Thinking applies to the next start and only to compatible chat templates. Off may reduce latency. Chat and API requests can override this default; raw-text Lab captures do not use it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.serverActionError { Text(error).foregroundStyle(.orange).font(.caption) }
                Text("Activation capture is included automatically when you start a model with this version of Dyno. No capture flag is needed. Older running servers need to be stopped and started again.")
                    .font(.caption).foregroundStyle(.secondary)
                if !snapshot.models.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RUNNING ENDPOINTS").font(.caption).foregroundStyle(.secondary)
                        ForEach(snapshot.models) { endpoint in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(endpoint.name).lineLimit(1)
                                    Text(":\(endpoint.port.map(String.init) ?? "—") · \(endpoint.stats?.activeRequests ?? 0) active requests")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.canStopEndpoint(endpoint) {
                                    Button("Stop") { model.stopEndpoint(endpoint) }
                                        .help("Stop this endpoint. Active requests will be interrupted.")
                                } else {
                                    Text("Manage in \(endpoint.runtime)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Stopping an endpoint interrupts its active requests. Start uses the port and launch options below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack {
                    Text("Start on port").font(.caption)
                    TextField("Port", value: Binding(get: { model.launchPort }, set: { model.launchPort = $0 }), format: .number.grouping(.never))
                        .frame(width: 90)
                }
                launchOptions
                if let served, served.stats != nil || served.tokensPerSecond != nil {
                    throughput(served)
                } else {
                    idleHint
                }
                hardware
            }
            .padding(20)
        }
    }

    // -- top row: what is running, and start/stop --------------------------

    private var controls: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Thinking", selection: Binding(get: { model.thinkingMode }, set: { model.thinkingMode = $0 })) {
                Text("Model default").tag("default")
                Text("On").tag("on")
                Text("Off").tag("off")
            }.frame(width: 205)
                .help("Default for the next server start. Requires a compatible model template. Individual chat/API requests can override it; restart for changes to apply.")
            if let served, model.canStopEndpoint(served) {
                Button("Stop") { model.stopEndpoint(served) }.controlSize(.large)
            } else if served != nil {
                Text("Already serving").foregroundStyle(.secondary)
            } else { switch model.serverState {
            case .running:
                Button("Stop") { model.stopServer() }
                    .controlSize(.large)
            case .launching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.stopServer() }
                }
            case .stopped, .failed:
                Button("Start") { model.startSelectedModel() }
                    .controlSize(.large)
                    .buttonStyle(.dynoPrimary)
                    .disabled(model.selectedModel == nil || model.runtime == nil)
            }
            }
        }
    }

    private var headline: String {
        switch model.serverState {
        case let .running(name, _), let .launching(name):
            return name.split(separator: "/").last.map(String.init) ?? name
        default: return model.selectedModel?.shortName ?? "No model selected"
        }
    }

    private var subline: String {
        if let served { return "Serving · port \(served.port.map(String.init) ?? "—")" }
        switch model.serverState {
        case let .running(_, port):
            return "Running · OpenAI API on 127.0.0.1:\(port)"
        case .launching:
            return "Loading into unified memory…"
        case let .failed(message):
            return message
        case .stopped:
            guard model.runtime != nil else { return "No Python runtime found — reinstall Dyno" }
            guard let selected = model.selectedModel else { return "Pick a model on the left" }
            return "\(Format.bytes(selected.sizeBytes)) · ready to start"
        }
    }

    /// Server flags. Collapsed by default — most runs want the defaults, and
    /// changing one of these means restarting the model.
    @ViewBuilder
    private var launchOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showingOptions.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Text("LAUNCH OPTIONS")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.7)
                    Text(model.launchOptions.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)

            if showingOptions {
                let options = Binding(
                    get: { model.launchOptions }, set: { model.launchOptions = $0 }
                )
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        number("Max tokens", options.maxTokens, 128...131_072, 512)
                        number("Prompt cache", options.promptCacheSize, 0...200, 5)
                        number("Decode concurrency", options.decodeConcurrency, 1...16, 1)
                        number("Prompt concurrency", options.promptConcurrency, 1...16, 1)
                    }
                    HStack(spacing: 20) {
                        decimal("Temperature", options.temperature, 0...2)
                        decimal("Top-p", options.topP, 0.05...1)
                        number("Top-k", options.topK, 0...200, 5)
                        Toggle("Trust remote code", isOn: options.trustRemoteCode)
                            .toggleStyle(.switch).controlSize(.mini)
                    }
                    if case .running = model.serverState {
                        Text("Restart the model for changes to take effect.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.035)))
            }
        }
    }

    private func number(
        _ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("\(value.wrappedValue)").monospacedDigit()
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden().controlSize(.mini)
            }
        }
    }

    private func decimal(
        _ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit()
                    .frame(width: 34, alignment: .leading)
                Slider(value: value, in: range).controlSize(.mini).frame(width: 78)
            }
        }
    }

    /// What the empty half of the panel is for, rather than blank space.
    private var idleHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeading("Throughput")
            Text("Start the model to measure it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Dyno reads tokens per second, time to first token, prefill rate and "
                 + "prompt-cache hits from inside the generation loop — not estimated "
                 + "from the outside.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // -- measured throughput ------------------------------------------------

    private func throughput(_ served: LLMModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Throughput", trailing: served.rateSource == .measured
                           ? "measured by the server" : served.rateSource.label)
            HStack(alignment: .top, spacing: 26) {
                BigStat(
                    value: served.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—",
                    unit: "tok/s",
                    caption: served.rateSource == .estimated ? "estimated" : "decode"
                )
                if let stats = served.stats {
                    BigStat(
                        value: stats.timeToFirstToken.map { String(format: "%.2f", $0) } ?? "—",
                        unit: "s", caption: "to first token"
                    )
                    BigStat(
                        value: stats.promptTokensPerSecond.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "tok/s", caption: "prefill"
                    )
                    BigStat(
                        value: stats.cacheHitRate.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "%", caption: "prompt cache"
                    )
                    BigStat(value: "\(stats.activeRequests)", unit: "", caption: "active")
                }
            }
            Sparkline(values: model.history.tokenRate.all, ceiling: nil, color: .accentColor)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    // -- the machine underneath ---------------------------------------------

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Machine", trailing: model.system.chip)
            MeterRow(
                label: "GPU",
                value: String(format: "%.0f%%", snapshot.gpu.busyPercent),
                detail: snapshot.gpu.frequencyMHz.map { String(format: "%.0f MHz", $0) },
                fraction: snapshot.gpu.busyPercent / 100
            )
            MeterRow(
                label: "GPU memory",
                value: Format.bytes(snapshot.memory.gpuUsed),
                detail: "of \(Format.bytes(snapshot.memory.gpuBudget))",
                fraction: (snapshot.memory.gpuUsedPercent ?? 0) / 100
            )
            MeterRow(
                label: "Bandwidth",
                value: snapshot.bandwidth.totalGBps.map { String(format: "%.0f GB/s", $0) } ?? "—",
                detail: model.system.peakBandwidthGBps.map { String(format: "of %.0f", $0) }
                    ?? "peak unknown",
                // Without a published peak for this chip, scale against what
                // this machine has actually reached rather than showing a bar
                // pinned at 100% of itself.
                fraction: (snapshot.bandwidth.totalGBps ?? 0)
                    / (model.system.peakBandwidthGBps
                       ?? max(model.history.bandwidth.peak * 1.25, 64)),
                tint: .blue
            )
            MeterRow(
                label: "Power",
                value: Format.watts(snapshot.power.socWatts),
                detail: snapshot.power.systemWatts.map { String(format: "%.0f W wall", $0) },
                fraction: (snapshot.power.socWatts ?? 0)
                    / max(model.history.gpuPower.peak + 20, 30),
                tint: .purple
            )

            if !snapshot.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                            Text(warning).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Small pieces

private struct BigStat: View {
    var value: String
    var unit: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()
                Text(unit).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

private struct MeterRow: View {
    var label: String
    var value: String
    var detail: String?
    var fraction: Double
    var tint: Color?

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: 82, alignment: .trailing)
            GaugeBar(fraction: fraction, color: tint, height: 7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    .frame(width: 84, alignment: .leading)
            }
        }
    }
}
