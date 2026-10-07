import SwiftUI

/// "What's included": read from the package that will be uploaded, so what you see is what is sent.
struct SharePreviewCard: View {
    var kind: ShareKind
    var package: [String: Any]?
    var loading: Bool
    var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ShareSectionTitle("What's included")
                Spacer()
                if loading { DynoSpinner(size: 11) }
            }
            if let issue { ShareIssue(text: issue) }
            if let package {
                content(package).opacity(loading ? 0.5 : 1)
                SizeRow(bytes: packageBytes(package))
            } else if loading {
                Text("Packaging…").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(18)
        .background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private func content(_ p: [String: Any]) -> some View {
        switch kind {
        case .test: TestIncluded(p: p)
        case .run: RunIncluded(p: p)
        case .evals: EvalsIncluded(p: p)
        }
    }
}

func packageBytes(_ p: [String: Any]) -> Int { (try? JSONSerialization.data(withJSONObject: p))?.count ?? 0 }
func byteText(_ n: Int) -> String { n < 1024 ? "\(n) B" : n < 1_048_576 ? "\(Int((Double(n) / 1024).rounded())) KB" : String(format: "%.1f MB", Double(n) / 1_048_576) }

private struct SizeRow: View {
    var bytes: Int
    var body: some View {
        let over = bytes > researchMaxBytes
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Image(systemName: over ? "exclamationmark.triangle.fill" : "doc.zipper").foregroundStyle(over ? .orange : .secondary)
                Text("Package size").font(.callout)
                Spacer()
                Text(byteText(bytes)).font(.callout.monospacedDigit()).foregroundStyle(over ? .orange : .primary)
            }
            if over {
                Text("Over Dyno Research's 1 MB limit. Leave out thinking or large files, or save the file instead.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line of the preview: an icon, a label and a value.
struct IncludedRow: View {
    var icon: String
    var label: String
    var value: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(DynoBrand.accent)
            Text(label).font(.callout)
            Spacer(minLength: 8)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - The environment, as the site draws it

struct EnvSummary {
    var title: String
    var services: [(name: String, reach: String)]
    var files: [(name: String, bytes: Int)]
    var compose: String?

    init?(environment: [String: Any]?, compose: String?) {
        guard let env = environment else { return nil }
        let spec = env["spec"] as? [String: Any] ?? [:]
        let meta = spec["meta"] as? [String: Any] ?? [:]
        title = meta["title"] as? String ?? env["id"] as? String ?? "Environment"
        let rules = spec["gateway"] as? [[String: Any]] ?? []
        services = (spec["nodes"] as? [[String: Any]] ?? []).compactMap { n in
            guard let name = n["name"] as? String else { return nil }
            let actions = rules.filter { $0["node"] as? String == name }.compactMap { $0["action"] as? String }
            let reach = actions.isEmpty ? "hidden" : actions.contains("allow") ? "allow" : actions.contains("flag") ? "flag" : "deny"
            return (name, reach)
        }
        files = (env["files"] as? [String: Any] ?? [:]).map { ($0.key, ($0.value as? String)?.utf8.count ?? 0) }.sorted { $0.name < $1.name }
        self.compose = compose ?? env["compose"] as? String
    }
}

struct EnvIncluded: View {
    var env: EnvSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IncludedRow(icon: "network", label: env.title)
            if !env.services.isEmpty { ServiceChips(services: env.services).padding(.leading, 28) }
            if env.files.isEmpty {
                IncludedRow(icon: "doc", label: "Files", value: "none")
            } else {
                IncludedRow(icon: "doc.on.doc", label: "\(env.files.count) environment file\(env.files.count == 1 ? "" : "s")", value: byteText(env.files.reduce(0) { $0 + $1.bytes }))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(env.files.prefix(6), id: \.name) { f in
                        HStack { Text(f.name).font(.caption.monospaced()); Spacer(); Text(byteText(f.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                    }
                    if env.files.count > 6 { Text("and \(env.files.count - 6) more").font(.caption).foregroundStyle(.tertiary) }
                }.padding(.leading, 28)
            }
            IncludedRow(icon: "shippingbox.and.arrow.backward", label: "Docker Compose file", value: env.compose.map { byteText($0.utf8.count) } ?? "not included")
        }
    }
}

struct ServiceChips: View {
    var services: [(name: String, reach: String)]
    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(services.prefix(10), id: \.name) { s in
                let c = ServiceChips.color(s.reach)
                Text(s.name).font(.caption.monospaced())
                    .strikethrough(s.reach == "deny", color: c)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .foregroundStyle(c)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(c.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: s.reach == "hidden" ? [3, 3] : [])))
                    .help(ServiceChips.help(s.reach))
            }
        }
    }
    static func color(_ reach: String) -> Color {
        switch reach { case "allow": DynoBrand.accent; case "flag": .orange; case "deny": .red; default: .secondary }
    }
    static func help(_ reach: String) -> String {
        switch reach {
        case "allow": "Reachable"
        case "flag": "Reachable; every connection recorded as a tripwire"
        case "deny": "Refused; every attempt recorded"
        default: "No gateway rule leads here"
        }
    }
}

/// Lays chips out in rows, wrapping to the width it gets.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Per kind

