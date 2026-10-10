import Foundation

/// What to move to the Trash to delete a downloaded model, so the disk space really comes back.
///
/// A Hugging Face cache entry keeps the weights in `models--org--name/blobs` and links to them from
/// `snapshots/<revision>`: deleting only the snapshot folder would leave every byte behind. So an MLX model in the
/// cache goes as its whole `models--org--name` folder. A GGUF file there goes with its blob, or as the whole folder
/// when it is the repository's only model file. Anything else (LM Studio, ~/models, an added folder) is the model's
/// own folder or file. Nothing outside the folders Dyno scans, and never one of those folders itself.
public enum ModelRemoval {
    public enum Failure: LocalizedError, Equatable {
        case outsideLibrary(String), missing(String)
        public var errorDescription: String? {
            switch self {
            case .outsideLibrary(let p): return "Dyno only deletes models inside the folders it scans for models, never those folders themselves or anything else (\(p))."
            case .missing(let p): return "\(p) no longer exists."
            }
        }
    }

    public static func targets(for path: String, roots: [String]) throws -> [URL] {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard manager.fileExists(atPath: url.path) || (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            throw Failure.missing(path)
        }
        let components = url.pathComponents
        var targets: [URL]
        if let i = components.firstIndex(where: { $0.hasPrefix("models--") }), components.count > i + 1, components[i + 1] == "snapshots" {
            let repo = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...i]))).standardizedFileURL
            if url.pathExtension.lowercased() == "gguf" && modelFiles(in: repo.appendingPathComponent("snapshots"), ext: "gguf") > 1 {
                targets = [url]
                let blob = url.resolvingSymlinksInPath().standardizedFileURL
                if blob != url, blob.path.hasPrefix(repo.path + "/") { targets.append(blob) }
            } else {
                targets = [repo]
            }
        } else {
            targets = [url]
        }
        let library = roots.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        for t in targets {
            let real = t.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(t.lastPathComponent).path
            guard library.contains(where: { real.hasPrefix($0 + "/") && real != $0 }) else { throw Failure.outsideLibrary(t.path) }
        }
        return targets
    }

    /// Model files of a kind across a repository's snapshots (links count once per name).
    private static func modelFiles(in snapshots: URL, ext: String) -> Int {
        guard let walker = FileManager.default.enumerator(at: snapshots, includingPropertiesForKeys: nil) else { return 0 }
        var names = Set<String>()
        for case let f as URL in walker where f.pathExtension.lowercased() == ext { names.insert(f.lastPathComponent) }
        return names.count
    }

    /// Moves the targets to the Trash (recoverable until the Trash is emptied). Returns the bytes they held.
    @discardableResult
    public static func trash(_ targets: [URL]) throws -> Int64 {
        var bytes: Int64 = 0
        for t in targets {
            bytes += size(of: t)
            try FileManager.default.trashItem(at: t, resultingItemURL: nil)
        }
        return bytes
    }

    /// Bytes on disk, not following links (a cache's snapshot links point at blobs counted once).
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey, .isRegularFileKey]
        func one(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isRegularFile == true else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return one(url) }
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let f as URL in walker { total += one(f) }
        }
        return total
    }
}
