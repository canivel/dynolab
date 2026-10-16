import AppKit
import DynoKit
import SwiftUI

/// How to run Claude Code or Codex on a local model: the `dyno launch` commands, and the `dyno` command itself.
///
/// Dyno's model server speaks both tools' APIs (Anthropic Messages, OpenAI Responses) and runs their web search with
/// Dyno's own, so the only setup is a terminal command.
struct CodingToolsSection: View {
    var model: MonitorModel

    @State private var chosen: String = ""
    @State private var installed = CodingToolsSection.commandPath() != nil
    @State private var note: String?
    @State private var copied: String?

    /// Where the `dyno` command goes: in macOS's default PATH, so a new Terminal window finds it.
    static let commandFile = "/usr/local/bin/dyno"

    static func commandPath() -> String? {
        FileManager.default.isExecutableFile(atPath: commandFile) ? commandFile : nil
    }

    private var models: [LocalModel] { model.localModels.filter { !$0.isIncomplete } }
    private var modelName: String { chosen.isEmpty ? (model.selectedModel?.name ?? models.first?.name ?? "<model>") : chosen }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeading("Use with Claude Code or Codex", trailing: "on this Mac only")
            Text("Run Claude Code or Codex on a model you've downloaded. Dyno serves it (or uses the one already running), "
                 + "speaks each tool's API, and answers their web searches with Dyno's own web search. Quit the tool and Dyno stops the model it started.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Model").font(.system(size: 11))
                Picker("", selection: Binding(get: { modelName }, set: { chosen = $0 })) {
                    ForEach(models) { m in Text(m.name).tag(m.name) }
                    if models.isEmpty { Text("Download a model in Models").tag("<model>") }
                }
                .labelsHidden().frame(maxWidth: 360)
                Spacer()
            }

            command("dyno launch claude --model \(modelName)", label: "Claude Code")
            command("dyno launch codex --model \(modelName)", label: "Codex")
            command("dyno models", label: "Downloaded models")

            HStack(spacing: 8) {
                if installed {
                    Label("The dyno command is installed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                } else {
                    Button("Install the dyno command…", action: installCommand).controlSize(.small)
                    Text("Adds \(Self.commandFile), so these work in Terminal. macOS asks for your password.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(.orange) }
            Text("Needs Claude Code (npm install -g @anthropic-ai/claude-code) or Codex (npm install -g @openai/codex). "
                 + "Arguments after -- go to the tool. Choose the web search provider in Settings.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func command(_ text: String, label: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).frame(width: 110, alignment: .leading)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            Button(copied == text ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
    }

    /// A two-line script, not a symlink: the bundled launcher finds its runtime relative to its own path.
    private func installCommand() {
        let launcher = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dyno-cli").path
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            note = "This copy of Dyno has no bundled command (\(launcher))."; return
        }
        let script = "#!/bin/sh\nexec '\(launcher.replacingOccurrences(of: "'", with: "'\\''"))' \"$@\"\n"
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("dyno-command-\(UUID().uuidString)")
        do { try script.write(to: staged, atomically: true, encoding: .utf8) } catch { note = error.localizedDescription; return }
        let shell = "mkdir -p /usr/local/bin && install -m 755 '\(staged.path)' '\(Self.commandFile)'"
        let apple = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&error)
        try? FileManager.default.removeItem(at: staged)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            note = error[NSAppleScript.errorMessage] as? String ?? "The command could not be installed."
        }
        installed = Self.commandPath() != nil
        if installed { note = nil }
    }
}
