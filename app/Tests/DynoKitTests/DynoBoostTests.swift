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
}
