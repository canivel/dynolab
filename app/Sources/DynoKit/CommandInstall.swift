import Foundation

/// Where the `dyno` Terminal command goes, so it works right after someone installs the app.
///
/// The command is a two-line script that runs the app's bundled `Contents/MacOS/dyno-cli` (not a symlink: the
/// launcher finds its runtime relative to its own path). The app writes it on launch into a folder that is already on
/// the user's PATH and that they can write to, such as Homebrew's `/opt/homebrew/bin`, with no password. A Mac with
/// no such folder needs `/usr/local/bin`, which takes the administrator password, so the app asks once.
public enum CommandInstall {
    public static let name = "dyno"
    public static let systemDirectory = "/usr/local/bin"

    /// Folders the command may go in, best first. `/usr/local/bin` is in macOS's default PATH, for every shell.
    public static func candidates(home: String = NSHomeDirectory()) -> [String] {
        [systemDirectory, "/opt/homebrew/bin", "\(home)/.local/bin", "\(home)/bin"]
    }

    public static func script(launcher: String) -> String {
        "#!/bin/sh\nexec '\(launcher.replacingOccurrences(of: "'", with: "'\\''"))' \"$@\"\n"
    }

    public enum Existing: Equatable {
        /// Dyno's command, running this copy of the app.
        case current
        /// Dyno's command, for a copy of the app that has moved or been replaced.
        case stale
        /// Someone else's `dyno`: never overwritten.
        case foreign
    }

    public static func classify(contents: String?, launcher: String) -> Existing {
        guard let contents else { return .foreign }
        if contents == script(launcher: launcher) { return .current }
        let ours = contents.hasPrefix("#!/bin/sh\nexec '") && contents.contains("/Contents/MacOS/dyno-cli'")
        return ours ? .stale : .foreign
    }

    /// An app run from the disk image or from App Translocation (opened in Downloads without being moved) has a
    /// temporary path; a command pointing there stops working, so wait until it runs from where it's installed.
    public static func isInstalledLocation(_ bundlePath: String) -> Bool {
        !bundlePath.hasPrefix("/Volumes/") && !bundlePath.contains("/AppTranslocation/")
    }

    public struct Plan: Equatable {
        public enum Action: Equatable {
            /// Already there and current.
            case none
            /// Write the script at this path; no password needed.
            case write(String)
            /// Needs the administrator password (into `/usr/local/bin`).
            case needsAdmin
            /// Another program called `dyno` is on the PATH: leave it alone.
            case conflict(String)
        }
        public var action: Action
        /// Where `dyno` is (or will be) installed, if anywhere.
        public var installed: String?

        public init(action: Action, installed: String?) {
            self.action = action
            self.installed = installed
        }
    }

    /// What to do, from the existing `dyno` files, the user's PATH and which folders are writable.
    ///
    /// - Parameters:
    ///   - existing: the `dyno` file in each candidate folder that has one, with its contents (nil if unreadable).
    ///   - path: the folders on the user's login-shell PATH.
    ///   - writable: whether the app can create or replace a file in a folder.
    public static func plan(launcher: String, existing: [String: String?], path: [String], writable: (String) -> Bool,
                            home: String = NSHomeDirectory()) -> Plan {
        let folders = candidates(home: home)
        // The first `dyno` on the PATH is the one Terminal runs.
        let onPath = path.map { ($0 as NSString).standardizingPath }
        for folder in onPath {
            guard let contents = existing[folder] else { continue }
            let file = "\(folder)/\(name)"
            switch classify(contents: contents, launcher: launcher) {
            case .current: return Plan(action: .none, installed: file)
            case .foreign: return Plan(action: .conflict(file), installed: nil)
            case .stale: return Plan(action: writable(folder) ? .write(file) : .needsAdmin, installed: file)
            }
        }
        // Not on the PATH yet: a folder that is, and that the app can write to.
        if let folder = folders.first(where: { onPath.contains($0) && writable($0) }) {
            return Plan(action: .write("\(folder)/\(name)"), installed: nil)
        }
        return Plan(action: .needsAdmin, installed: nil)
    }

    /// The folders on the PATH a new Terminal window gets: the login shell's, which reads `~/.zprofile` (Homebrew) and
    /// `~/.zshrc`. Apps opened from Finder have only the system PATH, so ask the shell.
    public static func loginPath(timeout: TimeInterval = 5) -> [String] {
        let fallback = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n__DYNO_PATH__%s\\n' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return fallback }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return fallback }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__DYNO_PATH__") }) else { return fallback }
        let folders = line.dropFirst("__DYNO_PATH__".count).split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return folders.isEmpty ? fallback : folders
    }

    public static func writable(_ folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: folder)
    }

    public static func existingFiles(home: String = NSHomeDirectory()) -> [String: String?] {
        var found: [String: String?] = [:]
        for folder in candidates(home: home) {
            let file = "\(folder)/\(name)"
            guard FileManager.default.fileExists(atPath: file) else { continue }
            // A big binary isn't ours: don't read it all.
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
            found[folder] = size < 4096 ? (try? String(contentsOfFile: file, encoding: .utf8)) : .some(nil)
        }
        return found
    }

    /// Write the script with no password. Replaces only Dyno's own script.
    public static func write(_ file: String, launcher: String) throws {
        let staged = URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent(".\(name)-\(UUID().uuidString)")
        try script(launcher: launcher).write(to: staged, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if rename(staged.path, file) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
