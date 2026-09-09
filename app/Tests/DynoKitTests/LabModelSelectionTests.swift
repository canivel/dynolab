import XCTest
@testable import DynoKit

final class LabModelSelectionTests: XCTestCase {
    func testExactRevisionAndAmbiguousNames() {
        let first = LocalModel(path: "/cache/models--org--qwen/snapshots/aaa", name: "org/qwen", sizeBytes: 100, source: "test")
        let second = LocalModel(path: "/cache/models--org--qwen/snapshots/bbb", name: "org/qwen", sizeBytes: 100, source: "test")
        XCTAssertEqual(LabModelSelection.match(first.path, in: [first, second]), first)
        XCTAssertEqual(LabModelSelection.match("org/qwen", in: [first]), first)
        XCTAssertNil(LabModelSelection.match("org/qwen", in: [first, second]))
        XCTAssertNil(LabModelSelection.match("default_model", in: [first]))
        XCTAssertNil(LabModelSelection.match("/cache/models--org--qwen/snapshots/ccc", in: [first]))
    }
}
