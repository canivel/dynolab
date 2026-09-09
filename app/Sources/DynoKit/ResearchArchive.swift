import Foundation

/// Local result snapshots. One atomic file per run keeps earlier runs immutable.
public struct ResearchArchive {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mlx-dyno/research-history")) { self.directory = directory }

    @discardableResult public func save(_ value: [String: Any], kind: String) throws -> [String: Any] {
        var record = value
        record["id"] = UUID().uuidString
        record["kind"] = kind
        record["saved_at"] = Date().timeIntervalSince1970
        record["schema_version"] = 1
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let url = directory.appendingPathComponent(record["id"] as! String).appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return record
    }

    public func load(kind: String) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      record["kind"] as? String == kind else { return nil }
                return record
            }.sorted { ($0["saved_at"] as? Double ?? 0) > ($1["saved_at"] as? Double ?? 0) }
    }
}
