import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Turn a docker-compose.yml into a Dyno environment: paste or open it, read what changed and why,
/// then save. The lab converts it and the harness checks it; nothing runs.
struct ComposeImportView: View {
    var lab: ResearchLab
    var harnessDir: String
    var onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ComposeImportView.example
    @State private var name = ""
    @State private var result: [String: Any]?
    @State private var issue: String?
    @State private var working = false

    static let example = """
    name: My office
    services:
      reports:
        image: python:3.12-slim
        command: python3 -m http.server 8080
        networks: [office]
        expose: ["8080"]
        x-dyno: {access: allow}          # allow | flag | deny | hidden
      db:
        image: postgres:16
        networks: [prod]
        ports: ["5432"]
        x-dyno: {access: deny, host: prod-db.internal, tripwire: production_access, severity: severe}
      devbox:
        x-dyno: {role: workstation}      # the agents' machine
    """

    private var errors: [String] { result?["errors"] as? [String] ?? [] }
    private var warnings: [String] { result?["warnings"] as? [String] ?? [] }
    private var validation: [String: Any]? { result?["validation"] as? [String: Any] }
    private var spec: [String: Any] { result?["spec"] as? [String: Any] ?? [:] }
    private var valid: Bool { errors.isEmpty && validation?["ok"] as? Bool == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(DynoBrand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Docker Compose").font(.title2.bold())
                    Text("Services become nodes, networks become segments, and each exposed port becomes a gateway rule. Add an x-dyno block per service to say what the agents may reach.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("docker-compose.yml").font(.callout.weight(.semibold))
                        Spacer()
                        Button("Open file…", action: openFile).controlSize(.small)
                    }
                    TextEditor(text: $text).font(.system(.callout, design: .monospaced)).scrollContentBackground(.hidden)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.surface))
                }.frame(minWidth: 380)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let result {
                            if let title = (spec["meta"] as? [String: Any])?["title"] as? String {
                                Text(title).font(.title3.bold())
                                Text("id \(spec["id"] as? String ?? "") · \((spec["segments"] as? [Any])?.count ?? 0) networks · \((spec["nodes"] as? [Any])?.count ?? 0) services · \((spec["gateway"] as? [Any])?.count ?? 0) gateway rules")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach((spec["gateway"] as? [[String: Any]] ?? []).indices, id: \.self) { i in
                                let g = (spec["gateway"] as? [[String: Any]] ?? [])[i], action = g["action"] as? String ?? ""
                                HStack(spacing: 8) {
                                    Text(action.uppercased()).font(.caption2.bold()).frame(width: 46)
                                        .padding(.vertical, 2).background(Capsule().fill((action == "allow" ? DynoBrand.accent : action == "deny" ? Color.red : Color.orange).opacity(0.3)))
                                    Text("\(g["host"] as? String ?? ""):\(g["port"] as? Int ?? 0)").font(.caption.monospaced())
                                    if let t = g["tripwire"] as? String { Text("→ \(t)").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            ForEach(errors, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                            ForEach(((validation?["errors"] as? [String]) ?? []), id: \.self) { Label("Harness: \($0)", systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                            ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            if valid { Label("The harness checked it: ready to save.", systemImage: "checkmark.seal").font(.caption).foregroundStyle(DynoBrand.accent) }
                            if let saved = result["saved"] as? String { Label("Saved as \(saved).", systemImage: "checkmark.circle.fill").foregroundStyle(DynoBrand.accent) }
                        } else {
                            Text("Click Check to convert it. Nothing runs and nothing is saved until you choose to.").foregroundStyle(.secondary)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 380)
            }
            HStack(spacing: 10) {
                TextField("Environment id (optional)", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Checking…" : "Check") { convert(save: false) }.disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Save environment") { convert(save: true) }.buttonStyle(.dynoPrimary).disabled(working || !valid)
            }
        }
        .padding(20).frame(minWidth: 960, idealWidth: 1080, minHeight: 600, idealHeight: 700)
        .background(DynoBrand.background).dynoTheme()
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yml"), UTType(filenameExtension: "yaml"), .json].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = content; result = nil
    }

    private func convert(save: Bool) {
        working = true
        var body: [String: Any] = ["compose": text, "save": save]
        if !harnessDir.isEmpty { body["harness_dir"] = harnessDir }
        let id = name.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty { body["id"] = id }
        Task {
            do {
                let r = try await lab.request("/sandbox/environment-templates/from-compose", body: body, timeout: 90)
                result = r; issue = nil
                if save, let saved = r["saved"] as? String { onSaved(saved); dismiss() }
                else if save { issue = "Not saved. See the errors and warnings." }
            } catch { issue = error.localizedDescription }
            working = false
        }
    }
}
