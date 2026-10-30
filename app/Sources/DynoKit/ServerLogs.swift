import Foundation

/// Model server logs in ~/.mlx-dyno/logs: serve-<port>.log for servers the app starts, launch-<port>.log for
/// `dyno launch`. Performance → Logs reads them.
public enum ServerLogs {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public var url: URL
        public var port: UInt16?
        /// "Dyno app" or "dyno launch".
        public var source: String
        public var modified: Date
        public var size: Int64
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/logs")
    }

    /// A fresh log for a server about to start on `port`, beginning with `header`.
    public static func create(port: UInt16, header: String, in folder: URL = directory, now: Date = Date()) -> FileHandle? {
        let url = folder.appendingPathComponent("serve-\(port).log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now)
        guard FileManager.default.createFile(atPath: url.path, contents: Data("== \(stamp) \(header)\n".utf8)),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    /// The server logs, most recently written first.
    public static func list(in folder: URL = directory) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            guard url.pathExtension == "log", name.hasPrefix("serve-") || name.hasPrefix("launch-") else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let digits = name.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            return Entry(url: url, port: UInt16(digits), source: name.hasPrefix("serve-") ? "Dyno app" : "dyno launch",
                         modified: values?.contentModificationDate ?? .distantPast, size: Int64(values?.fileSize ?? 0))
        }.sorted { $0.modified > $1.modified }
    }

    /// The end of a log, at most `maxBytes`, starting on a whole line.
    public static func tail(_ url: URL, maxBytes: Int = 256_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        // Progress bars rewrite their line with carriage returns; keep only each line's final state.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }

    /// Dyno's own request lines ("12:38:57 request 1 · …").
    public static func isRequestLine(_ line: Substring) -> Bool {
        line.range(of: #"^\d\d:\d\d:\d\d request \d+ · "#, options: .regularExpression) != nil
    }
}
