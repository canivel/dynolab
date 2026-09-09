import Foundation

public enum LabModelSelection {
    /// Prefer an exact path/revision. Repo IDs are accepted only when unambiguous.
    public static func match(_ identifier: String?, in models: [LocalModel]) -> LocalModel? {
        guard let identifier, !identifier.isEmpty, identifier != "default_model" else { return nil }
        if identifier.hasPrefix("/") {
            let path = URL(fileURLWithPath: identifier).resolvingSymlinksInPath().standardizedFileURL.path
            return models.first {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == path
            }
        }
        let matches = models.filter { $0.name == identifier }
        return matches.count == 1 ? matches.first : nil
    }
}
