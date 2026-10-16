import AppKit
import DynoKit

/// Sets up the `dyno` Terminal command on launch, so `dyno launch claude --model …` works right after installing.
///
/// No password when a folder on the user's PATH is theirs to write (Homebrew's `/opt/homebrew/bin`, `~/.local/bin`);
/// otherwise the app asks once to put it in `/usr/local/bin`, and Router offers it again. After the app moves or
/// updates, the command is pointed at the new copy.
@MainActor
final class CommandLineSetup: ObservableObject {
    static let shared = CommandLineSetup()

    /// Where `dyno` is installed, when it runs this copy of the app.
    @Published private(set) var installed: String?
    /// Another program called `dyno` is first on the PATH.
    @Published private(set) var conflict: String?
    @Published private(set) var note: String?

    private static let askedKey = "commandLineSetupAsked"
    private var launcher: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dyno-cli").path }
    private var available: Bool {
        FileManager.default.isExecutableFile(atPath: launcher) && CommandInstall.isInstalledLocation(Bundle.main.bundlePath)
    }

    /// Before the launch check finishes, so Router doesn't flash the install button.
    private init() {
        let launcher = launcher
        installed = CommandInstall.existingFiles().first { _, contents in
            CommandInstall.classify(contents: contents, launcher: launcher) == .current
        }.map { "\($0.key)/\(CommandInstall.name)" }
    }

    /// On launch: install or update without a password when possible; ask once when it needs one.
    func start() {
        guard available else { return }
        let launcher = launcher
        Task.detached(priority: .utility) {
            let path = CommandInstall.loginPath()
            var plan = CommandInstall.plan(launcher: launcher, existing: CommandInstall.existingFiles(), path: path,
                                           writable: CommandInstall.writable)
            if case let .write(file) = plan.action {
                if (try? CommandInstall.write(file, launcher: launcher)) != nil { plan = .init(action: .none, installed: file) }
                else { plan.action = .needsAdmin }
            }
            let result = plan
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ plan: CommandInstall.Plan) {
        switch plan.action {
        case .none, .write: installed = plan.installed
        case let .conflict(file): conflict = file
        case .needsAdmin:
            installed = nil
            guard !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            ask(updating: plan.installed != nil)
        }
    }

    private func ask(updating: Bool) {
        let alert = NSAlert()
        alert.messageText = updating ? "Update the dyno command?" : "Install the dyno command?"
        alert.informativeText = "With it you can run Claude Code or Codex on your models from Terminal:\n\n"
            + "dyno launch claude --model <name>\n\nDyno adds \(CommandInstall.systemDirectory)/dyno, so macOS asks "
            + "for your password. You can do this later in Router."
        alert.addButton(withTitle: updating ? "Update" : "Install")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installWithPassword() }
    }

    /// Into `/usr/local/bin`, with the administrator password (macOS's own prompt).
    func installWithPassword() {
        guard available else {
            note = CommandInstall.isInstalledLocation(Bundle.main.bundlePath)
                ? "This copy of Dyno has no bundled command." : "Move Dyno to Applications first, then open it from there."
            return
        }
        let file = "\(CommandInstall.systemDirectory)/\(CommandInstall.name)"
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("dyno-command-\(UUID().uuidString)")
        do { try CommandInstall.script(launcher: launcher).write(to: staged, atomically: true, encoding: .utf8) }
        catch { note = error.localizedDescription; return }
        defer { try? FileManager.default.removeItem(at: staged) }
        let shell = "mkdir -p \(CommandInstall.systemDirectory) && install -m 755 '\(staged.path)' '\(file)'"
        let apple = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {  // -128: the user cancelled
                note = error[NSAppleScript.errorMessage] as? String ?? "The command could not be installed."
            }
            return
        }
        installed = file
        conflict = nil
        note = nil
    }
}
