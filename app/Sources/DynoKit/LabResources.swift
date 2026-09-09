import Foundation

/// Conservative admission estimate, not a prediction of peak MLX allocation.
public struct LabResources {
    public let estimatedBytes: Int64
    public let availableBytes: Int64?
    public let reserveBytes: Int64
    public let blockedReason: String?
    public var canRun: Bool { blockedReason == nil }

    public init(weightBytes: Int64?, memory: MemorySample, gpuBusy: Double,
                activeRequests: Int, fresh: Bool, maxInputTokens: Int = 256) {
        // Weight overhead, framework workspace, and a quadratic sequence margin.
        let tokens = Double(max(1, min(maxInputTokens, 1024)))
        estimatedBytes = Int64(Double(weightBytes ?? 0) * 1.35 + 2 * GB +
            pow(tokens / 256, 2) * 0.125 * GB)
        reserveBytes = max(Int64(4 * GB), Int64(Double(memory.total) * 0.05))
        if memory.total > 0, let gpuHeadroom = memory.gpuHeadroom {
            availableBytes = max(0, min(memory.total - memory.used, gpuHeadroom) - reserveBytes)
        } else { availableBytes = nil }
        if !fresh {
            blockedReason = "Waiting for fresh hardware measurements. Keep Dyno open while telemetry refreshes."
        } else if weightBytes == nil || weightBytes! <= 0 {
            blockedReason = "Choose a downloaded MLX model so Dyno can estimate its additional memory."
        } else if let availableBytes, estimatedBytes > availableBytes {
            blockedReason = "Not enough estimated headroom for a separate copy. Choose a smaller or more heavily quantized model, or free memory in other apps. Stopping a serving model is a manual option in Models."
        } else if availableBytes == nil {
            blockedReason = "Memory or Metal headroom is unavailable. Wait for telemetry before starting an experiment."
        } else if activeRequests > 0 {
            blockedReason = "Inference requests are active. Wait for them to finish, or schedule the experiment when serving traffic is quiet."
        } else if gpuBusy >= 50 {
            blockedReason = "The GPU is busy. Wait for a quieter period before adding an experiment."
        } else {
            blockedReason = nil
        }
    }
}
