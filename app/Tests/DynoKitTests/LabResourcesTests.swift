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
        XCTAssertEqual(result.availableBytes!, Int64(50 * GB))
        XCTAssertGreaterThan(result.estimatedBytes, Int64(5 * GB))
    }
    func testLargeModelDoesNotFitAlongsideServing() {
        XCTAssertFalse(LabResources(weightBytes: Int64(40 * GB), memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true).canRun)
    }
    func testOSReserveDoesNotSubtractFromMetalBudgetTwice() {
        var sample = memory()
        sample.used = Int64(110 * GB)
        sample.gpuUsed = Int64(96 * GB)
        let result = LabResources(weightBytes: nil, memory: sample, gpuBusy: 0,
                                  activeRequests: 0, fresh: true, reuseServingModel: true)
        XCTAssertEqual(result.availableBytes, Int64(4 * GB))
        XCTAssertTrue(result.canRun)
        sample.used = Int64(127 * GB)
        XCTAssertFalse(LabResources(weightBytes: nil, memory: sample, gpuBusy: 0,
                                   activeRequests: 0, fresh: true, reuseServingModel: true).canRun)
    }
    func testActiveRequestsBlockButDeviceActiveTimeDoesNot() {
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 1, fresh: true).canRun)
        XCTAssertTrue(LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 100, activeRequests: 0, fresh: true).canRun)
    }
    func testUnknownAndStaleTelemetryCannotClaimReady() {
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: MemorySample(), gpuBusy: 0, activeRequests: 0, fresh: true).canRun)
        XCTAssertFalse(LabResources(weightBytes: nil, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true).canRun)
        XCTAssertFalse(LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: false).canRun)
    }
    func testServingCaptureCountsWorkspaceOnlyAndCanQueueWhileBusy() {
        let result = LabResources(weightBytes: Int64(40 * GB), memory: memory(),
            gpuBusy: 99, activeRequests: 1, fresh: true, reuseServingModel: true)
        XCTAssertTrue(result.canRun)
        XCTAssertLessThan(result.estimatedBytes, Int64(3 * GB))
    }
    func testLongerInputIncreasesWorkspaceEstimate() {
        let short = LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true)
        let long = LabResources(weightBytes: 1000, memory: memory(), gpuBusy: 0, activeRequests: 0, fresh: true, maxInputTokens: 1024)
        XCTAssertGreaterThan(long.estimatedBytes, short.estimatedBytes)
    }
}
