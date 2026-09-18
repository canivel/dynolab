import AppKit
import DynoKit
import SwiftUI

/// Reports detected servers separately from device-wide GPU activity.
struct RuntimeOverview: View {
    var model: MonitorModel
    var pool: PoolSession
    @State private var showing = false
    @State private var stopping: LLMModel?
    @State private var stopPool = false
    private var endpoints: [LLMModel] { model.snapshot.models.filter { $0.port != nil } }
    private var hasRuntime: Bool { !endpoints.isEmpty || pool.running }

    var body: some View {
        Button { showing.toggle() } label: {
            Label(model.serverState.isBusy ? "Loading model" : (hasRuntime ? "Runtime active" : "No runtime"), systemImage: hasRuntime ? "server.rack" : "power")
                .font(.system(size: 11, weight: .medium))
        }
        .help("See running models, requests and pool status")
        .popover(isPresented: $showing) { panel }
    }

    var panel: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Research runtimes").font(.title3.bold())
                    Text("Loaded models can hold memory even when no request is running. GPU activity also includes the desktop and other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                    if endpoints.isEmpty && !pool.running {
                        Text("No model endpoint detected. Saved studies remain available; start a model or pool to run new requests.")
                    }
                    switch model.serverState {
                    case .launching(let name):
                        Label("Loading \(name)", systemImage: "hourglass")
                        Button("Cancel model startup", role: .destructive) { model.stopServer() }
                    case .failed(let error):
                        RecoveryNotice(error: error) { navigate(.run) }
                    default: EmptyView()
                    }
                    if let error = model.serverActionError {
                        RecoveryNotice(error: error) { navigate(.run) }
                    }
                    ForEach(endpoints) { endpoint in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(endpoint.name).font(.headline).textSelection(.enabled)
                            Text("\(model.canStopEndpoint(endpoint) ? "Dyno / MLX" : endpoint.runtime) · localhost:\(String(endpoint.port!))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let stats = endpoint.stats {
                                Text(stats.activeRequests == 0 ? "No active requests reported" : "\(stats.activeRequests) active requests")
                            } else {
                                Text("Request activity unavailable").foregroundStyle(.secondary)
                            }
                            if let size = endpoint.sizeGB {
                                Text(String(format: "Reported memory: %.1f GB · process/runtime estimate, not GPU-only", size))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if model.canStopEndpoint(endpoint) {
                                Button("Stop model", role: .destructive) { stopping = endpoint }
                            } else {
                                Text("Manage this endpoint in \(endpoint.runtime) or Pools.").font(.caption)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if pool.running || pool.telemetry.error != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("GPU pool", systemImage: "network").font(.headline)
                            Text(pool.modelLabel)
                            Text(pool.telemetry.phase)
                            if pool.telemetry.workerFresh,
                               let used = pool.telemetry.workerUsedBytes, let total = pool.telemetry.workerTotalBytes {
                                Text(String(format: "Worker GPU: %.1f / %.1f GiB used (device-wide)", used / 1073741824, total / 1073741824)).font(.caption)
                            } else { Text("Worker memory telemetry unavailable").font(.caption).foregroundStyle(.secondary) }
                            if let error = pool.telemetry.error {
                                Text(error).foregroundStyle(.orange).textSelection(.enabled)
                                Text(pool.recoveryHelp).font(.caption)
                            }
                            HStack {
                                Button("Open pool") { navigate(.pools) }
                                if pool.running { Button("Stop pool", role: .destructive) { stopPool = true } }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    HStack {
                        Button("Models") { navigate(.run) }
                        Button("Pools") { navigate(.pools) }
                        Button("Execution log") { navigate(.execution) }
                    }
                }.padding(18)
            }.frame(width: 430).frame(maxHeight: 600)
            .alert("Stop this model?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
                Button("Stop model", role: .destructive) { if let stopping { model.stopEndpoint(stopping) }; stopping = nil }
                Button("Keep running", role: .cancel) { stopping = nil }
            } message: { Text("This interrupts requests using this endpoint. Saved studies and downloaded models are kept.") }
            .alert("Stop the pool?", isPresented: $stopPool) {
                Button("Stop pool", role: .destructive) { pool.stop() }
                Button("Keep running", role: .cancel) { }
            } message: { Text("This interrupts pool requests and unloads its model. Saved studies and model files are kept.") }
    }
    private func navigate(_ tab: MainWindow.Tab) { showing = false; model.requestedTab = tab }
}

struct RecoveryNotice: View {
    let error: String
    var openRuntime: () -> Void
    private var advice: String {
        let text = error.lowercased()
        if text.contains("could not be saved") || text.contains("has not been saved") || text.contains("disk") {
            return "Keep the app open. Check available disk space and folder access, then retry saving."
        }
        if text.contains("timeout") || text.contains("timed out") || text.contains("stopped sending data") {
            return "The endpoint did not respond in time. Check its status and execution log before retrying. A long thinking response may need more time."
        }
        if text.contains("memory") || text.contains("allocation") {
            return "Check runtime memory use. Stop unused models or select a smaller model before retrying."
        }
        if text.contains("connect") || text.contains("offline") || text.contains("refused") {
            return "Check that the selected model or pool is running, then check the connection in Lab."
        }
        return "Review the details below and check the selected runtime. Your saved history remains available."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Could not complete the operation", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
            Text(advice).font(.callout)
            HStack {
                Button("Open Models") { openRuntime() }
                Button("Copy error") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error, forType: .string) }
            }
            DisclosureGroup("Technical details") { Text(error).font(.caption).textSelection(.enabled) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
