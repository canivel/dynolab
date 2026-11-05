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

    @Test func aGGUFModelIsServedByLlamaCppBehindDyno() {
        let python = "/Applications/Dyno.app/Contents/Resources/python/bin/python3.12 -m dyno serve"
        #expect(ProcessScanner.runtime(for: python + " --model /Users/x/.mlx-dyno/gguf/a/Qwen3-0.6B-Q8_0.gguf --port 8971") == "llama.cpp")
        let backend = "/Applications/Dyno.app/Contents/Resources/pool-runtime/llama-server --model /Users/x/q.gguf --host 127.0.0.1 --port 50123 --alias dyno-backend --kv-unified"
        #expect(ModelMonitor.isDynoBackend(backend))
        #expect(ModelMonitor.modelArgument(in: backend) == "/Users/x/q.gguf")
        #expect(!ModelMonitor.isDynoBackend("llama-server -m /models/a.gguf --port 8080"))
        let file = LocalGGUF(path: "/Users/x/.mlx-dyno/gguf/a/Qwen3-0.6B-Q8_0.gguf", name: "Qwen3-0.6B-Q8_0.gguf", size: 639_446_688, repository: "Qwen/Qwen3-0.6B-GGUF")
        #expect(file.asModel.isGGUF)
        #expect(file.asModel.shortName == "Qwen3-0.6B-Q8_0.gguf")
        #expect(file.asModel.owner == "Qwen")
    }
}
