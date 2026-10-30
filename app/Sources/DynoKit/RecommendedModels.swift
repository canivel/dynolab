import Foundation

/// A short list of MLX models known to run well with Dyno, shown at the top of Discover.
///
/// The hub's own ordering is by downloads, which says nothing about what serves well here
/// or fits this Mac. Each entry was checked against the bundled mlx_lm and the hub.
public enum RecommendedModels {
    public struct Entry: Sendable, Identifiable, Hashable {
        public var id: String
        /// What it is good for, in a few words.
        public var use: String
        public var sizeBytes: Int64

        public var name: String { String(id.split(separator: "/").last ?? "") }
        public var author: String { String(id.split(separator: "/").first ?? "") }
        public var drafter: DynoBoost.Drafter? { DynoBoost.drafter(for: id) }

        public var catalogModel: CatalogModel {
            CatalogModel(id: id, name: name, author: author, downloads: 0, likes: 0, sizeBytes: sizeBytes,
                         quantization: ModelCatalog.quantization(in: name), pipeline: nil, createdAt: nil, updatedAt: nil)
        }
    }

    public static let all = [
        Entry(id: "lmstudio-community/Qwen3.8-27B-MLX-4bit",
              use: "Coding with Claude Code or Codex. The fastest with its drafter.", sizeBytes: 16_100_000_000),
        Entry(id: "lmstudio-community/Qwen3.8-27B-MLX-8bit",
              use: "The same model at higher quality, for Macs with 64 GB or more.", sizeBytes: 29_500_000_000),
        Entry(id: "lmstudio-community/Qwen3.5-9B-MLX-4bit",
              use: "Quick chat and agents on 16–24 GB Macs.", sizeBytes: 6_000_000_000),
        Entry(id: "mlx-community/Qwen3-8B-4bit",
              use: "Lab research: the model the guides and examples use.", sizeBytes: 4_600_000_000),
        Entry(id: "lmstudio-community/gemma-4-31B-it-MLX-4bit",
              use: "A second model family to compare in evals.", sizeBytes: 18_400_000_000),
    ]

    /// The entries whose weights leave room for context on this Mac, best first; all of them when the budget is unknown.
    public static func fitting(budget: Int64?) -> [Entry] {
        guard let budget else { return all }
        return all.filter { Double($0.sizeBytes) < Double(budget) * 0.85 }
    }
}
