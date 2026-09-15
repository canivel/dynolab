import Foundation

public struct ResearchMessage: Codable, Equatable {
    public var role: String
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}
public struct ResearchIteration: Codable, Equatable {
    public var model = ""
    public var port: UInt16 = 0
    public var system = "You are a helpful assistant."
    public var prompt = ""
    public var context: [ResearchMessage] = []
    public var thinking = "default"
    public var temperature = 0.0
    public var maxTokens = 2048
    public var seed = 0
    public init() {}
    public var messages: [ResearchMessage] {
        (system.isEmpty ? [] : [ResearchMessage(role: "system", content: system)]) + context + [ResearchMessage(role: "user", content: prompt)]
    }
}
public struct ResearchStudy: Codable, Identifiable {
    public let id: UUID
    public let created: Date
    public let title: String
    public let question: String
    public let hypothesis: String
    public init(title: String, question: String, hypothesis: String) {
        id = UUID(); created = Date(); self.title = title; self.question = question; self.hypothesis = hypothesis
    }
}
public struct ResearchEntry: Codable, Identifiable {
    public let id: UUID
    public let created: Date
    public var kind: String
    public var title: String
    public var body: String
    public var parent: UUID?
    public var iteration: ResearchIteration?
    public var answer: String?
    public var thinking: String?
    public var attachment: String?
    public init(kind: String, title: String, body: String = "", parent: UUID? = nil,
                iteration: ResearchIteration? = nil, answer: String? = nil, thinking: String? = nil, attachment: String? = nil) {
        id = UUID(); created = Date(); self.kind = kind; self.title = title; self.body = body
        self.parent = parent; self.iteration = iteration; self.answer = answer; self.thinking = thinking; self.attachment = attachment
    }
}
/// Append-only entries, including drafts and failed attempts. Corrections are new entries.
/// Independent files prevent two open app instances from overwriting a study's history.
public struct ResearchNotebook {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/notebooks")) { self.directory = directory }
    public func folder(_ study: UUID) -> URL { directory.appendingPathComponent(study.uuidString) }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    public func create(_ study: ResearchStudy) throws { try write(study, to: folder(study.id).appendingPathComponent("study.json")) }
    public func studies() throws -> [ResearchStudy] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try read(ResearchStudy.self, $0.appendingPathComponent("study.json")) }.sorted { $0.created > $1.created }
    }
    public func append(_ entry: ResearchEntry, to study: UUID) throws {
        guard FileManager.default.fileExists(atPath: folder(study).appendingPathComponent("study.json").path) else { throw CocoaError(.fileNoSuchFile) }
        let url = folder(study).appendingPathComponent("entries/\(entry.id.uuidString).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try write(entry, to: url)
    }
    public func entries(_ study: UUID) throws -> [ResearchEntry] {
        let url = folder(study).appendingPathComponent("entries")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .map { try read(ResearchEntry.self, $0) }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
    }
    public func attach(_ source: URL, study: UUID) throws -> String {
        let name = UUID().uuidString + "." + source.pathExtension
        let target = folder(study).appendingPathComponent("attachments/\(name)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return "attachments/\(name)"
    }
}

public struct ResearchResponseText {
    public let answer: String
    public let thinking: String
    public init(content: String, reasoning: String = "") {
        guard let start = content.range(of: "<think>") else { answer = content; thinking = reasoning; return }
        if let end = content.range(of: "</think>", range: start.upperBound..<content.endIndex) {
            thinking = reasoning.isEmpty ? String(content[start.upperBound..<end.lowerBound]) : reasoning
            answer = String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            thinking = reasoning.isEmpty ? String(content[start.upperBound...]) : reasoning
            answer = String(content[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

public struct ResearchWorkingCopy: Codable {
    public var input: ResearchIteration
    public var title: String
    public var parent: UUID?
    public var note: String
    public var noteKind: String
    public var focus: UUID?
    public var updated: Date
    public init(input: ResearchIteration, title: String, parent: UUID?, note: String, noteKind: String, focus: UUID?) {
        self.input = input; self.title = title; self.parent = parent; self.note = note; self.noteKind = noteKind; self.focus = focus; updated = Date()
    }
}
extension ResearchNotebook {
    public func saveWorkingCopy(_ copy: ResearchWorkingCopy, study: UUID, session: UUID) throws {
        try write(copy, to: folder(study).appendingPathComponent("drafts/\(session.uuidString).json"))
    }
    public func workingCopy(_ study: UUID) throws -> ResearchWorkingCopy? {
        let url = folder(study).appendingPathComponent("drafts")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .map { try read(ResearchWorkingCopy.self, $0) }.max { $0.updated < $1.updated }
    }
}

/// Reads completion metadata from immutable saved evidence, including older notebooks.
extension ResearchEntry {
    public var finishReason: String? {
        guard let data = body.data(using: .utf8),
              let evidence = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = evidence["response"] as? [String: Any],
              let choice = (response["choices"] as? [[String: Any]])?.first else { return nil }
        return choice["finish_reason"] as? String
    }
    public var hasFinalAnswer: Bool { !(answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hitTokenLimit: Bool { kind == "result" && finishReason == "length" }
    public var largerBudgetRetry: ResearchIteration? {
        guard hitTokenLimit, var settings = iteration, settings.maxTokens < 16384 else { return nil }
        settings.maxTokens = min(16384, max(8192, settings.maxTokens * 2))
        return settings
    }
}

extension ResearchEntry {
    public var completionWarning: String? {
        guard kind == "result" else { return nil }
        if hitTokenLimit {
            let budget = iteration.map { " (\($0.maxTokens) tokens)" } ?? ""
            let outcome = hasFinalAnswer ? "The answer may be incomplete." : "The model stopped before returning a final answer."
            return "The output limit\(budget) was reached. \(outcome) Thinking and the answer share this budget. Review a retry with more tokens; completion is not guaranteed. The original result is preserved separately."
        }
        if !hasFinalAnswer {
            return "The endpoint returned no final answer (finish reason: \(finishReason ?? "not reported")). Review the saved response before retrying. Model-emitted thinking is not a substitute for an answer."
        }
        return nil
    }
}

/// Visibility changes are journal events; original entries and exports remain intact.
public enum ResearchTimelineArchive {
    public static func hiddenIDs(in entries: [ResearchEntry]) -> Set<UUID> {
        var hidden = Set<UUID>()
        for entry in entries.sorted(by: { $0.created < $1.created }) where ["archive", "restore"].contains(entry.kind) {
            guard let data = entry.body.data(using: .utf8), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { continue }
            if entry.kind == "archive" { hidden.formUnion(ids) } else { hidden.subtract(ids) }
        }
        return hidden
    }
    public static func queryIDs(for entry: ResearchEntry, in entries: [ResearchEntry]) -> [UUID] {
        let resultKinds = ["result", "error", "cancelled"]
        let root = resultKinds.contains(entry.kind) ? entries.first(where: { $0.id == entry.parent && $0.kind == "iteration" }) ?? entry : entry
        guard root.kind == "iteration" else { return [entry.id] }
        return [root.id] + entries.filter { $0.parent == root.id && resultKinds.contains($0.kind) }.map(\.id)
    }
}
