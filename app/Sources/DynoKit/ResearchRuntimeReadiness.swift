import Foundation

public enum ResearchRuntimeReadiness {
    public static func permitsRun(healthy: Bool, checkedAt: Date, now: Date = Date(), savedModel: String?, currentModel: String) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return healthy && age >= 0 && age < 10 && (savedModel == nil || savedModel == currentModel)
    }
}
