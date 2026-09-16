import Foundation
import CryptoKit

/// A deliberately narrow public format. Raw transport logs, endpoints, audio and working copies are never exported.
public struct CommunityStudy: Codable {
    public var schemaVersion = 1
    public var title: String
    public var question: String
    public var hypothesis: String
    public var method: String
    public var finding: String
    public var limitations: String
    public var license = "CC-BY-4.0"
    public struct Model: Codable { public var name: String; public var revision: String?; public var runtime: String }
    public var model: Model
    public var omissions: [String]
    public struct Item: Codable {
        public var id: UUID
        public var parent: UUID?
        public var kind: String
        public var title: String
        public var prompt: String?
        public var answer: String?
        public var thinking: String?
        public var note: String?
        public var model: String?
        public var system: String?
        public var context: [ResearchMessage]?
        public struct Settings: Codable { public var temperature: Double; public var seed: Int; public var maxTokens: Int; public var thinking: String }
        public var settings: Settings?
        public var finishReason: String?
    }
    public var entries: [Item]
    public init(study: ResearchStudy, entries source: [ResearchEntry], includeThinking: Bool, method: String, finding: String, limitations: String) {
        title = study.title; question = study.question; hypothesis = study.hypothesis
        self.method = method; self.finding = finding; self.limitations = limitations
        let names = Set(source.compactMap { $0.iteration?.model }.filter { !$0.isEmpty })
        model = Model(name: names.count == 1 ? names.first! : "Multiple or unrecorded models; see individual entries", revision: nil, runtime: "Dyno Lab; runtime revision not recorded")
        omissions = ["Raw request/response logs, local endpoints, attachments, audio and working copies are excluded.", "Only entries selected by the author are included. Model revision was not recorded in the notebook."]
        if !includeThinking { omissions.append("Model-emitted thinking omitted by the author.") }
        let ids = Set(source.map(\.id))
        entries = source.map { e in
            let settings = e.iteration.map { Item.Settings(temperature: $0.temperature, seed: $0.seed, maxTokens: $0.maxTokens, thinking: $0.thinking) }
            return Item(id: e.id, parent: e.parent.flatMap { ids.contains($0) ? $0 : nil }, kind: ["prompt", "result", "error"].contains(e.kind) ? e.kind : "note", title: e.title, prompt: e.iteration?.prompt, answer: e.answer, thinking: includeThinking ? e.thinking : nil, note: e.iteration == nil ? e.body : nil, model: e.iteration?.model, system: e.iteration?.system, context: e.iteration?.context, settings: settings, finishReason: e.finishReason)
        }
        if source.contains(where: { $0.parent.map { !ids.contains($0) } ?? false }) { omissions.append("Some parent entries were omitted; their links were removed. This package contains a partial history.") }
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self); _ = try Self.read(data); return data
    }
    public static func read(_ data: Data) throws -> CommunityStudy {
        func invalid() -> NSError { NSError(domain: "DynoSharing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid study package. Use schema 1, include a title, question, method and limitations, and keep the package below 1 MB with 1–200 entries."]) }
        guard data.count <= 1_000_000 else { throw invalid() }
        let p = try JSONDecoder().decode(Self.self, from: data)
        guard p.schemaVersion == 1, !p.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, p.title.count <= 160, !p.question.isEmpty, p.question.count <= 4000, !p.method.isEmpty, p.method.count <= 8000, !p.limitations.isEmpty, p.limitations.count <= 8000, ["CC-BY-4.0", "CC0-1.0"].contains(p.license), (1...200).contains(p.entries.count), Set(p.entries.map(\.id)).count == p.entries.count else { throw invalid() }
        let ids = Set(p.entries.map(\.id)); let parents = Dictionary(uniqueKeysWithValues: p.entries.map { ($0.id, $0.parent) })
        for e in p.entries {
            guard ["prompt", "result", "note", "error"].contains(e.kind), e.parent == nil || ids.contains(e.parent!) else { throw invalid() }
            if let s = e.settings { guard s.temperature.isFinite, (0...10).contains(s.temperature), (1...1_000_000).contains(s.maxTokens), ["on","off","default"].contains(s.thinking) else { throw invalid() } }
            var seen = Set<UUID>(); var cursor: UUID? = e.id
            while let id = cursor { guard seen.insert(id).inserted else { throw invalid() }; cursor = parents[id] ?? nil }
        }
        return p
    }
    /// Creates a separate notebook, remaps ancestry, records the original bytes and never assigns a local endpoint.
    public func importInto(_ store: ResearchNotebook, original: Data, sourceURL: String = "Downloaded study package") throws -> UUID {
        let study = ResearchStudy(title: title, question: question, hypothesis: hypothesis)
        var pending: [ResearchEntry] = []; var mapped: [UUID: UUID] = [:]
        var remaining = entries
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { $0.parent == nil || mapped[$0.parent!] != nil }) else { throw CocoaError(.fileReadCorruptFile) }
            let item = remaining.remove(at: index)
            var iteration: ResearchIteration?
            if let prompt = item.prompt {
                var input = ResearchIteration(); input.prompt = prompt; input.model = item.model ?? model.name; input.port = 0
                input.system = item.system ?? ""; input.context = item.context ?? []
                if let s = item.settings { input.temperature = s.temperature; input.seed = s.seed; input.maxTokens = s.maxTokens; input.thinking = s.thinking }
                iteration = input
            }
            var body = item.note ?? ""
            if let finish = item.finishReason, item.kind == "result" {
                body = String(data: try JSONSerialization.data(withJSONObject: ["response": ["choices": [["finish_reason": finish]]]]), encoding: .utf8) ?? body
            }
            let e = ResearchEntry(kind: item.kind, title: item.title, body: body, parent: item.parent.flatMap { mapped[$0] }, iteration: iteration, answer: item.answer, thinking: item.thinking)
            mapped[item.id] = e.id; pending.append(e)
        }
        try store.create(study)
        do {
            let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            let provenance = "Source: \(sourceURL)\nPackage SHA-256: \(hash)\nLicense: \(license)\nModel: \(model.name)\nRevision: \(model.revision ?? "Not recorded")\nMethod: \(method)\nFinding: \(finding)\nLimitations: \(limitations)\nOmissions: \(omissions.joined(separator: "; "))\nImported history; local timestamps record import time. Select your own model before running."
            try store.append(ResearchEntry(kind: "note", title: "Imported study · source and limitations", body: provenance), to: study.id)
            for e in pending { try store.append(e, to: study.id) }
            let target = store.folder(study.id).appendingPathComponent("source-package.json")
            try original.write(to: target, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return study.id
        } catch { try? FileManager.default.removeItem(at: store.folder(study.id)); throw error }
    }
}
