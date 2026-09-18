import SwiftUI

struct AppSettingsView: View {
    @ObservedObject private var updates = AppUpdates.shared

    var body: some View {
        Form {
            Section("Dyno Lab") {
                LabeledContent("Installed version", value: AppIdentity.label)
                Link("User guide", destination: URL(string: "https://dynolab.dev/guide.html")!)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticChecks },
                    set: { updates.setAutomaticChecks($0) }))
                    .disabled(updates.startupError != nil)
                Text("Checks for new stable releases in the background. You choose when to install and restart.")
                    .font(.callout).foregroundStyle(.secondary)
                if let version = updates.availableVersion {
                    Label("Version \(version) is available", systemImage: "arrow.down.circle")
                }
                if let error = updates.startupError {
                    Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Check for Updates…") { updates.check() }
                        .disabled(!updates.canCheck)
                    Link("Release notes", destination: URL(string: "https://github.com/canivel/dynolab/releases")!)
                }
                Text("The toolbar update button appears only when a new version has been found.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model and research settings") {
                Text("Choose model startup options in Models and pool configuration in Pools. Each study saves its own prompt and generation settings.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Models") { open(.run) }
                    Button("Open Pools") { open(.pools) }
                    Button("Open Lab") { open(.lab) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 510, height: 510)
    }

    private func open(_ tab: MainWindow.Tab) {
        MonitorModel.shared.requestedTab = tab
        AppDelegate.shared?.showMainWindow()
    }
}
