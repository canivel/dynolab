import SwiftUI

/// Presents saved descriptive counts without treating ungraded responses as failures.
struct StudyResultsOverview: View {
    let summary: [String: Any]
    var review: () -> Void
    private var rows: [[String: Any]] { (summary["rows"] as? [[String: Any]] ?? []).filter { count($0, "completed") + count($0, "invalid_attempts") > 0 } }
    private func count(_ row: [String: Any], _ key: String) -> Int { row[key] as? Int ?? 0 }
    private var completed: Int { rows.reduce(0) { $0 + count($1, "completed") } }
    private var resolved: Int { rows.reduce(0) { $0 + count($1, "passed") + count($1, "failed") } }
    private let outcomes: [(String, String, Color)] = [
        ("passed", "Pass", .green), ("failed", "Fail", .red),
        ("ungraded", "Unresolved", .gray), ("disagreement", "Disputed", .orange)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Results overview", systemImage: "chart.bar.xaxis").font(.title2.bold())
                Spacer()
                Text("DESCRIPTIVE RESULTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(completed == 0 ? "Run the comparison to see results" : resolved == completed ? "All completed responses have a clear grade" : "Review the answers before drawing conclusions")
                            .font(.headline)
                        Text(completed == 0 ? "Results appear here as requests finish." : "\(resolved) of \(completed) responses graded Pass or Fail")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if completed > resolved {
                        Button("Review responses", action: review).buttonStyle(.dynoPrimary)
                    }
                }
                if completed > 0 {
                    ProgressView(value: Double(resolved), total: Double(completed)).tint(DynoBrand.lime)
                    Text("Unresolved includes responses not yet graded and those marked Uncertain. Disputed means reviewers disagree.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 14))

            ForEach(["development", "test"], id: \.self) { split in
                let group = rows.filter { $0["split"] as? String == split }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(split == "development" ? "Development cases" : "Held-out test cases").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 16) {
                            ForEach(Array(group.enumerated()), id: \.offset) { _, row in conditionCard(row) }
                        }
                    }
                }
            }
            if !(rows.contains { $0["split"] as? String == "test" }) {
                Label("No held-out test results in this comparison.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("How to interpret these results") {
                Text(summary["interpretation"] as? String ?? "")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.subheadline)
        }.padding(.vertical, 12)
    }

    private func conditionCard(_ row: [String: Any]) -> some View {
        let name = row["condition"] as? String ?? "Condition"
        let total = count(row, "completed")
        let accent = name == "baseline" ? DynoBrand.lime : Color.purple
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: name == "baseline" ? "a.circle.fill" : "b.circle.fill").foregroundStyle(accent)
                Text(name.capitalized).font(.headline)
                Spacer()
                Text("\(total) responses").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(outcomes, id: \.0) { key, _, color in
                        if count(row, key) > 0 {
                            Rectangle().fill(color.opacity(0.8))
                                .frame(width: geometry.size.width * Double(count(row, key)) / Double(max(1, total)))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
            }.frame(height: 12).accessibilityLabel("Outcome distribution for \(name)")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                ForEach(outcomes, id: \.0) { key, label, color in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(count(row, key))).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Label(label, systemImage: "circle.fill").font(.caption).foregroundStyle(color)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if count(row, "invalid_attempts") > 0 {
                Label("\(count(row, "invalid_attempts")) incomplete or failed attempts · excluded above", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(20).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.25)))
    }
}
