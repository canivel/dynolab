import SwiftUI

/// Shares the pool's existing telemetry subscription; changing tabs never starts a process.
struct PerformanceView: View {
    var model: MonitorModel
    var session: PoolSession
    @State private var scope = "Automatic"

    private var poolActive: Bool { session.running && session.starting }
    private var showPool: Bool { scope == "Pool" || (scope == "Automatic" && poolActive) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Performance source", selection: $scope) {
                    Text("Automatic").tag("Automatic")
                    Text("This device").tag("Device")
                    Text("Pool").tag("Pool")
                }.pickerStyle(.segmented).frame(width: 310)
                Spacer()
                Text(showPool ? (poolActive ? "Live pool performance" : "Pool stopped · last session") : "Coordinator performance")
                    .font(.callout).foregroundStyle(.secondary)
                if showPool {
                    Button("Open Pools") { model.requestedTab = .pools }
                }
            }.padding(16)
            Text("Automatic follows a pool started in this app. GPU load and power include other apps; request speed and model allocations come from the pool runtime.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if showPool {
                PoolDashboard(session: session, model: model, performanceOnly: true)
            } else {
                ObservabilityView(model: model)
            }
        }
    }
}
