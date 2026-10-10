import SwiftUI

/// What the prompt editor opens: a saved prompt (or the built-in one, edited as a copy) and the
/// version to start from. `prompt == nil` starts a new prompt.
struct PromptEditRequest: Identifiable {
    let id = UUID()
    var prompt: [String: Any]?
    var version: [String: Any]?
}

/// A Markdown editor for the agents' system prompts: one for the lead, one for agents it creates, and the team
/// instruction that opens the lead's prompt when a test requires a team.
/// Saving never overwrites: it adds a version, and earlier versions stay as they were.
struct PromptEditorView: View {
    var lab: ResearchLab
    var request: PromptEditRequest
    var placeholders: [String: String]
    /// The built-in team instruction, for versions saved before there was one.
    var defaultTeam: String = ""
    var onSaved: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var lead = ""
    @State private var teammate = ""
    @State private var team = ""
    @State private var note = ""
    @State private var part = "lead"
    @State private var showPreview = true
    @State private var base: Int?
    @State private var issue: String?
    @State private var saving = false
    @State private var loaded = false

    private var builtin: Bool { request.prompt?["builtin"] as? Bool == true }
    private var savedID: String? { builtin ? nil : request.prompt?["id"] as? String }
    private var versions: [[String: Any]] { savedID == nil ? [] : (request.prompt?["versions"] as? [[String: Any]] ?? []) }
    private var nextVersion: Int { (versions.last?["version"] as? Int ?? 0) + 1 }
    private var text: Binding<String> { part == "lead" ? $lead : part == "team" ? $team : $teammate }
    private var changed: Bool {
        guard let last = versions.last else { return true }
        return last["lead"] as? String != lead || last["teammate"] as? String != teammate || (last["team"] as? String ?? defaultTeam) != team
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext").font(.title2).foregroundStyle(DynoBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Prompt name", text: $name).textFieldStyle(.plain).font(.title2.bold())
                    Text(savedID == nil ? (builtin ? "A new prompt, starting from the built-in one." : "A new prompt.")
                         : "Saving adds version \(nextVersion). Earlier versions stay as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Preview", isOn: $showPreview).toggleStyle(.switch).controlSize(.small)
            }
            HStack(alignment: .top, spacing: 12) {
                if !versions.isEmpty { history.frame(width: 190) }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $part) {
                        Text("Lead agent").tag("lead"); Text("Agents it creates").tag("teammate"); Text("Team instruction").tag("team")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 460)
                    Text(part == "lead" ? "The system prompt of the agent you set up. Tell it how to plan, delegate and report."
                         : part == "team" ? "Opens the lead's prompt whenever the test's team size is more than 1: build the team of {{team_size}} before any work. Reword it as you like; it can't be empty."
                         : "The system prompt of every agent created during the test. Its creator's instructions come with its first message.")
                        .font(.caption).foregroundStyle(.secondary)
                    HSplitView {
                        CodeEditor(text: text, font: CodeEditor.mono(12)).scrollContentBackground(.hidden)
                            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.background))
                            .frame(minWidth: 320)
                        if showPreview {
                            ScrollView { MarkdownPreview(text: text.wrappedValue).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                                .background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.surface)).frame(minWidth: 280)
                        }
                    }
                    placeholderBar
                }
            }
            HStack(spacing: 10) {
                Label("The goal and the rules are always included: if a prompt leaves out {{goal}} or {{rules}}, Dyno adds them at the end. With a team size above 1, the team instruction always comes first.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                TextField("What changed (optional)", text: $note).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : savedID == nil ? "Save prompt" : "Save as v\(nextVersion)", action: save)
                    .buttonStyle(.dynoPrimary).keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || lead.isEmpty || teammate.isEmpty || team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (savedID != nil && !changed))
            }
        }
        .padding(20).frame(minWidth: 1000, idealWidth: 1180, minHeight: 640, idealHeight: 760)
        .background(DynoBrand.background).dynoTheme()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let v = request.version ?? versions.last
            lead = v?["lead"] as? String ?? ""
            teammate = v?["teammate"] as? String ?? ""
            team = v?["team"] as? String ?? defaultTeam
            base = v?["version"] as? Int
            let current = request.prompt?["name"] as? String ?? ""
            name = savedID != nil ? current : builtin ? "My prompt" : "New prompt"
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Versions").font(.callout.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(versions.reversed().indices, id: \.self) { i in
                        let v = Array(versions.reversed())[i], n = v["version"] as? Int ?? 0
                        Button {
                            lead = v["lead"] as? String ?? ""; teammate = v["teammate"] as? String ?? ""; team = v["team"] as? String ?? defaultTeam; base = n
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("v\(n)").font(.callout.weight(.semibold))
                                    if n == versions.last?["version"] as? Int { Text("latest").font(.caption2).foregroundStyle(DynoBrand.accent) }
                                }
                                if let t = v["created"] as? Double { Text(Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                if let note = v["note"] as? String, !note.isEmpty { Text(note).font(.caption).lineLimit(3) }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 8).fill(base == n ? DynoBrand.accent.opacity(0.14) : Color.clear))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Click a version to start from it. Saving makes a new version; nothing is overwritten.").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.surface))
    }

    private var placeholderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Insert:").font(.caption).foregroundStyle(.secondary)
                ForEach(placeholders.keys.sorted(), id: \.self) { key in
                    Button("{{\(key)}}") { text.wrappedValue += (text.wrappedValue.hasSuffix("\n") || text.wrappedValue.isEmpty ? "" : " ") + "{{\(key)}}" }
                        .font(.caption.monospaced()).controlSize(.small).help(placeholders[key] ?? "")
                }
            }
        }
    }

    private func save() {
        saving = true
        var body: [String: Any] = ["name": name, "lead": lead, "teammate": teammate, "team": team,
                                   "note": note.isEmpty && base != nil && savedID != nil && base != versions.last?["version"] as? Int ? "From v\(base!)" : note]
        if let savedID { body["id"] = savedID }
        Task {
            do {
                let saved = try await lab.request("/sandbox/prompts", body: body, timeout: 30)
                onSaved(saved)
                dismiss()
            } catch { issue = error.localizedDescription }
            saving = false
        }
    }
}

