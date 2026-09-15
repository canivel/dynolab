import Foundation

/// Accumulates OpenAI-compatible SSE deltas without treating an interrupted stream as complete.
public struct ResearchStream {
    public private(set) var content = ""
    public private(set) var reasoning = ""
    public private(set) var finishReason: String?
    public private(set) var chunks: [[String: Any]] = []
    public private(set) var done = false
    public init() {}
    public mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { done = true; return }
        guard !payload.isEmpty else { return }
        guard let data = payload.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        chunks.append(object)
        if let error = object["error"] { throw NSError(domain: "ResearchStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Endpoint stream error: \(error)"]) }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        content += delta["content"] as? String ?? ""
        reasoning += delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
        if let finish = choice["finish_reason"] as? String { finishReason = finish }
    }
    public var text: ResearchResponseText { ResearchResponseText(content: content, reasoning: reasoning) }
    public var response: [String: Any] {
        var result: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content, "reasoning": reasoning], "finish_reason": finishReason as Any? ?? NSNull()]]]
        if let usage = chunks.last(where: { $0["usage"] is [String: Any] })?["usage"] { result["usage"] = usage }
        if let model = chunks.first?["model"] { result["model"] = model }
        return result
    }
}
