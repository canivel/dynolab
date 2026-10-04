import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle validates the release archive before replacing the signed app.
/// Checks may run in the background; installation always requires the user.
@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var startupError: String?
    @Published private(set) var availableVersion: String?
    var stopPool: (() -> Void)?
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            startupError = "Updates are unavailable in this development build. Install a signed release from dynolab.dev."
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        do { try controller.updater.start() }
        catch { startupError = error.localizedDescription }
    }

    func check() { controller?.checkForUpdates(nil) }
    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { availableVersion = nil }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Never infer that a quiet GPU means no research is in progress.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restart Dyno Lab to install the update?"
        alert.informativeText = "Restarting stops Dyno’s model server, router and pool, and interrupts unfinished requests. Saved studies and downloaded models are kept. Finish your work before continuing."
        alert.addButton(withTitle: "Restart and update")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        stopPool?()
        MonitorModel.shared.shutdown()
    }
}

struct UpdateCheckMenuItem: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
        Toggle("Automatically Check for Updates", isOn: Binding(
            get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
            .disabled(updates.startupError != nil)
    }
}

struct AppUpdatesButton: View {
    @ObservedObject private var updates = AppUpdates.shared
    @State private var showing = false
    var body: some View {
        if let version = updates.availableVersion {
            Button { showing.toggle() } label: {
                HStack(spacing: 6) {
                    Label("Update available", systemImage: "arrow.down.circle")
                    Circle().fill(DynoBrand.lime).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .help("Dyno Lab \(version) is available")
            .accessibilityLabel("Update available: Dyno Lab \(version)")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Dyno Lab updates").font(.headline)
                    Text("Version \(version) is available").font(.subheadline.bold())
                    Text("Installed: \(AppIdentity.label)").foregroundStyle(.secondary)
                    if let error = updates.startupError {
                        Text(error).foregroundStyle(.orange)
                    }
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                        .disabled(updates.startupError != nil)
                    Text("Dyno checks for published releases. You choose when to install and restart. Your studies and downloaded models stay on this computer.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Review update…") {
                        showing = false
                        updates.check()
                    }.disabled(!updates.canCheck)
                    Link("Release notes", destination: URL(string: "https://github.com/canivel/dynolab/releases")!)
                }.padding(20).frame(width: 340)
            }
        }
    }
}
