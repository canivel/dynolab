import SwiftUI

/// An environment drawn as a flowchart: the agents' workstation, the gateway rules it goes
/// through, and the networks with their services. Every part can be clicked to see and change
/// it. Changes are saved as a new environment (or, for one of your own, in place).
struct EnvironmentMapView: View {
    var lab: ResearchLab
    var harnessDir: String
    var environmentID: String
    var onSaved: (String) -> Void

    @State private var original = EnvDraft()
    @State private var d = EnvDraft()
    @State private var editable = false
    @State private var loaded = false
    @State private var selection: Part? = .workstation
    @State private var newName = ""
    @State private var issue: String?
    @State private var saving = false
    @State private var confirming: Bool? = nil   // true: save as new, false: save changes

    enum Part: Hashable { case workstation, rule(UUID), network(UUID), service(UUID) }

    private var changed: Bool { loaded && d != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !loaded {
                HStack { ProgressView().controlSize(.small); Text(issue ?? "Loading the architecture…").font(.caption).foregroundStyle(issue == nil ? Color.secondary : Color.orange) }
            } else {
                ScrollView(.horizontal) { chart.padding(12) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.background))
                inspector.frame(maxWidth: .infinity, alignment: .leading)
                saveBar
            }
        }
        .task(id: environmentID) { await load() }
        .alert(confirming == true ? "Create “\(newName.trimmingCharacters(in: .whitespaces))”?" : "Save changes to “\(original.title.isEmpty ? environmentID : original.title)”?",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirming == true ? "Create" : "Save changes") { let asNew = confirming == true; confirming = nil; save(asNew: asNew) }
            Button("Keep editing", role: .cancel) { confirming = nil }
        } message: {
            Text(confirming == true ? "A new environment with these changes. “\(original.title.isEmpty ? environmentID : original.title)” stays as it is."
                 : "Every test that uses this environment from now on runs with the new version. Past results are kept as they ran.")
        }
    }

    // MARK: Chart

    private var reachable: Set<String> { Set(d.rules.map(\.node).filter { !$0.isEmpty }) }
    private func isolated(_ seg: EnvDraft.Segment) -> Bool {
        !d.nodes.contains { $0.segment == seg.name && reachable.contains($0.name) }
    }

    private var chart: some View {
        HStack(alignment: .top, spacing: 40) {
            column("Agents") {
                box(.workstation, color: DynoBrand.violet) {
                    Label(d.hostname.isEmpty ? "devbox" : d.hostname, systemImage: "desktopcomputer").font(.callout.weight(.semibold))
                    Text("The agents' workstation, on its own access network").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.anchorPreference(key: Frames.self, value: .bounds) { ["ws": $0] }
            }
            column("Gateway: every attempt is logged") {
                if d.rules.isEmpty { Text("No rules: the workstation reaches nothing.").font(.caption).foregroundStyle(.secondary).frame(width: 220) }
                ForEach(d.rules) { r in
                    box(.rule(r.id), color: actionColor(r.action)) {
                        HStack(spacing: 6) {
                            Text(r.action.uppercased()).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(actionColor(r.action).opacity(0.3)))
                            Text("\(r.host.isEmpty ? "host" : r.host):\(r.port)").font(.caption.monospaced()).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        Text(ruleLine(r)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.anchorPreference(key: Frames.self, value: .bounds) { ["rule-\(r.id)": $0] }
                }
            }
            column("Networks") {
                ForEach(d.segments) { seg in
                    let iso = isolated(seg)
                    VStack(alignment: .leading, spacing: 8) {
                        Button { selection = .network(seg.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                Text(seg.name.isEmpty ? "unnamed network" : seg.name).font(.callout.weight(.semibold))
                                if iso { Text("no route from the workstation").font(.caption2).foregroundStyle(.secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        ForEach(d.nodes.filter { $0.segment == seg.name }) { n in
                            box(.service(n.id), color: DynoBrand.accent) {
                                Label(n.name.isEmpty ? "service" : n.name, systemImage: "server.rack").font(.callout.weight(.semibold))
                                Text(serviceLine(n)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.anchorPreference(key: Frames.self, value: .bounds) { ["node-\(n.name)": $0] }
                        }
                        if !d.nodes.contains(where: { $0.segment == seg.name }) { Text("No services yet").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(10).frame(width: 230, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selection == .network(seg.id) ? DynoBrand.accent.opacity(0.08) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selection == .network(seg.id) ? DynoBrand.accent : Color.secondary.opacity(0.4),
                                                                      style: StrokeStyle(lineWidth: 1, dash: iso ? [5, 4] : [])))
                }
                Button { addNetwork() } label: { Label("Add a parallel network", systemImage: "plus") }.controlSize(.small)
            }
        }
        .overlayPreferenceValue(Frames.self) { frames in
            GeometryReader { geo in
                ForEach(links, id: \.self) { link in
                    if let a = frames[link.from], let b = frames[link.to] {
                        let p = geo[a], q = geo[b]
                        Path { path in
                            let start = CGPoint(x: p.maxX, y: p.midY), end = CGPoint(x: q.minX, y: q.midY)
                            path.move(to: start)
                            path.addCurve(to: end, control1: CGPoint(x: start.x + 28, y: start.y), control2: CGPoint(x: end.x - 28, y: end.y))
                        }.stroke(link.color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: link.dashed ? [4, 3] : []))
                    }
                }
            }.allowsHitTesting(false)
        }
    }

    private struct Link: Hashable { var from, to: String; var color: Color; var dashed: Bool }
    private var links: [Link] {
        d.rules.flatMap { r -> [Link] in
            let c = actionColor(r.action)
            var out = [Link(from: "ws", to: "rule-\(r.id)", color: c, dashed: false)]
            // A refused connection never reaches the service: drawn dashed.
            if !r.node.isEmpty { out.append(Link(from: "rule-\(r.id)", to: "node-\(r.node)", color: c, dashed: r.action == "deny")) }
            return out
        }
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
            content()
        }
    }

    private func box<C: View>(_ part: Part, color: Color, @ViewBuilder _ content: () -> C) -> some View {
        let on = selection == part
        return Button { selection = part } label: {
            VStack(alignment: .leading, spacing: 3) { content() }
                .padding(10).frame(width: 190, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? color.opacity(0.18) : DynoBrand.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? color : color.opacity(0.45), lineWidth: on ? 2 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func actionColor(_ a: String) -> Color { a == "allow" ? DynoBrand.accent : a == "deny" ? .red : .orange }
    private func ruleLine(_ r: EnvDraft.Rule) -> String {
        let to = r.node.isEmpty ? "" : " to \(r.node)"
        switch r.action {
        case "deny": return "Refused\(to), recorded as \(r.tripwire.isEmpty ? "?" : r.tripwire) (\(r.severity))"
        case "flag": return "Let through\(to), recorded as \(r.tripwire.isEmpty ? "?" : r.tripwire) (\(r.severity))"
        default: return "Let through\(to)"
        }
    }
    private func serviceLine(_ n: EnvDraft.Node) -> String {
        let kind = ["http-files": "web server", "mock-api": "REST API", "line-service": "TCP service", "object-store": "blob storage",
                    "sql-db": "SQL database", "vault": "secrets vault", "mail-outbox": "email outbox"][n.kind] ?? "custom command"
        let reached = d.rules.filter { $0.node == n.name }.map { $0.action }
        let access = reached.isEmpty ? "not reachable" : reached.contains("allow") || reached.contains("flag") ? "reachable" : "refused"
        return "\(kind) · port \(n.port) · \(access)"
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch selection {
            case .workstation?:
                header("Workstation", "Where the agents work. Every agent in a test shares it.")
                field("Hostname") { TextField("devbox", text: $d.hostname).textFieldStyle(.roundedBorder) }
                Text("It reaches services only through the gateway rules. It never joins a network directly.").font(.caption).foregroundStyle(.secondary)
                Button { addRule(to: nil) } label: { Label("Add a gateway rule", systemImage: "plus") }
            case .rule(let id)?:
                if let i = d.rules.firstIndex(where: { $0.id == id }) {
                    header("Gateway rule", "What happens when the workstation connects to this hostname.")
                    field("Hostname the agents use") { TextField("reports.internal", text: $d.rules[i].host).textFieldStyle(.roundedBorder) }
                    field("Port") { TextField("8080", text: $d.rules[i].port).textFieldStyle(.roundedBorder).frame(width: 90) }
                    field("Goes to service") {
                        Picker("", selection: $d.rules[i].node) { Text("none").tag(""); ForEach(d.nodes.map(\.name).filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                    field("Permission") {
                        Picker("", selection: $d.rules[i].action) { Text("Allow").tag("allow"); Text("Flag").tag("flag"); Text("Deny").tag("deny") }.pickerStyle(.segmented).labelsHidden()
                    }
                    if d.rules[i].action != "allow" {
                        field("Recorded as") { TextField("production_access", text: $d.rules[i].tripwire).textFieldStyle(.roundedBorder) }
                        field("Severity") { Picker("", selection: $d.rules[i].severity) { Text("moderate").tag("moderate"); Text("severe").tag("severe") }.pickerStyle(.segmented).labelsHidden() }
                    }
                    Text(ruleLine(d.rules[i])).font(.caption).foregroundStyle(actionColor(d.rules[i].action))
                    remove("Remove this rule") { d.rules.remove(at: i); selection = .workstation }
                }
            case .network(let id)?:
                if let i = d.segments.firstIndex(where: { $0.id == id }) {
                    header("Network", isolated(d.segments[i]) ? "No gateway rule leads here, so the agents can't reach it." : "A separate internal network. Services on it see each other.")
                    field("Name") { TextField("office", text: renameSegment(i)).textFieldStyle(.roundedBorder) }
                    serviceMenu("Add a service to this network", segment: d.segments[i].name)
                    field("Access from the agents' workstation") {
                        Picker("", selection: Binding(get: { d.access(of: d.segments[i].name) }, set: { d.setAccess($0, of: d.segments[i].name) })) {
                            ForEach(EnvDraft.accessLevels, id: \.id) { Text($0.title).tag($0.id) }
                            if d.access(of: d.segments[i].name) == "custom" { Text("Custom").tag("custom") }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Button { addNetwork() } label: { Label("Add a parallel network", systemImage: "plus") }
                    remove("Remove this network and its services") {
                        let name = d.segments[i].name
                        let gone = Set(d.nodes.filter { $0.segment == name }.map(\.name))
                        d.nodes.removeAll { $0.segment == name }; d.rules.removeAll { gone.contains($0.node) }
                        d.segments.remove(at: i); selection = .workstation
                    }
                }
            case .service(let id)?:
                if let i = d.nodes.firstIndex(where: { $0.id == id }) {
                    header("Service", "A sandboxed container on the \(d.nodes[i].segment) network.")
                    field("Name") { TextField("reports", text: renameService(i)).textFieldStyle(.roundedBorder) }
                    field("Type") {
                        Picker("", selection: $d.nodes[i].kind) { ForEach(EnvDraft.kindNames, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden()
                    }
                    field("Port") { TextField("8080", text: $d.nodes[i].port).textFieldStyle(.roundedBorder).frame(width: 90) }
                    if d.nodes[i].kind == "custom" { field("Command") { TextField("python3 /srv/app.py 8080", text: $d.nodes[i].command, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4) } }
                    if !d.nodes[i].files.isEmpty {
                        field("Files") { ForEach(d.nodes[i].files) { f in Text("\(f.path)  \(f.owner) \(f.mode)").font(.caption.monospaced()).foregroundStyle(.secondary) } }
                    }
                    let access = d.rules.filter { $0.node == d.nodes[i].name }
                    field("How the workstation reaches it") {
                        if access.isEmpty { Text("It doesn't. No gateway rule leads here.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(access) { r in
                            Button { selection = .rule(r.id) } label: { Text("\(r.action) \(r.host):\(r.port)").font(.caption.monospaced()).foregroundStyle(actionColor(r.action)) }.buttonStyle(.link)
                        }
                    }
                    Button { addRule(to: d.nodes[i].name) } label: { Label("Add an access rule for it", systemImage: "plus") }
                    serviceMenu("Add a service next to it", segment: d.nodes[i].segment)
                    Button { addNetwork() } label: { Label("Add a parallel network", systemImage: "plus") }
                    remove("Remove this service") { let name = d.nodes[i].name; d.rules.removeAll { $0.node == name }; d.nodes.remove(at: i); selection = .workstation }
                }
            case nil:
                Text("Click any part of the chart.").foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.surface))
    }

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption.bold()).foregroundStyle(.secondary); content() }
    }
    private func remove(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Label(title, systemImage: "trash") }.buttonStyle(.borderless).foregroundStyle(.red).font(.caption)
    }

    /// Services and rules refer to networks and services by name, so renames carry through.
    private func renameSegment(_ i: Int) -> Binding<String> {
        Binding(get: { d.segments[i].name }, set: { new in
            let old = d.segments[i].name, new = EnvDraft.cleanName(new)
            for j in d.nodes.indices where d.nodes[j].segment == old { d.nodes[j].segment = new }
            d.segments[i].name = new
        })
    }
    private func renameService(_ i: Int) -> Binding<String> {
        Binding(get: { d.nodes[i].name }, set: { new in
            let old = d.nodes[i].name, new = EnvDraft.cleanName(new)
            for j in d.rules.indices where d.rules[j].node == old { d.rules[j].node = new }
            d.nodes[i].name = new
        })
    }

    private func unique(_ base: String, in names: [String]) -> String {
        var n = 2, name = base
        while names.contains(name) { name = "\(base)-\(n)"; n += 1 }
        return name
    }
    private func serviceMenu(_ title: String, segment: String) -> some View {
        Menu {
            ForEach(EnvDraft.serviceTemplates) { t in
                Button { let n = d.addService(t, to: segment); selection = .service(n.id) } label: { Label(t.title, systemImage: t.icon) }
            }
        } label: { Label(title, systemImage: "plus") }.fixedSize()
    }

    private func addService(in segment: String) {
        let name = unique("service", in: d.nodes.map(\.name))
        let node = EnvDraft.Node(name: name, segment: segment, kind: "http-files", port: "8080",
                                 files: [.init(path: "/srv/www/index.html", content: "hello from \(name)\n")])
        d.nodes.append(node)
        d.rules.append(.init(host: "\(name).internal", port: "8080", action: "allow", node: name, tripwire: "", severity: "moderate"))
        selection = .service(node.id)
    }
    private func addNetwork() {
        let seg = EnvDraft.Segment(name: unique("isolated", in: d.segments.map(\.name)))
        d.segments.append(seg)
        let name = unique("service", in: d.nodes.map(\.name))
        d.nodes.append(.init(name: name, segment: seg.name, kind: "http-files", port: "8080", files: [.init(path: "/srv/www/index.html", content: "hello from \(name)\n")]))
        selection = .network(seg.id)
    }
    private func addRule(to node: String?) {
        let host = (node ?? "new") + ".internal"
        let r = EnvDraft.Rule(host: unique(host, in: d.rules.map(\.host)), port: d.nodes.first { $0.name == node }?.port ?? "8080",
                              action: "flag", node: node ?? "", tripwire: "\(node ?? "new")_access", severity: "moderate")
        d.rules.append(r)
        selection = .rule(r.id)
    }

    // MARK: Saving

    private var saveBar: some View {
        HStack(spacing: 10) {
            ForEach(d.warnings().prefix(2), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Spacer()
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).lineLimit(3).frame(maxWidth: 420, alignment: .trailing) }
            if changed {
                Button("Discard changes") { d = original; selection = .workstation }
                TextField("Name for the new environment", text: $newName).textFieldStyle(.roundedBorder).frame(width: 240)
                Button(saving ? "Saving…" : "Save as new environment") { confirming = true }.buttonStyle(.dynoPrimary)
                    .disabled(saving || slug(newName).isEmpty)
                if editable { Button("Save changes") { confirming = false }.disabled(saving) }
            } else {
                Text(editable ? "Click any part to change it." : "Built-in. Click any part to change it; you'll save a copy.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slug(_ s: String) -> String {
        var out = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if let first = out.first, !first.isLetter { out = "env-" + out }
        return String(out.prefix(40))
    }

    private func save(asNew: Bool) {
        saving = true
        Task {
            do {
                var draft = d
                if asNew {
                    draft.id = slug(newName)
                    draft.title = newName.trimmingCharacters(in: .whitespaces)
                    draft.description = "Based on \(original.title.isEmpty ? environmentID : original.title). " + original.description
                }
                let (spec, files) = try draft.payload()
                var body: [String: Any] = ["harness_dir": harnessDir, "spec": spec, "files": files]
                if !asNew { body["replace"] = true }
                _ = try await lab.request("/sandbox/environment-templates", body: body, timeout: 60)
                issue = nil
                onSaved(draft.id)
                if !asNew { original = d }
            } catch { issue = error.localizedDescription }
            saving = false
        }
    }

    private func load() async {
        loaded = false; issue = nil
        var c = URLComponents(); c.queryItems = harnessDir.isEmpty ? [] : [URLQueryItem(name: "harness_dir", value: harnessDir)]
        // Right after launch the lab service may not answer yet; never draw an empty environment instead.
        for attempt in 0..<30 {
            do {
                let detail = try await lab.request("/sandbox/environment-templates/\(environmentID)?\(c.percentEncodedQuery ?? "")", timeout: 30)
                original = EnvDraft(detail: detail, keepID: true); d = original
                editable = detail["editable"] as? Bool == true
                newName = (original.title.isEmpty ? environmentID : original.title) + " copy"
                selection = .workstation; issue = nil; loaded = true
                return
            } catch {
                if Task.isCancelled { return }
                if attempt >= 3 { issue = "Can't load this environment yet: \(error.localizedDescription)" }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct Frames: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}
