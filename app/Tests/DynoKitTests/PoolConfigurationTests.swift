import XCTest
@testable import DynoKit

final class PoolConfigurationTests: XCTestCase {
    func testSelectingWorkerPreservesModelAndRuntime() throws {
        let initial = #"{"binary":"/runtime/llama-server","model":"/models/test.gguf","context":4096,"alias":"research","port":8978,"peer":"192.168.40.2","pairing_id":"old"}"#
        let connection = Data(#"{"peer":"192.168.40.20","local_address":"192.168.40.10","user":"worker","ssh_port":22,"rpc_port":50052,"pairing_id":"new","name":"Untrusted label","binary":"/untrusted"}"#.utf8)
        let output = try PoolConfiguration.merging(connection: connection, into: initial)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["binary"] as? String, "/runtime/llama-server")
        XCTAssertEqual(parsed["model"] as? String, "/models/test.gguf")
        XCTAssertEqual(parsed["context"] as? Int, 4096)
        XCTAssertEqual(parsed["port"] as? Int, 8978)
        XCTAssertEqual(parsed["pairing_id"] as? String, "new")
        XCTAssertEqual(parsed["peer"] as? String, "192.168.40.20")
        XCTAssertNil(parsed["name"])
    }
    func testIncompleteTrustCannotBeMerged() {
        XCTAssertThrowsError(try PoolConfiguration.merging(connection: Data(#"{"peer":"192.168.40.20"}"#.utf8), into: "{}"))
    }
}
