import Foundation

public struct GGUFFile: Identifiable, Sendable, Decodable {
    public var id: String { rfilename }
    public let rfilename: String
    public let size: Int64?
    public var supported: Bool { rfilename.range(of: "-[0-9]{5}-of-[0-9]{5}\\.gguf$", options: .regularExpression) == nil }
}
public struct LocalGGUF: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public let repository: String?
}
public enum GGUFModels {
    public static func files(repository: String) async throws -> [GGUFFile] {
        guard repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "GGUF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a Hugging Face repository such as Qwen/Qwen3-0.6B-GGUF."])
        }
        let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "GGUF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not list this repository. Check its name and access permissions."])
        }
        struct Listing: Decodable { let siblings: [GGUFFile] }
        return try JSONDecoder().decode(Listing.self, from: data).siblings.filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
            .sorted { $0.rfilename < $1.rfilename }
    }
    public static func scan(roots: [String]? = nil) -> [LocalGGUF] {
        let manager = FileManager.default
        let defaults = [manager.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/gguf").path] + ModelLibrary.defaultSearchPaths()
        var found: [String: LocalGGUF] = [:]
        for root in roots ?? defaults {
            guard let entries = manager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in entries {
                guard file.pathExtension.lowercased() == "gguf", found[file.path] == nil else { continue }
                guard file.lastPathComponent.range(of: "-[0-9]{5}-of-[0-9]{5}\\.gguf$", options: .regularExpression) == nil else { continue }
                let resolved = file.resolvingSymlinksInPath()
                guard let handle = try? FileHandle(forReadingFrom: resolved) else { continue }
                let magic = try? handle.read(upToCount: 4); try? handle.close()
                guard magic == Data("GGUF".utf8),
                      let attrs = try? manager.attributesOfItem(atPath: resolved.path),
                      let size = attrs[.size] as? NSNumber, size.int64Value > 4 else { continue }
                var repository: String?
                var ancestor = file.deletingLastPathComponent()
                for _ in 0..<8 {
                    if let data = try? Data(contentsOf: ancestor.appendingPathComponent("model.json")),
                       let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        repository = metadata["repository"] as? String
                        if repository != nil { break }
                    }
                    if ancestor.lastPathComponent.hasPrefix("models--") {
                        repository = String(ancestor.lastPathComponent.dropFirst(8)).replacingOccurrences(of: "--", with: "/"); break
                    }
                    if ancestor.path == "/" { break }
                    ancestor.deleteLastPathComponent()
                }
                found[resolved.path] = LocalGGUF(path: file.path, name: file.lastPathComponent, size: size.int64Value, repository: repository)
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }
}
