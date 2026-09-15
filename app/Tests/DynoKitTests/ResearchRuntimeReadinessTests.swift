import XCTest
@testable import DynoKit
final class ResearchRuntimeReadinessTests: XCTestCase {
    func testOfflineStaleAndReplacedModelsDoNotUnlockSavedIterations() {
        let now = Date()
        XCTAssertTrue(ResearchRuntimeReadiness.permitsRun(healthy: true, checkedAt: now, now: now, savedModel: "A", currentModel: "A"))
        XCTAssertFalse(ResearchRuntimeReadiness.permitsRun(healthy: false, checkedAt: now, now: now, savedModel: "A", currentModel: "A"))
        XCTAssertFalse(ResearchRuntimeReadiness.permitsRun(healthy: true, checkedAt: now.addingTimeInterval(-11), now: now, savedModel: "A", currentModel: "A"))
        XCTAssertFalse(ResearchRuntimeReadiness.permitsRun(healthy: true, checkedAt: now, now: now, savedModel: "A", currentModel: "B"))
    }
}