/// Enough Markdown for prompts: headings, bullet and numbered lists, code blocks, and inline
/// bold, italics and code. Placeholders show as they are.
struct MarkdownPreview: View {
    var text: String
    /// Off in lists that keep growing (the assistant's chat): selection there loops layout. Right-click copies instead.
    var selectable = true

    var body: some View {
        let stack = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
        }
        if selectable { stack.textSelection(.enabled) } else { stack }
    }

    private var blocks: [AnyView] {
        var out: [AnyView] = []
        var code: [String]? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code {
                    out.append(AnyView(Text(c.joined(separator: "\n")).font(.caption.monospaced()).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DynoBrand.background))))
                    code = nil
                } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { out.append(AnyView(Spacer().frame(height: 4))); continue }
            if line.hasPrefix("### ") { out.append(AnyView(inline(String(line.dropFirst(4))).font(.callout.bold()))) }
            else if line.hasPrefix("## ") { out.append(AnyView(inline(String(line.dropFirst(3))).font(.headline).padding(.top, 4))) }
            else if line.hasPrefix("# ") { out.append(AnyView(inline(String(line.dropFirst(2))).font(.title3.bold()).padding(.top, 4))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(String(line.dropFirst(2))) }.padding(.leading, 8)))
            } else if let r = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                out.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) { Text(String(line[r]).trimmingCharacters(in: .whitespaces)); inline(String(line[r.upperBound...])) }.padding(.leading, 8)))
            } else { out.append(AnyView(inline(line))) }
        }
        if let c = code { out.append(AnyView(Text(c.joined(separator: "\n")).font(.caption.monospaced()))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: options) { return Text(a) }
        return Text(s)
    }
}
