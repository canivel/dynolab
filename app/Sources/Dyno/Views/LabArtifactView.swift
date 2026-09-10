import AppKit
import Charts
import DynoKit
import SwiftUI
import UniformTypeIdentifiers

struct LabArtifactView: View {
    @State private var artifact: LabArtifact?
    @State private var error: String?
    @State private var search = ""
    @State private var atlasModel = "gpt2-small"
    @State private var atlasSource = "0-res-jb"
    @State private var atlasFeature = "0"
    @State private var fetching = false
    @State private var selectedNode: String?
    @State private var history: [[String: Any]] = []
    private let archive = ResearchArchive()
    init(initialArtifact: LabArtifact? = nil) { _artifact = State(initialValue: initialArtifact) }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Research artifacts").font(.title2.bold())
                Text("Explore attention, feature examples and attribution graphs exported from your research tools.").foregroundStyle(.secondary)
                Button("Import artifact JSON") { importArtifact() }.buttonStyle(.borderedProminent)
                Link("Neuronpedia feature atlas ↗", destination: URL(string: "https://www.neuronpedia.org/")!)
                Text("Neuronpedia opens in your browser. Imported descriptions are source annotations, not locally verified explanations. No prompts are uploaded by this viewer.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Fetch a public Neuronpedia feature") {
                    TextField("Model ID", text: $atlasModel)
                    TextField("Source ID", text: $atlasSource)
                    TextField("Feature index", text: $atlasFeature)
                    Text("Sends these public identifiers to neuronpedia.org. Results are saved locally; no local prompts or model data are sent.").font(.caption)
                    Button(fetching ? "Fetching…" : "Fetch feature") { Task { await fetchFeature() } }.disabled(fetching)
                }
                TextField("Search feature labels", text: $search).textFieldStyle(.roundedBorder)
                Divider()
                Text("SAVED ARTIFACTS").font(.caption)
                List(history.indices, id: \.self) { i in
                    Button(history[i]["title"] as? String ?? "Artifact") {
                        do {
                            let data = try JSONSerialization.data(withJSONObject: history[i]["artifact"] ?? [:])
                            artifact = try LabArtifact.read(data); selectedNode = nil
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.plain)
                }
            }.padding().frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error { Text(error).foregroundStyle(.red) }
                    if let a = artifact {
                        Text(a.model).font(.title2.bold())
                        Text("Source: \(a.source) · \(a.kind)").font(.caption).foregroundStyle(.secondary)
                        Text(a.note).font(.callout)
                        if let values = a.values, let tokens = a.tokens, a.kind == "attention" {
                            Text("Attention · query row × key column").font(.headline)
                            Chart(values.indices, id: \.self) { q in
                                ForEach(values[q].indices, id: \.self) { k in
                                    RectangleMark(x: .value("Key token", k), y: .value("Query token", q))
                                        .foregroundStyle(by: .value("Attention", values[q][k]))
                                }
                            }.chartForegroundStyleScale(domain: 0...1).frame(height: 380)
                            Text(tokens.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: " · ")).font(.caption.monospaced()).textSelection(.enabled)
                            Text("Attention weights show routing, not causal importance. One layer/head per artifact.").foregroundStyle(.secondary)
                        }
                        if let nodes = a.nodes, let edges = a.edges, a.kind == "graph" {
                            Canvas { context, size in
                                func point(_ index: Int) -> CGPoint {
                                    let angle = Double(index) / Double(nodes.count) * 2 * Double.pi
                                    return CGPoint(x: size.width/2 + CGFloat(Darwin.cos(angle))*(size.width/2-35), y: size.height/2 + CGFloat(Darwin.sin(angle))*(size.height/2-35))
                                }
                                let lookup = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
                                for edge in edges {
                                    guard let s = lookup[edge.source], let t = lookup[edge.target] else { continue }
                                    var path = Path(); path.move(to: point(s)); path.addLine(to: point(t))
                                    let highlighted = selectedNode == nil || selectedNode == edge.source || selectedNode == edge.target
                                    context.stroke(path, with: .color((edge.weight >= 0 ? Color.green : .orange).opacity(highlighted ? 0.6 : 0.06)), lineWidth: 1)
                                }
                                for i in nodes.indices {
                                    let p = point(i)
                                    context.fill(Path(ellipseIn: CGRect(x: p.x-5, y: p.y-5, width: 10, height: 10)), with: .color(nodes[i].id == selectedNode ? .yellow : .purple))
                                    context.draw(Text(String(i)).font(.caption2), at: CGPoint(x:p.x,y:p.y-13))
                                }
                            }.frame(height: 330)
                            Text("Green: positive weight · Orange: negative. Select a node to inspect directed edges; layout is not model geometry.").font(.caption)
                            ForEach(Array(nodes.enumerated()), id: \.element.id) { i, node in
                                Button("\(i). \(node.label)") { selectedNode = node.id }
                            }
                            ForEach(Array(edges.enumerated()).filter { selectedNode == nil || $0.element.source == selectedNode || $0.element.target == selectedNode }, id: \.offset) { _, edge in
                                Text("\(edge.source) → \(edge.target): \(edge.weight)").font(.caption.monospaced())
                            }
                        }
                        if let features = a.features {
                            ForEach(features.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.id.contains(search) }) { feature in
                                GroupBox("Feature \(feature.id) · \(feature.label)") {
                                    VStack(alignment: .leading) {
                                        Chart(feature.activations.indices, id: \.self) { i in
                                            BarMark(x: .value("Token", i), y: .value("Activation", feature.activations[i])).foregroundStyle(.purple)
                                        }.frame(height: 130)
                                        Text(feature.tokens.joined()).font(.callout).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("Bring your research into Dyno", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Import a data-only JSON artifact from dyno.interop. Supports attention maps, SAE feature examples and directed attribution graphs. Large models and circuit generation remain in your external research runtime."))
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 450)
        }.onAppear { reload() }
    }
    @MainActor private func fetchFeature() async {
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [atlasModel, atlasSource, atlasFeature].allSatisfy({ !$0.isEmpty && $0.count < 200 && $0.unicodeScalars.allSatisfy { valid.contains($0) } }), Int(atlasFeature).map({ $0 >= 0 }) == true else {
            error = "Enter valid model/source IDs and a nonnegative feature index"; return
        }
        fetching = true; defer { fetching = false }
        do {
            let url = URL(string: "https://www.neuronpedia.org/api/feature/\(atlasModel)/\(atlasSource)/\(atlasFeature)")!
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 30))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Neuronpedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "Feature not available; check model/source/index or try later"]) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 8_000_000 else { throw NSError(domain: "Neuronpedia", code: 2, userInfo: [NSLocalizedDescriptionKey:"Feature response exceeds 8 MB"]) }
                data.append(byte)
            }
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["modelId"] as? String == atlasModel, value["layer"] as? String == atlasSource,
                  String(describing: value["index"] ?? "") == atlasFeature,
                  let examples = value["activations"] as? [[String: Any]], !examples.isEmpty else {
                throw NSError(domain: "Neuronpedia", code: 3, userInfo: [NSLocalizedDescriptionKey:"Response identity mismatch or no activation examples"])
            }
            let label = (value["explanations"] as? [[String: Any]])?.first?["description"] as? String ?? "Unlabeled"
            let features: [[String: Any]] = examples.prefix(32).enumerated().map { i, row in
                ["id": "\(atlasFeature) / example \(i)", "label": label, "tokens": row["tokens"] ?? [], "activations": row["values"] ?? []]
            }
            let normalized: [String: Any] = ["kind":"features", "model":atlasModel, "source":"Neuronpedia / \(atlasSource)", "note":"Public source examples and annotations; not measurements on the local model.", "features":features]
            let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
            let parsed = try LabArtifact.read(normalizedData)
            _ = try archive.save(["title":"\(atlasModel) / \(atlasSource) / \(atlasFeature)", "artifact":normalized], kind:"tool-artifact")
            artifact = parsed; error = nil; reload()
        } catch { self.error = error.localizedDescription }
    }
    private func reload() { do { history = try archive.load(kind: "tool-artifact") } catch { self.error = error.localizedDescription } }
    private func importArtifact() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8_000_000 else { throw NSError(domain: "Artifact", code: 1, userInfo: [NSLocalizedDescriptionKey:"Artifact exceeds 8 MB"]) }
            let data = try Data(contentsOf: url)
            let parsed = try LabArtifact.read(data)
            _ = try archive.save(["title": "\(parsed.model) · \(parsed.kind)", "artifact": JSONSerialization.jsonObject(with: data)], kind: "tool-artifact")
            artifact = parsed; selectedNode = nil; error = nil; reload()
        } catch { self.error = error.localizedDescription }
    }
}
