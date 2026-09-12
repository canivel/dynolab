import Foundation

/// Measurements from this coordinator's output, never from unrelated endpoints.
public struct PoolTelemetry {
    public var workerStatus = "Unavailable"
    public var workerRPCRunning: Bool?
    public var workerDeviceID: String?
    public var workerName: String?
    public var workerInstance: String?
    public var workerUpdatedAt: Date?
    public var workerUtilization: Double?
    public var workerUsedBytes: Double?
    public var workerTotalBytes: Double?
    public var workerTemperature: Double?
    public var workerPower: Double?
    public var workerHistory: [Double] = []
    public var workerFresh: Bool { workerStatus == "Live" && (workerUpdatedAt.map { Date().timeIntervalSince($0) < 5 } ?? false) }
    public var phase = "Not started"
    public var measuredAt: Date?
    public var ready = false
    public var active = false
    public var endpoint: String?
    public var error: String?
    public var freeMiB: [String: Double] = [:]
    public var mappedModelDevices: Set<String> = []
    public var modelMiB: [String: Double] = [:]
    public var rates: [Double] = []
    public var completed = 0
    public var events: [String] = []
    public init() {}
    public mutating func consume(_ line: String) {
        if let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let status = event["status"] as? String {
            if status == "worker_telemetry" {
                guard let sample = event["sample"] as? [String: Any] else { return }
                let instance = sample["instance_id"] as? String
                if instance != workerInstance { workerHistory = []; workerInstance = instance }
                let live = event["stale"] as? Bool == false && sample["collector_status"] as? String == "ok"
                workerStatus = live ? "Live" : "Stale / unavailable"
                workerUpdatedAt = Date().addingTimeInterval(-((sample["sample_age_ms"] as? NSNumber)?.doubleValue ?? 0) / 1000)
                workerRPCRunning = (sample["rpc"] as? [String: Any])?["running"] as? Bool
                guard live, let gpus = sample["gpus"] as? [[String: Any]],
                      let gpu = gpus.first(where: { $0["selected"] as? Bool == true }) else {
                    workerHistory = []; workerUtilization = nil; if live { workerStatus = "GPU mapping unavailable" }; return
                }
                let deviceID = gpu["id"] as? String
                if deviceID != workerDeviceID { workerHistory = []; workerDeviceID = deviceID }
                workerName = gpu["name"] as? String
                workerUtilization = (gpu["utilization_percent"] as? NSNumber)?.doubleValue
                workerUsedBytes = (gpu["memory_used_bytes"] as? NSNumber)?.doubleValue
                workerTotalBytes = (gpu["memory_total_bytes"] as? NSNumber)?.doubleValue
                workerTemperature = (gpu["temperature_c"] as? NSNumber)?.doubleValue
                workerPower = (gpu["power_watts"] as? NSNumber)?.doubleValue
                if let value = workerUtilization { workerHistory.append(value); if workerHistory.count > 120 { workerHistory.removeFirst() } }
                return
            }
            if status == "telemetry_unavailable" { workerStatus = "Unavailable"; workerHistory = []; workerUtilization = nil; return }
            switch status {
            case "checking_connection": phase = "Verifying worker"
            case "ssh_endpoint_verified", "connecting": phase = "Connecting securely"
            case "tunnel_ready": phase = "Discovering GPUs"
            case "devices_discovered":
                phase = "Devices verified"; measuredAt = Date()
                freeMiB = (event["free_memory_mib"] as? [String: NSNumber] ?? [:]).mapValues { $0.doubleValue }
            case "loading": phase = "Loading model"
            case "ready": phase = "Ready"; ready = true
            case "stopped": ready = false; active = false; workerStatus = "Stopped"; if error == nil { phase = "Stopped" }
            case "failed": error = event["error"] as? String; phase = "Needs attention"; ready = false; active = false
            default: break
            }
            if let value = event["endpoint"] as? String { endpoint = value }
            record(error ?? phase)
        }
        if let match = captures(#"(MTL\d+|RPC\d+)(?:_Mapped|\[[^\]]+\])? model buffer size =\s*([0-9.]+) MiB"#, line), let value = Double(match[1]) { modelMiB[match[0]] = value; if line.contains(match[0] + "_Mapped") { mappedModelDevices.insert(match[0]) } else { mappedModelDevices.remove(match[0]) } }
        if line.contains("processing task, is_child = 0") { active = true; record("Request started") }
        if let match = captures(#"(?<!prompt )eval time =\s*[0-9.]+ ms /\s*\d+ tokens.*?([0-9.]+) tokens per second"#, line), let value = Double(match[0]) {
            rates.append(value); if rates.count > 60 { rates.removeFirst() }
        }
        if line.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory") || line.contains("backend is in error state") {
            error = "Metal ran out of GPU memory during execution. Stop the pool and restart with a smaller allocation before retrying."
            phase = "Execution failed"; ready = false; active = false
            record(error!)
        }
        if line.contains("stop processing: n_tokens") { active = false; if error == nil { completed += 1; record("Request completed") } }
    }
    private mutating func record(_ message: String) {
        events.append(message); if events.count > 40 { events.removeFirst() }
    }
    private func captures(_ pattern: String, _ line: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let match = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }
}
