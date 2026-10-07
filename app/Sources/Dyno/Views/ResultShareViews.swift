import AppKit
import SwiftUI

/// What a result share sheet packages: one finished test, or the Evals table (one batch or everything).
enum SharedResult {
    case run(room: String)
    case eval(batch: String?)

    var endpoint: String {
        switch self { case .run: "/sandbox/packages/export-run"; case .eval: "/sandbox/packages/export-eval" }
    }
    var suffix: String {
        switch self { case .run: ".dynorun.json"; case .eval: ".dynoeval.json" }
    }
}

/// Share a result: save it as a file, or publish it to Dyno Research as a private draft.
struct ResultShareView: View {
    var lab: ResearchLab
    var result: SharedResult
    var suggestedTitle: String
    @State private var thinking = false

    private var isRun: Bool { if case .run = result { return true } else { return false } }

    var body: some View {
        ShareSheet(kind: isRun ? .run : .evals, suggestedTitle: suggestedTitle, optionsKey: thinking ? "thinking" : "plain",
                   makePackage: makePackage) {
            if isRun { ThinkingOption(on: $thinking) }
        }
    }

    private func makePackage(_ f: ShareFields) async throws -> [String: Any] {
        var body: [String: Any] = ["title": f.title, "description": f.summary, "author": f.author, "license": f.license]
        switch result {
        case .run(let room): body["room"] = room; if thinking { body["thinking"] = true }
        case .eval(let batch): if let batch { body["batch"] = batch }
        }
        return try await lab.request(result.endpoint, body: body, timeout: 120)
    }
}

/// Whether the agents' private reasoning goes with the result.
private struct ThinkingOption: View {
    @Binding var on: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShareSectionTitle("Options")
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include thinking").font(.callout.weight(.semibold))
                    Text("The agents' private reasoning. It shows why they did things, and makes the package larger.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(12).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