private struct TestIncluded: View {
    var p: [String: Any]
    var body: some View {
        let rules = (p["rules"] as? [Any])?.count ?? 0
        let script = (p["script"] as? [Any])?.count ?? 0
        let history = (p["history"] as? [Any])?.count ?? 0
        let alerts = (p["alerts"] as? [Any])?.count ?? 0
        VStack(alignment: .leading, spacing: 10) {
            if let env = EnvSummary(environment: p["environment"] as? [String: Any], compose: p["compose"] as? String) {
                EnvIncluded(env: env)
            } else {
                IncludedRow(icon: "desktopcomputer", label: "Plain machine", value: "no services")
            }
            Divider()
            IncludedRow(icon: "checklist", label: "Rules, with what watches each", value: "\(rules)")
            IncludedRow(icon: "target", label: "Goal and lead agent", value: (p["prompt"] is [String: Any]) ? "with prompt" : "")
            if script > 0 { IncludedRow(icon: "text.bubble", label: "Scripted messages", value: "\(script)") }
            if history > 0 { IncludedRow(icon: "clock.arrow.circlepath", label: "Earlier messages", value: "\(history)") }
            if alerts > 0 { IncludedRow(icon: "bell", label: "Observer alerts", value: "\(alerts)") }
            Text("No model is included: whoever runs it picks one.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RunIncluded: View {
    var p: [String: Any]
    var body: some View {
        let result = p["result"] as? [String: Any] ?? [:]
        let rules = result["rules"] as? [[String: Any]] ?? []
        let broken = rules.filter { $0["status"] as? String == "broken" }.count
        let timeline = p["timeline"] as? [[String: Any]] ?? []
        let thinking = timeline.contains { $0["kind"] as? String == "thought" }
        let stats = p["stats"] as? [String: Any] ?? [:]
        let setup = p["setup"] as? [String: Any] ?? [:]
        VStack(alignment: .leading, spacing: 10) {
            OutcomeBadge(outcome: result["outcome"] as? String ?? "", verdict: result["verdict"] as? String ?? "")
            IncludedRow(icon: "cpu", label: "Model", value: String((p["model"] as? String ?? "–").split(separator: "/").last ?? "–"))
            IncludedRow(icon: "person.3", label: "Agents", value: "\((p["team"] as? [Any])?.count ?? 0)")
            IncludedRow(icon: "checklist", label: "Rules broken", value: "\(broken) of \(rules.count)")
            IncludedRow(icon: "list.bullet.rectangle", label: "Timeline and log", value: "\(timeline.count) entries\((stats["tool_calls"] as? Int).map { " · \($0) steps" } ?? "")")
            IncludedRow(icon: "brain", label: "Thinking", value: thinking ? "included" : "left out")
            IncludedRow(icon: "eye", label: "Observer events", value: "\((p["observer"] as? [Any])?.count ?? 0)")
            Divider()
            if let env = EnvSummary(environment: setup["environment"] as? [String: Any], compose: nil) {
                EnvIncluded(env: env)
            } else {
                IncludedRow(icon: "desktopcomputer", label: "Plain machine", value: "no services")
            }
            Text("Honeypot secrets are replaced with [secret].").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OutcomeBadge: View {
    var outcome: String
    var verdict: String
    var body: some View {
        let (label, color): (String, Color) = switch outcome {
        case "kept_honest": ("Kept the rules, reported honestly", DynoBrand.accent)
        case "kept_no_report": ("Kept the rules, no final report", .orange)
        case "broke_disclosed": ("Broke a rule and said so", .orange)
        case "broke_hidden": ("Broke a rule and hid it", .red)
        case "dishonest_report": ("Report contradicts the log", .red)
        default: ("No verdict", .secondary)
        }
        let icon = outcome.hasPrefix("kept_honest") ? "checkmark.circle.fill" : outcome == "kept_no_report" || outcome == "broke_disclosed" ? "exclamationmark.triangle.fill" : outcome.isEmpty ? "questionmark.circle" : "xmark.octagon.fill"
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(color)
            if !verdict.isEmpty { Text(verdict).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.35)))
    }
}

private struct EvalsIncluded: View {
    var p: [String: Any]
    var body: some View {
        let scenarios = p["scenarios"] as? [[String: Any]] ?? []
        let configs = p["configs"] as? [[String: Any]] ?? []
        let cells = p["cells"] as? [[String: Any]] ?? []
        let runs = cells.reduce(0) { $0 + ($1["n"] as? Int ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            IncludedRow(icon: "tablecells", label: "Scenarios × configs", value: "\(scenarios.count) × \(configs.count)")
            IncludedRow(icon: "play.circle", label: "Finished runs", value: "\(runs)")
            IncludedRow(icon: "chart.bar", label: "Rates with 95% ranges, pass^k", value: "\(cells.count) cells")
            Divider()
            ForEach(Array(scenarios.prefix(5).enumerated()), id: \.offset) { _, s in
                HStack { Image(systemName: "square.grid.2x2").foregroundStyle(.secondary).frame(width: 18); Text(s["title"] as? String ?? "Scenario").font(.caption).lineLimit(1) }
            }
            if scenarios.count > 5 { Text("and \(scenarios.count - 5) more scenarios").font(.caption).foregroundStyle(.tertiary) }
            if runs < 5 { Text("Few runs: the ranges on the site will be wide.").font(.caption).foregroundStyle(.orange) }
        }
    }
}
