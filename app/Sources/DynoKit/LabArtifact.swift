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

    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 8_000_000 else { throw invalid("Artifact exceeds 8 MB") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.model.isEmpty, !value.source.isEmpty else { throw invalid("Model and source are required") }
        switch value.kind {
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
        default: throw invalid("Supported artifact kinds: attention, graph, features")
        }
        return value
    }
    private static func invalid(_ message: String) -> NSError { NSError(domain: "DynoLabArtifact", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
