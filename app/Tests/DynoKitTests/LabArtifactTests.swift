import XCTest
@testable import DynoKit
final class LabArtifactTests: XCTestCase {
    func testGraphRejectsDanglingAndDuplicateNodes() throws {
        func data(_ nodes: String, _ edges: String) -> Data { Data("{\"kind\":\"graph\",\"model\":\"test\",\"source\":\"test\",\"note\":\"\",\"nodes\":\(nodes),\"edges\":\(edges)}".utf8) }
        let nodes = "[{\"id\":\"a\",\"label\":\"A\"}]"
        XCTAssertNoThrow(try LabArtifact.read(data(nodes,"[]")))
        XCTAssertThrowsError(try LabArtifact.read(data(nodes,"[{\"source\":\"a\",\"target\":\"missing\",\"weight\":1}]")))
        XCTAssertThrowsError(try LabArtifact.read(data("[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"a\",\"label\":\"B\"}]","[]")))
    }
    func testAttentionShape() {
        let valid = "{\"kind\":\"attention\",\"model\":\"test\",\"source\":\"test\",\"note\":\"\",\"tokens\":[\"a\"],\"values\":[[1]]}"
        XCTAssertNoThrow(try LabArtifact.read(Data(valid.utf8)))
        XCTAssertThrowsError(try LabArtifact.read(Data(valid.replacingOccurrences(of:"[[1]]",with:"[[1,0]]").utf8)))
        XCTAssertThrowsError(try LabArtifact.read(Data(valid.replacingOccurrences(of:"[[1]]",with:"[[2]]").utf8)))
    }
}
