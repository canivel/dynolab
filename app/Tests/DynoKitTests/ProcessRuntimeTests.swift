import Testing
@testable import DynoKit

struct ProcessRuntimeTests {
    @Test func dynoServeIsMLXWhateverTheModelIsCalled() {
        let python = "/Applications/Dyno.app/Contents/Resources/python/bin/python3.12 -m dyno serve"
        #expect(ProcessScanner.runtime(for: python + " --model /Users/x/.cache/huggingface/hub/models--OBLITERATUS--Qwen3.8-27B-OBLITERATED/snapshots/a5 --port 8971") == "MLX")
        #expect(ProcessScanner.runtime(for: python + " --model /Users/x/models/ollama-export --port 8972") == "MLX")
        #expect(ProcessScanner.runtime(for: "python -m mlx_lm.server --model org/model") == "MLX")
        #expect(ProcessScanner.runtime(for: "/usr/bin/python3 -m dyno lab --port 8980") == nil)
    }

    @Test func pythonDashMIsAModuleNotAModel() {
        let path = "/Users/x/.cache/huggingface/hub/models--OBLITERATUS--Qwen3.8-27B-OBLITERATED/snapshots/a5"
        #expect(ModelMonitor.modelArgument(in: "/App/python/bin/python3.12 -m dyno serve --model \(path) --port 8971") == path)
        #expect(ModelMonitor.modelArgument(in: "python -m mlx_lm.server --model org/model") == "org/model")
        #expect(ModelMonitor.modelArgument(in: "llama-server -m /models/a.gguf") == "/models/a.gguf")
        #expect(ModelMonitor.shortName(path) == "Qwen3.8-27B-OBLITERATED")
    }
}
