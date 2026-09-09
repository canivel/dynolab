import DynoKit
import Observation
import SwiftUI

@Observable @MainActor
private final class ExecutionMonitor {
    struct Row: Identifiable {
        var source: ExecutionSource
        var trace: ExecutionTrace
        var id: String { "\(source.port):\(trace.id)" }
    }
    var rows: [Row] = []
    var selected: String?
    var detail: ExecutionTrace?
    var unavailable: [String] = []
    var paused = false
    var dropped = 0
    var error: String?
    let client = ExecutionClient()

    func refresh(_ sources: [ExecutionSource]) async {
        let results = await withTaskGroup(of: (ExecutionSource, ExecutionSnapshot?).self) { group in
            for source in sources {
                group.addTask { [client] in (source, try? await client.list(port: source.port)) }
            }
            var results: [(ExecutionSource, ExecutionSnapshot?)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard !Task.isCancelled, !paused else { return }
        unavailable = results.filter { $0.1 == nil }.map { "\($0.0.name) :\($0.0.port)" }.sorted()
        dropped = results.reduce(0) { $0 + ($1.1?.dropped ?? 0) }
        rows = results.flatMap { source, snapshot in
            (snapshot?.executions ?? []).map { Row(source: source, trace: $0) }
        }.sorted { $0.trace.started > $1.trace.started }
        if selected == nil { selected = rows.first?.id }
        await loadSelection()
    }

    func loadSelection() async {
        guard let row = rows.first(where: { $0.id == selected }) else {
            detail = nil
            return
        }
        let selection = selected
        do {
            let result = try await client.detail(port: row.source.port, id: row.trace.id)
            guard !Task.isCancelled, selection == selected else { return }
            detail = result
            error = nil
        } catch {
            guard !Task.isCancelled, selection == selected else { return }
            detail = nil
            self.error = "This execution is no longer available. It may have expired or the endpoint restarted."
        }
    }

    func clear(_ sources: [ExecutionSource]) async {
        var failed = false
        for source in sources {
            do { try await client.clear(port: source.port) } catch { failed = true }
        }
        selected = nil
        detail = nil
        let wasPaused = paused
        paused = false
        await refresh(sources)
        paused = wasPaused
        if failed { error = "Some endpoints could not be cleared. Restart older Dyno servers to enable execution history." }
    }
}

struct ExecutionView: View {
    var model: MonitorModel
    @State private var monitor = ExecutionMonitor()
    @State private var search = ""
    @State private var showInput = true
    @State private var follow = true

    private var sources: [ExecutionSource] {
        var ports: [UInt16: String] = [:]
        for server in model.snapshot.models {
            if let port = server.port { ports[port] = server.name }
        }
        if case let .running(name, port) = model.serverState { ports[port] = name }
        for backend in model.router.backends {
            if let url = URL(string: backend.url),
               ["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""),
               let port = UInt16(exactly: backend.port) { ports[port] = backend.name }
        }
        if model.router.isReachable { ports[model.routerPort] = "Router" }
        return ports.map { ExecutionSource(port: $0.key, name: $0.value) }.sorted { $0.port < $1.port }
    }
    private var rows: [ExecutionMonitor.Row] {
        monitor.rows.filter { search.isEmpty ||
            "\($0.trace.model) \($0.trace.preview) \($0.trace.status) \($0.source.name)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(monitor.paused ? .orange : .green).frame(width: 7, height: 7)
                Text(monitor.paused ? "Execution · paused" : "Live execution").font(.headline)
                Text("\(monitor.rows.filter { $0.trace.isRunning }.count) active")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(monitor.paused ? "Resume" : "Pause") { monitor.paused.toggle() }
                Button("Clear finished") { Task { await monitor.clear(sources) } }
                    .disabled(monitor.rows.isEmpty)
            }.padding(14)
            HStack {
                Text("Inputs and model-emitted thinking, answers and tool calls. Memory only · last 64 requests per endpoint.")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
            if !monitor.unavailable.isEmpty {
                Text("Capture unavailable: \(monitor.unavailable.joined(separator: ", ")). Restart Dyno endpoints after updating; other runtimes are visible through the router.")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if monitor.dropped > 0 {
                Text("\(monitor.dropped) execution traces skipped (cumulative): all 64 history slots per endpoint were marked active. Requests still run; this counter does not mean inference failed.")
                    .font(.caption).foregroundStyle(.orange).padding(.bottom, 6)
            }
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Filter requests", text: $search).textFieldStyle(.roundedBorder).padding(10)
                    List(selection: $monitor.selected) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle().fill(statusColor(row.trace.status)).frame(width: 6, height: 6)
                                    Text(row.trace.model.split(separator: "/").last.map(String.init) ?? row.trace.model)
                                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(Date(timeIntervalSince1970: row.trace.started), style: .time)
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Text(row.trace.preview.isEmpty ? row.trace.endpoint : row.trace.preview)
                                    .font(.system(size: 11)).lineLimit(2).foregroundStyle(.secondary)
                                Text("\(row.source.name) :\(String(row.source.port)) · \(row.trace.status)")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                            }.padding(.vertical, 5).tag(row.id)
                        }
                    }.listStyle(.sidebar)
                }.frame(minWidth: 230, idealWidth: 280, maxWidth: 340)
                if let detail = monitor.detail {
                    traceView(detail).frame(minWidth: 400, maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(monitor.rows.isEmpty ? "Waiting for requests" : "Select an execution").font(.title3)
                        Text(monitor.error ?? (sources.isEmpty
                            ? "Start a model in Models or start the Router, then send a request from Chat or any API client."
                            : "Requests appear here as they arrive, including calls from other devices through the router."))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                }
            }
        }
        .task(id: sources) {
            while !Task.isCancelled {
                if !monitor.paused { await monitor.refresh(sources) }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { break }
            }
        }
        .task(id: monitor.selected) {
            monitor.detail = nil
            await monitor.loadSelection()
        }
    }

