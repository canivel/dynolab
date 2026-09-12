import XCTest
@testable import DynoKit

final class PoolTelemetryTests: XCTestCase {
    func testMetalFailureDoesNotShowReadyOrSuccessfulCompletion() {
        var state = PoolTelemetry()
        state.consume(#"{"status":"ready"}"#)
        state.consume("processing task, is_child = 0")
        state.consume("error: Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)")
        state.consume("stop processing: n_tokens = 5")
        XCTAssertFalse(state.ready)
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.completed, 0)
        XCTAssertNotNil(state.error)
    }
    func testMeasurementsAndLifecycle() {
        var state = PoolTelemetry()
        state.consume(#"{"status":"devices_discovered","free_memory_mib":{"MTL0":10240,"RPC0":20480}}"#)
        XCTAssertEqual(state.freeMiB.values.reduce(0,+), 30720)
        state.consume("0.00 I load_tensors: RPC0[127.0.0.1:53074] model buffer size = 111.62 MiB")
        state.consume("0.00 I load_tensors: MTL0_Mapped model buffer size = 604.15 MiB")
        XCTAssertEqual(state.modelMiB["RPC0"], 111.62)
        XCTAssertEqual(state.modelMiB["MTL0"], 604.15)
        XCTAssertTrue(state.mappedModelDevices.contains("MTL0"))
        XCTAssertFalse(state.mappedModelDevices.contains("RPC0"))
        state.consume(#"{"status":"ready","endpoint":"http://127.0.0.1:8978/v1"}"#)
        state.consume("I slot launch_slot_: processing task, is_child = 0")
        XCTAssertTrue(state.ready); XCTAssertTrue(state.active)
        state.consume("prompt eval time = 102.80 ms / 5 tokens (20.56 ms per token, 48.64 tokens per second)")
        XCTAssertTrue(state.rates.isEmpty)
        state.consume("eval time = 620.86 ms / 32 tokens (20.03 ms per token, 49.93 tokens per second)")
        XCTAssertEqual(state.rates, [49.93])
        state.consume("stop processing: n_tokens = 36")
        XCTAssertFalse(state.active); XCTAssertEqual(state.completed, 1)
        state.consume(#"{"status":"stopped"}"#)
        state.consume(#"{"status":"failed","error":"Worker disconnected"}"#)
        XCTAssertFalse(state.ready); XCTAssertEqual(state.phase, "Needs attention")
        XCTAssertEqual(state.error, "Worker disconnected")
    }
    func testWorkerTelemetryIsSeparateAndDoesNotReplacePoolState() {
        var state = PoolTelemetry()
        state.phase = "Ready"; state.ready = true
        state.consume(#"{"status":"worker_telemetry","stale":false,"sample":{"instance_id":"first","collector_status":"ok","gpus":[{"selected":true,"name":"RTX","utilization_percent":60,"memory_used_bytes":10,"memory_total_bytes":20}]}}"#)
        XCTAssertTrue(state.workerFresh); XCTAssertEqual(state.workerHistory, [60])
        XCTAssertEqual(state.phase, "Ready")
        state.consume(#"{"status":"worker_telemetry","stale":true,"sample":{"instance_id":"first","collector_status":"ok","gpus":[]}}"#)
        XCTAssertFalse(state.workerFresh); XCTAssertTrue(state.workerHistory.isEmpty)
        state.consume(#"{"status":"telemetry_unavailable"}"#)
        XCTAssertTrue(state.ready); XCTAssertEqual(state.workerStatus, "Unavailable")
    }
    func testUnrecognizedLogsCannotInventMeasurements() {
        var state = PoolTelemetry()
        state.consume("hello"); state.consume("{broken"); state.consume("model buffer size = NaN")
        XCTAssertTrue(state.freeMiB.isEmpty); XCTAssertTrue(state.modelMiB.isEmpty); XCTAssertTrue(state.rates.isEmpty)
    }
}
