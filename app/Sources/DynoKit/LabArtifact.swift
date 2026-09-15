import Foundation

/// Portable, data-only interchange. No notebooks, HTML or pickled objects execute.
public struct LabArtifact: Codable {
    public struct Node: Codable, Identifiable { public let id: String; public let label: String }
    public struct Edge: Codable { public let source: String; public let target: String; public let weight: Double }
    public struct Feature: Codable, Identifiable {
        public let id: String; public let label: String; public let tokens: [String]; public let activations: [Double]
    }
    public let kind: String
    public let model: String
    public let source: String
    public let note: String
    public var tokens: [String]?
    public var values: [[Double]]?
    public var nodes: [Node]?
    public var edges: [Edge]?
    public var features: [Feature]?
    public var thinking: String?
    public var prompt: String?
    public var answer: String?
    public var tokenPhases: [String]?
    public var layerIndices: [Int]?
    public var captureMode: String?
    public var generationStatus: String?

    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 8_000_000 else { throw invalid("Artifact exceeds 8 MB") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.model.isEmpty, !value.source.isEmpty else { throw invalid("Model and source are required") }
        switch value.kind {
        case "generation":
            let phases = Set(["prompt", "thinking", "answer", "marker", "unassigned"])
            guard let tokens = value.tokens, !tokens.isEmpty, tokens.count <= 1024,
                  let tokenPhases = value.tokenPhases, tokenPhases.count == tokens.count,
                  tokenPhases.allSatisfy({ phases.contains($0) }),
                  let layers = value.layerIndices, !layers.isEmpty, layers.count <= 8,
                  Set(layers).count == layers.count, layers.allSatisfy({ $0 >= 0 && $0 < 256 }),
                  let values = value.values, values.count == layers.count,
                  values.allSatisfy({ $0.count == tokens.count && $0.allSatisfy { $0.isFinite && $0 >= 0 } }),
                  value.captureMode == "Teacher-forced replay",
                  let status = value.generationStatus,
                  ["disabled", "complete", "incomplete", "missing_open_marker", "ambiguous_markers", "unexpected_markers"].contains(status),
                  (["disabled", "complete"].contains(status) || value.answer == nil)
            else { throw invalid("Generation capture needs aligned token phases/layer norms, valid status, and explicit replay provenance; at most 1024 tokens") }
        case "attention":
            guard let tokens = value.tokens, let matrix = value.values, !tokens.isEmpty, tokens.count <= 128,
                  matrix.count == tokens.count, matrix.allSatisfy({ $0.count == tokens.count && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }) else { throw invalid("Attention needs a square token matrix, at most 128 tokens, with values in 0…1") }
        case "graph":
            guard let nodes = value.nodes, let edges = value.edges, !nodes.isEmpty, nodes.count <= 128, edges.count <= 1024 else { throw invalid("Graph limit: 128 nodes and 1024 edges") }
            let ids = Set(nodes.map(\.id))
            guard ids.count == nodes.count, edges.allSatisfy({ ids.contains($0.source) && ids.contains($0.target) && $0.weight.isFinite }) else { throw invalid("Graph has duplicate nodes, dangling edges or nonfinite weights") }
        case "features":
            guard let features = value.features, !features.isEmpty, features.count <= 256, Set(features.map(\.id)).count == features.count,
                  features.allSatisfy({ $0.tokens.count <= 512 && $0.tokens.count == $0.activations.count && $0.activations.allSatisfy(\.isFinite) }) else { throw invalid("Invalid feature examples or activations") }
        default: throw invalid("Supported artifact kinds: attention, graph, features, generation")
        }
        return value
    }
    private static func invalid(_ message: String) -> NSError { NSError(domain: "DynoLabArtifact", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
