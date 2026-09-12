import SwiftUI
import AppKit

struct PoolsView: View {
    @Bindable var session: PoolSession
    var model: MonitorModel
    @State private var showSetup = true
    @State private var showDiscovery = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(showSetup ? "Hide setup" : "Pool setup") { showSetup.toggle() }
                Text("1. Select worker   →   2. Choose model   →   3. Start").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            HSplitView {
            if showSetup { ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Build your GPU pool").font(.title2.bold())
                    Text("Run one model using this computer and a GPU worker on your local network.").foregroundStyle(.secondary)
                    nearbyPanel
                    Divider()
                    Text("2. Choose a model").font(.headline)
                    HStack {
                        Button("Browse model file…") { chooseModel() }

                    }.disabled(session.running || session.nearby.busy)
                    if !model.ggufModels.isEmpty {
                        Menu("Choose downloaded model") {
                            ForEach(model.ggufModels) { item in
                                Button(item.name) { session.selectModel(item.path) }
                            }
                        }.disabled(session.running || session.nearby.busy)
                    }
                    Label(session.modelLabel, systemImage: "cube.box.fill").font(.callout.bold())
                    Text("GGUF is the model file format used by GPU pools. Your selection is saved automatically.").font(.caption).foregroundStyle(.secondary)
                    if !session.selectionNotice.isEmpty { Text(session.selectionNotice).font(.callout).foregroundStyle(Color.green) }
                    DisclosureGroup("Advanced settings") {
                        TextEditor(text: $session.config).font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 250).disabled(session.running || session.nearby.busy)
                        Button("Apply settings") { session.save() }.disabled(session.running)
                    }
                    Text("3. Start the model").font(.headline)
                    Toggle("I trust this worker · experimental GPU pooling", isOn: $session.acknowledged)
                        .font(.caption).disabled(session.running)
                    HStack {
                        Button("Check devices") { session.execute("probe") }.disabled(!session.acknowledged)
                        Button("Start model on pool") { session.execute("start") }.buttonStyle(.dynoPrimary).disabled(!session.acknowledged || !session.setupReady)
                    }.disabled(session.running || session.nearby.busy)
                    if session.running { Button("Stop pool", role: .destructive) { session.stop() } }
                    if !session.setupReady { Text("Select a saved worker and a GGUF model to enable Start.").font(.caption).foregroundStyle(.secondary) }
                    Text("Uses a separate model allocation. Existing MLX weights are not reused. Start does not reserve GPU capacity; use an idle worker and a small test model first.").font(.caption).foregroundStyle(.secondary)
                    Text("Inference stays on the coordinator’s loopback address. Saved workers can be selected individually; multi-worker scheduling is not enabled. Lab activation capture requires the Dyno capture runtime; other Lab methods require research runtime v2.").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.frame(minWidth: 360, idealWidth: 380, maxWidth: 440)
            }
            PoolDashboard(session: session, model: model, onPresentation: { showSetup = false }).frame(minWidth: 540)
            }
        }
        .onChange(of: session.telemetry.ready) { _, ready in if ready { showSetup = false } }
        .task { if session.nearby.networks.isEmpty && !session.running { session.nearby.refresh() } }
        .onChange(of: session.nearby.selectedNetwork) { _, _ in
            session.nearby.nearby = []; session.nearby.selectedWorker = ""
        }
        .onChange(of: session.nearby.pendingConnection) { _, value in
            if let value { session.useConnection(Data(value.utf8)); session.nearby.pendingConnection = nil }
        }
        .sheet(isPresented: Binding(get: { session.nearby.verificationCode != nil }, set: { if !$0 { session.nearby.answer(false) } })) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Verify both devices").font(.title2.bold())
                Text("Does the worker display this exact code? Compare every group, then confirm on both devices.")
                Text(session.nearby.verificationCode ?? "").font(.system(.title3, design: .monospaced).bold())
                    .textSelection(.enabled).padding().background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Discovery labels do not prove identity. Reject this attempt if any group differs.").foregroundStyle(.secondary)
                HStack {
                    Button("Reject", role: .cancel) { session.nearby.answer(false) }
                    Spacer()
                    Button("Every group matches") { session.nearby.answer(true) }.buttonStyle(.dynoPrimary)
                }
            }.padding(24).frame(width: 560).interactiveDismissDisabled()
        }
    }
    private var nearbyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Select a worker").font(.headline)
            DisclosureGroup("Add or re-pair a worker", isExpanded: Binding(get: { showDiscovery || session.nearby.saved.isEmpty }, set: { showDiscovery = $0 })) {
            Text("Open a pairing window in the worker app. Discovery stays on your selected local network.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Local network", selection: $session.nearby.selectedNetwork) {
                Text("Choose network").tag("")
                ForEach(session.nearby.networks) { network in
                    Text("\(network.interface) · \(network.address)").tag(network.address)
                }
            }.disabled(session.running || session.nearby.busy)
            HStack {
                Button("Refresh networks") { session.nearby.refresh() }
                Button("Find workers") { session.nearby.scan() }.disabled(session.nearby.selectedNetwork.isEmpty)
            }.disabled(session.running || session.nearby.busy)
            if !session.nearby.nearby.isEmpty {
                Picker("Worker", selection: $session.nearby.selectedWorker) {
                    ForEach(session.nearby.nearby) { worker in
                        Text("\(worker.name) · \(worker.gpu) · \(worker.address)").tag(worker.id)
                    }
                }.disabled(session.running || session.nearby.busy)
                Button("Pair selected worker") { session.nearby.pairSelected() }
                    .disabled(session.running || session.nearby.busy || session.nearby.selectedWorker.isEmpty)
            }
            HStack {
                if session.nearby.busy { ProgressView().controlSize(.small) }
                Text(session.nearby.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if session.nearby.busy { Button("Cancel discovery / pairing", role: .cancel) { session.nearby.cancel() } }
            }
            if !session.nearby.saved.isEmpty {
                Text("Saved workers · select one for this pool").font(.headline).padding(.top, 4)
                ForEach(session.nearby.saved) { worker in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(worker.name).font(.callout.bold())
                                if session.isSelected(worker) { Label("Selected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.green) }
                            }
                            Text("\(worker.gpu) · \(worker.peer)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(session.isSelected(worker) ? "Selected" : "Select worker") {
                            session.nearby.selectedNetwork = worker.localAddress
                            session.useConnection(worker.connection)
                        }.disabled(session.isSelected(worker) || session.running || session.nearby.busy || !session.nearby.networks.contains(where: { $0.address == worker.localAddress }))
                    }
                }
                Text("Selecting a worker saves it to this pool; it does not start a model. Repeat pairings with the same verified worker appear once.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func chooseModel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose GGUF weights for the coordinator."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.selectModel(url.path)
    }
}