    private func traceView(_ trace: ExecutionTrace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trace.model).font(.headline).textSelection(.enabled).lineLimit(2)
                    Text("POST \(trace.endpoint) · \(trace.stream ? "streaming" : "buffered response")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Thinking: \(trace.thinking.map { $0 ? "requested on" : "requested off" } ?? "model default") · \(trace.status)\(trace.finishReason.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(statusColor(trace.status))
                }
                Spacer()
                Button("Send prompt to Lab") {
                    if let input = trace.input?.data(using: .utf8),
                       let body = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
                        let messages = body["messages"] as? [[String: Any]] ?? []
                        model.researchLab.draftPrompt = messages.compactMap { item in
                            guard let text = item["content"] as? String else { return nil }
                            return "\(item["role"] as? String ?? "user"): \(text)"
                        }.joined(separator: "\n")
                        if messages.isEmpty { model.researchLab.draftPrompt = body["prompt"] as? String }
                        model.researchLab.draftModel = trace.model
                        model.requestedTab = .lab
                    }
                }.font(.caption).help("Copy text to a raw-text experiment; this does not replay the chat template")
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption)
            }.padding(16)
            HStack(spacing: 16) {
                let elapsed = (trace.ended ?? Date().timeIntervalSince1970) - trace.started
                Text(String(format: "%.1fs elapsed", elapsed))
                if let tokens = trace.usage?["completion_tokens"] ?? (trace.outputTokens > 0 ? trace.outputTokens : nil) {
                    Text("\(tokens) output tokens")
                }
                if let prompt = trace.usage?["prompt_tokens"] { Text("\(prompt) prompt tokens") }
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        DisclosureGroup("Request input & parameters", isExpanded: $showInput) {
                            code(trace.input ?? "").padding(.top, 8)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        if let parent = trace.parentId, !parent.isEmpty {
                            Text("Router request: \(parent)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        ForEach(trace.events ?? []) { event in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Image(systemName: icon(event.kind))
                                    Text(title(event.kind))
                                    if event.choice != 0 { Text("Choice \(event.choice)") }
                                    Spacer()
                                    Text(String(format: "+%.2fs", event.time - trace.started)).monospacedDigit()
                                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(event.kind == "thinking" ? Color.purple : .secondary)
                                code(event.text)
                            }.padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                        }
                        if !(trace.events ?? []).contains(where: { $0.kind == "thinking" }) {
                            Text(trace.isRunning ? "Thinking will appear if the model emits it." : "No separate thinking text was emitted. Hidden internal reasoning is not available through the API.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if trace.truncated {
                            Text("Capture limit reached (256 Ki characters or 1,024 steps). Inference continued; this trace is incomplete.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(16)
                }
                .onChange(of: trace.events?.last?.updated) { _, _ in
                    if follow { proxy.scrollTo("latest", anchor: .bottom) }
                }
            }
        }
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return .green
        case "failed": return .red
        case "cancelled": return .orange
        default: return .secondary
        }
    }
    private func title(_ kind: String) -> String {
        switch kind {
        case "thinking": return "Thinking · model output"
        case "output": return "Answer"
        case "tool": return "Tool call · emitted data"
        case "routing": return "Routing decision"
        case "candidate": return "Earlier candidate response"
        case "error": return "Error"
        default: return "Generation"
        }
    }
    private func icon(_ kind: String) -> String {
        switch kind {
        case "thinking": return "brain"
        case "output": return "text.alignleft"
        case "tool": return "wrench.and.screwdriver"
        case "error": return "exclamationmark.triangle"
        default: return "arrow.triangle.branch"
        }
    }
}
