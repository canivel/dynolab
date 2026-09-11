import SwiftUI

struct PoolsView: View {
    @Bindable var session: PoolSession
    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("LAN pool preview").font(.title2.bold())
                    Text("One GGUF model across this Mac and a trusted GPU worker. Experimental two-machine setup.").foregroundStyle(.secondary)
                    Text("1. Build matching RPC-enabled llama.cpp runtimes.\n2. Start the worker RPC on 127.0.0.1 only.\n3. Set up and verify SSH key login.\n4. Select an active LAN address, then plan and test devices.").font(.callout)
                    Text("Public addresses, VPN routes and workers outside the selected subnet are rejected. SSH carries RPC; no raw RPC listener is opened on the LAN.").font(.caption)
                    TextEditor(text: $session.config).font(.system(.caption, design: .monospaced)).frame(minHeight: 250).disabled(session.running)
                    HStack {
                        Button("List LAN interfaces") { session.execute("interfaces") }
                        Button("Save setup") { session.save() }
                    }.disabled(session.running)
                    Toggle("I trust this worker and accept experimental RPC", isOn: $session.acknowledged).font(.caption).disabled(session.running)
                    HStack {
                        Button("Check plan") { session.execute("plan") }.disabled(session.running)
                        Button("Test devices") { session.execute("probe") }.disabled(session.running || !session.acknowledged)
                        Button("Start pool") { session.execute("start") }.buttonStyle(.borderedProminent).disabled(session.running || !session.acknowledged)
                        Button("Stop", role: .destructive) { session.stop() }.disabled(!session.running)
                    }
                    Text("Uses a separate model allocation. Model file size is not a memory estimate. Existing MLX weights are not reused. Start does not reserve GPU capacity; use an idle worker and a small test model first.").font(.caption).foregroundStyle(.secondary)
                    Text("The endpoint stays on this Mac’s loopback address. Distributed Lab captures, automatic pairing, resource reservations and graceful drain are not available in this preview.").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.frame(minWidth: 400, idealWidth: 440, maxWidth: 540)
            VStack(alignment: .leading, spacing: 12) {
                Text(session.running ? (session.starting ? "Pool process active · see readiness below" : "Checking…") : "Setup and runtime log").font(.headline)
                ScrollView {
                    Text(session.log.isEmpty ? "List LAN interfaces to find this Mac’s address. No worker is connected yet." : session.log)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(minWidth: 300)
        }
    }
}
