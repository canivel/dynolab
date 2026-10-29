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
    @State private var copied: String?
    @ObservedObject private var setup = CommandLineSetup.shared

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
            command("dyno launch claude --model \(modelName) -- --dangerously-skip-permissions", label: "No permission prompts",
                    help: "Claude Code runs every command and edit without asking. Use it in a worktree or a throwaway copy: a local model makes more mistakes than Claude.")
            command("dyno launch codex --model \(modelName)", label: "Codex")
            command("dyno models", label: "Downloaded models")

            HStack(spacing: 8) {
                if let installed = setup.installed {
                    Label("The dyno command is installed (\(installed))", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                } else {
                    Button("Install the dyno command…") { setup.installWithPassword() }.controlSize(.small)
                    Text(setup.conflict.map { "Another program is installed as \($0). Dyno adds \(CommandInstall.systemDirectory)/dyno; macOS asks for your password." }
                         ?? "Adds \(CommandInstall.systemDirectory)/dyno, so these work in Terminal. macOS asks for your password.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if let note = setup.note { Text(note).font(.system(size: 10)).foregroundStyle(.orange) }
            Text("Needs Claude Code (npm install -g @anthropic-ai/claude-code) or Codex (npm install -g @openai/codex). "
                 + "Arguments after -- go to the tool. Choose the web search provider in Settings. "
                 + "Claude Code's auto mode needs a Claude model: on a local model it isn't offered, or it blocks every action it checks.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func command(_ text: String, label: String, help: String? = nil) -> some View {
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
        .help(help ?? "")
    }
}
