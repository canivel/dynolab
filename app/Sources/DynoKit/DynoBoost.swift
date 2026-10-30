import Foundation

/// Which MLX models `dyno serve` speeds up with speculative decoding ("Dyno Boost").
///
/// Mirrors the server: dense Qwen3.5-and-later models carry a multi-token-prediction head
/// (or have a DFlash2 drafter), named by base model, e.g. "Qwen3.8-27B". Mixture-of-experts
/// builds ("Qwen3.6-35B-A3B") are not supported yet, and the drafter repositories are not
/// models to serve.
public enum DynoBoost {
    public static func supports(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = basePattern.firstMatch(in: name, range: range) else { return false }
        let base = Range(match.range, in: name).map { String(name[$0]) } ?? ""
        if moePattern.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil { return false }
        return name.range(of: "dflash", options: .caseInsensitive) == nil
            && name.range(of: "gguf", options: .caseInsensitive) == nil
    }

    /// A DFlash2 drafter on the hub for this model's base, when there is one. It is not an MLX
    /// repository, so the Discover search never lists it; `dyno serve` finds it in the
    /// Hugging Face cache once downloaded and drafts with it instead of the MTP head.
    public static func drafter(for name: String) -> Drafter? {
        guard supports(name), let base = base(of: name) else { return nil }
        return drafters.first { $0.base.caseInsensitiveCompare(base) == .orderedSame }
    }

    public struct Drafter: Sendable, Hashable {
        public var repository: String
        public var base: String
        public var sizeBytes: Int64
    }

    public static let drafters = [
        Drafter(repository: "z-lab/Qwen3.8-27B-DFlash2", base: "Qwen3.8-27B", sizeBytes: 3_850_000_000),
    ]

    /// True for drafter repositories: they load only next to their base model, so they are not
    /// listed as models to serve.
    public static func isDrafter(_ name: String) -> Bool {
        name.range(of: #"-DFlash\d*(?:$|[-/])"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The downloaded drafter's snapshot, found the way `dflash_spec.find_drafter` does.
    public static func downloadedDrafter(_ drafter: Drafter, hub: String = hubCache) -> String? {
        let manager = FileManager.default
        let entry = (hub as NSString).appendingPathComponent("models--" + drafter.repository.replacingOccurrences(of: "/", with: "--"))
        let snapshots = (entry as NSString).appendingPathComponent("snapshots")
        let revisions = ((try? manager.contentsOfDirectory(atPath: snapshots)) ?? []).sorted()
        for revision in revisions where !revision.hasPrefix(".") {
            let path = (snapshots as NSString).appendingPathComponent(revision)
            let files = (try? manager.contentsOfDirectory(atPath: path)) ?? []
            // fileExists follows the cache link, so a blob that never finished doesn't count.
            let weights = files.filter { $0.hasSuffix(".safetensors") }
            if manager.fileExists(atPath: (path as NSString).appendingPathComponent("config.json")), !weights.isEmpty,
               weights.allSatisfy({ manager.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }) {
                return path
            }
        }
        return nil
    }

    public static var hubCache: String {
        ProcessInfo.processInfo.environment["HF_HUB_CACHE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
    }

    private static func base(of name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        return basePattern.firstMatch(in: name, range: range).flatMap { Range($0.range, in: name) }.map { String(name[$0]) }
    }

    private static let basePattern = try! NSRegularExpression(pattern: #"Qwen3\.\d+-\d+(?:\.\d+)?B(?:-A\d+B)?"#, options: .caseInsensitive)
    private static let moePattern = try! NSRegularExpression(pattern: #"-A\d+B$"#, options: .caseInsensitive)
}
