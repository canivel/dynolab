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

    private static let basePattern = try! NSRegularExpression(pattern: #"Qwen3\.\d+-\d+(?:\.\d+)?B(?:-A\d+B)?"#, options: .caseInsensitive)
    private static let moePattern = try! NSRegularExpression(pattern: #"-A\d+B$"#, options: .caseInsensitive)
}
