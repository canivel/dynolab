import XCTest
@testable import DynoKit

final class ServerControllerTests: XCTestCase {
    func testOnlyDynoServeCommandsAreControllable() {
        XCTAssertTrue(ServerController.isDynoServe("/venv/bin/python /venv/bin/dyno serve --model /models/qwen --port 8972"))
        XCTAssertTrue(ServerController.isDynoServe("/python -m dyno serve --model qwen"))
        XCTAssertFalse(ServerController.isDynoServe("/python -m dyno lab serve"))
        XCTAssertFalse(ServerController.isDynoServe("/python -m mlx_lm.server --model qwen"))
        XCTAssertFalse(ServerController.isDynoServe("/Applications/LM Studio"))
        XCTAssertFalse(ServerController.isDynoServe("/python -m dyno router"))
    }

    func testStopRefusesUnrelatedLiveProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        XCTAssertThrowsError(try ServerController.stopDetected(
            pid: child.processIdentifier, port: 8987,
            expectedCommand: "/python -m dyno serve --model qwen"))
        XCTAssertTrue(child.isRunning)
    }
}
