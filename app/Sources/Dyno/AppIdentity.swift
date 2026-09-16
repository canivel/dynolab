import AppKit

/// Read the running bundle, never a repository or a different installed app.
enum AppIdentity {
    static var version: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static var label: String { version.map { "v\($0)" } ?? "Unversioned build" }

    @MainActor static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Dyno Lab",
            .applicationVersion: version ?? "Unversioned development build",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: NSAttributedString(string: "AI safety, alignment and interpretability research.\nhttps://dynolab.dev")
        ])
    }
}
