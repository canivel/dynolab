import Foundation
import Testing
@testable import DynoKit

struct DynoBoostTests {
    @Test func denseQwen35AndLaterAreBoosted() {
        #expect(DynoBoost.supports("lmstudio-community/Qwen3.8-27B-MLX-4bit"))
        #expect(DynoBoost.supports("mlx-community/Qwen3.5-9B-8bit"))
        #expect(DynoBoost.supports("Qwen3.6-27B-4bit"))
    }

    @Test func moeOlderQwenDraftersAndGGUFAreNot() {
        #expect(!DynoBoost.supports("mlx-community/Qwen3.6-35B-A3B-4bit"))
        #expect(!DynoBoost.supports("mlx-community/Qwen3-8B-4bit"))
        #expect(!DynoBoost.supports("z-lab/Qwen3.8-27B-DFlash2"))
        #expect(!DynoBoost.supports("unsloth/Qwen3.8-27B-GGUF"))
        #expect(!DynoBoost.supports("mlx-community/Llama-3.3-70B-Instruct-4bit"))
    }

    @Test func qwen38HasADFlash2Drafter() {
        #expect(DynoBoost.drafter(for: "lmstudio-community/Qwen3.8-27B-MLX-4bit")?.repository == "z-lab/Qwen3.8-27B-DFlash2")
        #expect(DynoBoost.drafter(for: "mlx-community/qwen3.8-27b-8bit")?.repository == "z-lab/Qwen3.8-27B-DFlash2")
        #expect(DynoBoost.drafter(for: "lmstudio-community/Qwen3.5-9B-MLX-4bit") == nil)
        #expect(DynoBoost.drafter(for: "z-lab/Qwen3.8-27B-DFlash2") == nil)
    }

    @Test func draftModelsAreToldByTheirConfigNotTheirName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String, _ config: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: url.appendingPathComponent("config.json"))
            return url.path
        }
        #expect(DynoBoost.isDraftModel(at: try folder("Qwen3.8-27B-DFlash2", #"{"architectures": ["DFlash2DraftModel"], "dflash_config": {}}"#)))
        // Full models with DFlash2 in the name (GLM-5.3-Flash-…-DFlash2) stay models.
        #expect(!DynoBoost.isDraftModel(at: try folder("GLM-5.3-Flash-mlx-oQ4e-DFlash2", #"{"architectures": ["Glm5NextForConditionalGeneration"]}"#)))
        #expect(!DynoBoost.isDraftModel(at: try folder("Qwen3.8-27B-MLX-4bit", #"{"model_type": "qwen3_5"}"#)))
        #expect(!DynoBoost.isDraftModel(at: root.appendingPathComponent("missing").path))
    }

    @Test func findsADownloadedDrafterOnlyWhenComplete() throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: hub) }
        let drafter = DynoBoost.drafters[0]
        let snapshot = hub.appendingPathComponent("models--z-lab--Qwen3.8-27B-DFlash2/snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        #expect(DynoBoost.downloadedDrafter(drafter, hub: hub.path) == nil)
        // A cache link whose blob never arrived.
        try FileManager.default.createSymbolicLink(atPath: snapshot.appendingPathComponent("model.safetensors").path,
                                                   withDestinationPath: hub.appendingPathComponent("missing-blob").path)
        #expect(DynoBoost.downloadedDrafter(drafter, hub: hub.path) == nil)
        try Data("w".utf8).write(to: hub.appendingPathComponent("missing-blob"))
        #expect(DynoBoost.downloadedDrafter(drafter, hub: hub.path) == snapshot.path)
    }

    @Test func suggestionsFitTheBudget() {
        #expect(RecommendedModels.fitting(budget: nil).count == RecommendedModels.all.count)
        let small = RecommendedModels.fitting(budget: 16 * 1_073_741_824)
        #expect(small.allSatisfy { $0.sizeBytes < 15_000_000_000 })
        #expect(small.contains { $0.id == "mlx-community/Qwen3-8B-4bit" })
        #expect(!small.contains { $0.id.hasSuffix("27B-MLX-8bit") })
        #expect(RecommendedModels.all.first?.drafter != nil)
    }
}
