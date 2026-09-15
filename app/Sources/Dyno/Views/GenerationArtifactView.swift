import Charts
import DynoKit
import SwiftUI

struct GenerationArtifactView: View {
    let artifact: LabArtifact
    @State private var phase = "all"
    @State private var selected: Int?
    @State private var showsThinking = true
    private var tokens: [String] { artifact.tokens ?? [] }
    private var phases: [String] { artifact.tokenPhases ?? [] }
    private var layers: [Int] { artifact.layerIndices ?? [] }
    private var values: [[Double]] { artifact.values ?? [] }
    private var visible: [Int] { tokens.indices.filter { phase == "all" || phases[$0] == phase } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generated text and internal measurements").font(.title2.bold())
            Text("\(artifact.captureMode ?? "") · \(artifact.generationStatus ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if let prompt = artifact.prompt {
                GroupBox("Recorded input · exact chat template") {
                    ScrollView {
                        Text(prompt).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 220)
                }
                Text("Scroll the recorded input to inspect every message and template-added instruction.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let thinking = artifact.thinking, !thinking.isEmpty {
                DisclosureGroup("Model-generated thinking", isExpanded: $showsThinking) {
                    ScrollView { Text(thinking).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 220)
                }
                Text("This is reasoning text emitted by the model, not a guaranteed explanation of its computation.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if artifact.generationStatus == "disabled" {
                Text("Thinking was disabled for this run.").foregroundStyle(.secondary)
            }
            GroupBox("Final answer") {
                Text(artifact.answer.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                     ?? "No completed final answer was captured.")
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Divider()
            Text("Measured activation norms").font(.headline)
            Text("Fresh forward-pass measurements. Select a token to inspect its raw block-output norm. Norm size is not confidence, intent, or a safety score.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Token section", selection: $phase) {
                Text("All").tag("all")
                Text("Prompt").tag("prompt")
                Text("Thinking").tag("thinking")
                Text("Answer").tag("answer")
            }.pickerStyle(.segmented)
            if visible.isEmpty { Text("No tokens in this section.").foregroundStyle(.secondary) }
            else {
                Chart {
                    ForEach(layers.indices, id: \.self) { layer in
                        ForEach(visible, id: \.self) { token in
                            LineMark(x: .value("Token", token), y: .value("L2 norm", values[layer][token]))
                                .foregroundStyle(by: .value("Block", "L\(layers[layer])"))
                        }
                    }
                    if let selected { RuleMark(x: .value("Selected token", selected)).foregroundStyle(.secondary) }
                }.frame(height: 190)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(visible, id: \.self) { index in
                            Button { selected = index } label: {
                                VStack(spacing: 4) {
                                    Text(String(index)).font(.caption2)
                                    Text(tokens[index].replacingOccurrences(of: "\n", with: "↵")).font(.caption.monospaced())
                                }.padding(6)
                            }.buttonStyle(.bordered).tint(selected == index ? DynoBrand.violet : .secondary)
                                .help("\(phases[index]) token \(index)")
                        }
                    }
                }
            }
            if let selected, tokens.indices.contains(selected) {
                Text("Token \(selected) · \(phases[selected]): \(tokens[selected].debugDescription)").font(.callout.monospaced())
                ForEach(layers.indices, id: \.self) { layer in
                    Text("Block \(layers[layer]): \(values[layer][selected], specifier: "%.4f")")
                        .font(.caption.monospaced())
                }
            }
        }.onChange(of: phase) { _, _ in selected = nil }
    }
}
