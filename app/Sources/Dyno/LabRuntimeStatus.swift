import Foundation
import Observation
import DynoKit

@Observable @MainActor final class LabRuntimeStatus {
    struct Endpoint {
        let port: UInt16
        let identifier: String
        let name: String
        let checked: Date
        let ready: Bool
    }
    var endpoints: [Endpoint] = []
    var checking = false
    var available: [Endpoint] { endpoints.filter { ResearchRuntimeReadiness.permitsRun(healthy: $0.ready, checkedAt: $0.checked, savedModel: nil, currentModel: $0.identifier) } }
    func ready(_ port: UInt16?, model: String? = nil) -> Bool {
        available.contains { $0.port == port && ResearchRuntimeReadiness.permitsRun(healthy: $0.ready, checkedAt: $0.checked, savedModel: model, currentModel: $0.identifier) }
    }
    func refresh(_ models: [LLMModel]) async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        let candidates = models.filter { $0.port != nil }
        // Drop disappeared/replaced endpoints immediately, before probing survivors.
        endpoints.removeAll { old in !candidates.contains { $0.port == old.port && $0.identifier == old.identifier } }
        var next: [Endpoint] = []
        for candidate in candidates {
            guard !Task.isCancelled, let port = candidate.port else { break }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
            request.timeoutInterval = 1; request.cachePolicy = .reloadIgnoringLocalCacheData
            var ready = false
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = object["data"] as? [[String: Any]], !list.isEmpty {
                var health = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
                health.timeoutInterval = 1; health.cachePolicy = .reloadIgnoringLocalCacheData
                if let (_, response) = try? await URLSession.shared.data(for: health) {
                    ready = (response as? HTTPURLResponse)?.statusCode == 200
                }
            }
            next.append(Endpoint(port: port, identifier: candidate.identifier, name: candidate.name, checked: Date(), ready: ready))
        }
        if !Task.isCancelled { endpoints = next }
    }
}
