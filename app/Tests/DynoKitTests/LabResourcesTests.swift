import XCTest
@testable import DynoKit

final class LabResourcesTests: XCTestCase {
    private func memory() -> MemorySample {
        var value = MemorySample()
        value.total = Int64(128 * GB); value.used = Int64(64 * GB)
        value.gpuBudget = Int64(100 * GB); value.gpuUsed = Int64(50 * GB)
        return value
    }
    func testIdleHeadroomAdmitsSmallModelAndReservesMemory() {
        let result = LabResources(weightBytes: Int64(5 * GB), memory: memory(), gpuBusy: 1, activeRequests: 0, fresh: true)
        XCTAssertTrue(result.canRun)
        XCTAssertLessThan(result.availableBytes!, Int64(50 * GB))
        XCTAssertGreaterThan(result.estimatedBytes, Int64(5 * GB))
    }
    func testLargeModelDoesNotFitAlongsideServing() {
        XCTAssertFalse(LabResources(weightBytes: Int64(40 * GB), memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true).canRun)
    }
    func testActiveRequestsAndBusyGPUBlockAdmission() {
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 1, fresh: true).canRun)
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 70, activeRequests: 0, fresh: true).canRun)
    }
    func testUnknownAndStaleTelemetryCannotClaimReady() {
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: MemorySample(), gpuBusy: 0, activeRequests: 0, fresh: true).canRun)
        XCTAssertFalse(LabResources(weightBytes: nil, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true).canRun)
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: false).canRun)
    }
    func testLongerInputIncreasesWorkspaceEstimate() {
        let short = LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true)
        let long = LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true, maxInputTokens: 1024)
        XCTAssertGreaterThan(long.estimatedBytes, short.estimatedBytes)
    }
}
