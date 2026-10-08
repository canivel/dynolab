import Foundation

/// Flags passed to `dyno serve` when a model is started.
///
/// These are launch-time settings — changing one means restarting the server,
/// unlike the per-request `GenerationOptions`. Only values that differ from the
/// server's own defaults are passed, so an untouched setting stays whatever
/// mlx_lm considers correct.
struct LaunchOptions: Codable, Equatable {
    var maxTokens: Int = 4096
    var temperature: Double = 0.0
    var topP: Double = 1.0
    var topK: Int = 0

    /// How many prompts the server keeps cached. The difference between a
    /// snappy multi-turn chat and re-reading the context every turn.
    var promptCacheSize: Int = 10
    /// Sequences decoded together. Raising it trades latency for total
    /// throughput when more than one request is in flight.
    var decodeConcurrency: Int = 1
    var promptConcurrency: Int = 1

    /// Speculative decoding: a small model drafts, the big one verifies.
    var draftModelPath: String = ""
    var draftTokens: Int = 3

    var trustRemoteCode = false

    static let `default` = LaunchOptions()

    /// What `mlx_lm.server` does when a flag is left out. Compare against these, not against Dyno's own defaults:
    /// Dyno defaults to 4,096 tokens and one request at a time, the server to 512 tokens and batches of 32 and 8, so
    /// leaving the flags out silently ran models with short replies (a thinking model answered nothing) and batched
    /// decoding (which ran out of Metal resources on long agent contexts).
    static let server = LaunchOptions(maxTokens: 512, temperature: 0.0, topP: 1.0, topK: 0,
                                      promptCacheSize: 10, decodeConcurrency: 32, promptConcurrency: 8)

    var arguments: [String] {
        var flags: [String] = []
        let defaults = LaunchOptions.server

        if maxTokens != defaults.maxTokens { flags += ["--max-tokens", String(maxTokens)] }
        if temperature != defaults.temperature { flags += ["--temp", String(temperature)] }
        if topP != defaults.topP { flags += ["--top-p", String(topP)] }
        if topK != defaults.topK { flags += ["--top-k", String(topK)] }
        if promptCacheSize != defaults.promptCacheSize {
            flags += ["--prompt-cache-size", String(promptCacheSize)]
        }
        if decodeConcurrency != defaults.decodeConcurrency {
            flags += ["--decode-concurrency", String(decodeConcurrency)]
        }
        if promptConcurrency != defaults.promptConcurrency {
            flags += ["--prompt-concurrency", String(promptConcurrency)]
        }
        if !draftModelPath.isEmpty {
            flags += ["--draft-model", draftModelPath,
                      "--num-draft-tokens", String(draftTokens)]
        }
        if trustRemoteCode { flags.append("--trust-remote-code") }
        return flags
    }

    /// What the Run tab shows so it is obvious the model is not being started
    /// with stock settings.
    var summary: String {
        let flags = arguments
        return flags.isEmpty ? "default settings" : flags.joined(separator: " ")
    }
}
