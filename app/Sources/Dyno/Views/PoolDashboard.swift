import SwiftUI
import Charts
import DynoKit

struct PoolDashboard: View {
    @Bindable var session: PoolSession
    var model: MonitorModel
    var onPresentation: () -> Void = {}
    var recorded = false
    var performanceOnly = false
    @State var presentation = false
    @State private var diagnostics = false
    private var stats: PoolTelemetry { session.telemetry }
    private var workerDisplay: Bool { recorded ? stats.workerUpdatedAt != nil && stats.workerUtilization != nil : stats.workerFresh }
    private var total: Double { stats.freeMiB.values.reduce(0, +) / 1024 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if recorded { Text("RECORDED SESSION · real inference measurements").font(.caption.bold()).foregroundStyle(.secondary) }
                HStack {
                    Label("COMPUTE POOL", systemImage: "point.3.connected.trianglepath.dotted").font(.caption.bold()).tracking(2).foregroundStyle(.secondary)
                    Spacer()
                    if !performanceOnly { Toggle("Presentation", isOn: $presentation).toggleStyle(.switch).controlSize(.small) }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.modelLabel).font(.title2.bold()).lineLimit(2)
                        Label(stats.active ? "Generating" : stats.phase, systemImage: stats.active ? "waveform" : (stats.ready ? "checkmark.circle.fill" : "circle"))
                            .foregroundStyle(stats.error != nil ? Color.orange : (stats.ready ? Color.green : Color.secondary))
                    }
                    Spacer()
                    if session.running && !performanceOnly { Button("Stop pool", role: .destructive) { session.stop() } }
                }
                if let error = stats.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Pool could not start", systemImage: "exclamationmark.triangle.fill").font(.headline)
                        Text(error).textSelection(.enabled)
                        Text(session.recoveryHelp).font(.callout)
                        if !session.running && !recorded {
                            Button("Check devices again") { session.execute("probe") }.disabled(!session.acknowledged)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("REPORTED GPU HEADROOM").font(.caption.bold()).tracking(1.5)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(stats.freeMiB.isEmpty ? "—" : String(format: "%.1f", total))
                            .font(.system(size: 58, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("GiB").font(.title2).foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(stats.freeMiB.count) GPUs").font(.title2.bold())
                            Text("One model · local network").font(.caption)
                        }
                    }
                    if let measured = stats.measuredAt { Text("Measured at \(measured.formatted(date: .omitted, time: .standard)) · refresh with Test devices when stopped").font(.caption2).foregroundStyle(.secondary) }
                    HStack {
                        ForEach(stats.freeMiB.keys.sorted(), id: \.self) { key in
                            Text("\(key.hasPrefix("RPC") ? "Worker free VRAM" : "Metal budget remaining")  \(String(format: "%.1f", (stats.freeMiB[key] ?? 0) / 1024)) GiB")
                                .font(.callout.weight(.medium))
                            if key != stats.freeMiB.keys.sorted().last { Text("+").foregroundStyle(.secondary) }
                        }
                    }
                    Text(stats.freeMiB.isEmpty ? "Test devices to measure available memory." : "Snapshot before model loading. Metal reports its working-set budget minus this process’s allocations, not system-wide free RAM. Worker VRAM is reported separately. The sum is not reserved capacity or a maximum model size.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            .onChange(of: presentation) { _, value in if value { onPresentation() } }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.cyan.opacity(0.17), .indigo.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .top, spacing: 14) {
                    device(title: "Coordinator", name: model.system.chip, id: "MTL0", local: true)
                    device(title: "Worker", name: workerName, id: "RPC0", local: false)
                }
                HStack(spacing: 16) {
                    metric("Completed requests", "\(stats.completed)")
                    metric("Last generation", stats.rates.last.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    metric("Execution", stats.active ? "Generating" : (stats.ready ? "Idle · ready" : "Offline"))
                }
                if !stats.rates.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Generation speed by completed request").font(.headline)
                        Chart(Array(stats.rates.enumerated()), id: \.offset) { item in
                            BarMark(x: .value("Request", String(item.offset + 1)), y: .value("Tokens/s", item.element)).foregroundStyle(.cyan)
                        }.frame(height: 100)
                    }.padding(16).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let error = stats.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if !presentation {
                    if !performanceOnly {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Run a prompt on this pool").font(.headline)
                            Spacer()
                            if let endpoint = stats.endpoint {
                                Button("Copy API URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(endpoint, forType: .string) }
                            }
                        }
                        Text("Raw text completion · up to 128 output tokens").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $session.prompt).frame(height: 65).padding(6).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button(session.requesting ? "Generating…" : "Generate") { session.generate() }.buttonStyle(.dynoPrimary)
                                .disabled(!stats.ready || session.requesting || session.prompt.isEmpty)
                            if session.requesting { ProgressView().controlSize(.small) }
                        }
                        if !session.response.isEmpty { Text(session.response).textSelection(.enabled).padding(10) }
                        if !session.requestError.isEmpty { Text(session.requestError).foregroundStyle(.orange) }
                    }
                    }
                    DisclosureGroup("Activity · \(stats.events.count) recent events") {
                        ForEach(Array(stats.events.enumerated().reversed()), id: \.offset) { item in
                            Text(item.element).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                        }
                    }
                    DisclosureGroup("Technical diagnostics", isExpanded: $diagnostics) {
                        Text(session.log.isEmpty ? "No diagnostics yet." : session.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } else {
                    Text("DYNO LAB  /  Your AI research, across your devices.").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                }
            }.padding(24)
            .onChange(of: presentation) { _, value in if value { onPresentation() } }
        }
    }
    private var workerName: String {
        let object = (try? JSONSerialization.jsonObject(with: Data(session.config.utf8))) as? [String: Any]
        if let name = stats.workerName { return name }
        return session.nearby.saved.first(where: { $0.peer == object?["peer"] as? String })?.gpu ?? "Remote GPU via verified SSH"
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func device(title: String, name: String, id: String, local: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: local ? "laptopcomputer" : "server.rack").font(.headline)
            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if local {
                Text(String(format: "%.0f%% GPU active time", model.snapshot.gpu.busyPercent)).font(.title3.bold())
                Chart(Array(model.history.gpu.window(60).enumerated()), id: \.offset) { item in
                    AreaMark(x: .value("Sample", item.offset), y: .value("Load", item.element)).foregroundStyle(.cyan.opacity(0.15))
                    LineMark(x: .value("Sample", item.offset), y: .value("Load", item.element)).foregroundStyle(.cyan)
                }.chartYScale(domain: 0...100).chartXAxis(.hidden).frame(height: 70)
                HStack {
                    Text(model.snapshot.gpu.frequencyMHz.map { String(format: "%.0f MHz", $0) } ?? "Clock unavailable")
                    Text("·")
                    Text(model.snapshot.power.gpuWatts.map { String(format: "%.1f W", $0) } ?? "Power unavailable")
                }.font(.caption).foregroundStyle(.secondary)
                Text(recorded ? "Current device-wide sample, not from the recorded run" : "Time outside OFF state · includes the desktop and other apps").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(workerDisplay ? (stats.workerUtilization.map { String(format: "%.0f%% GPU utilization", $0) } ?? "Utilization unavailable") : "Telemetry \(stats.workerStatus == "Live" ? "stale" : stats.workerStatus.lowercased())").font(.title3.bold())
                if workerDisplay && !stats.workerHistory.isEmpty {
                    Chart(Array(stats.workerHistory.enumerated()), id: \.offset) { item in
                        AreaMark(x: .value("Sample", item.offset), y: .value("Load", item.element)).foregroundStyle(.purple.opacity(0.18))
                        LineMark(x: .value("Sample", item.offset), y: .value("Load", item.element)).foregroundStyle(DynoBrand.violet)
                    }.chartYScale(domain: 0...100).chartXAxis(.hidden).frame(height: 70)
                } else {
                    Text(session.running ? "Waiting for worker telemetry. Check that telemetry is enabled in the worker app. Missing samples are not treated as zero load." : "Live monitoring stops when the pool or device check ends. Check devices to refresh; start a model for continuous monitoring.")
                        .font(.caption).foregroundStyle(.secondary).frame(minHeight: 70, alignment: .top)
                }
                if workerDisplay, let used = stats.workerUsedBytes, let total = stats.workerTotalBytes {
                    Text(String(format: "%.1f / %.1f GiB VRAM used", used / GB, total / GB)).font(.caption)
                    ProgressView(value: used, total: total).tint(DynoBrand.violet)
                }
                if workerDisplay {
                    Text([stats.workerTemperature.map { String(format: "%.0f °C", $0) }, stats.workerPower.map { String(format: "%.0f W", $0) }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Text((recorded ? "Recorded · device-wide · verified SSH" : "Live · device-wide · verified SSH") + (stats.workerRPCRunning.map { $0 ? " · RPC running" : " · RPC stopped" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(stats.modelMiB[id].map { String(format: stats.mappedModelDevices.contains(id) ? "%.1f MiB mapped model buffer" : "%.1f MiB model allocation", $0) } ?? "Model allocation not reported yet")
                .font(.caption).foregroundStyle(stats.modelMiB[id] != nil ? Color.primary : Color.secondary)
            Text(stats.mappedModelDevices.contains(id) ? "Mapped address range, not resident RAM. May include gaps; do not add it to worker VRAM usage." : "Last run’s allocation; excludes KV cache and workspace.").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
