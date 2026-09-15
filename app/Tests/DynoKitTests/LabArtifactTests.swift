import XCTest
@testable import DynoKit
final class LabArtifactTests: XCTestCase {
    func testGenerationRequiresAlignedPhasesAndHonestStatus() throws {
        var value: [String: Any] = ["kind":"generation", "model":"test", "source":"test", "note":"Replay",
            "tokens":["question", "reason", "answer"], "tokenPhases":["prompt", "thinking", "answer"],
            "values":[[1.0,2.0,3.0]], "layerIndices":[32], "captureMode":"Teacher-forced replay",
            "generationStatus":"complete", "thinking":"reason", "answer":"answer"]
        func parse() throws { _ = try LabArtifact.read(JSONSerialization.data(withJSONObject:value)) }
        XCTAssertNoThrow(try parse())
        value["generationStatus"]="incomplete"
        XCTAssertThrowsError(try parse())
        value.removeValue(forKey:"answer")
        XCTAssertNoThrow(try parse())
        value["tokenPhases"]=["prompt"]
        XCTAssertThrowsError(try parse())
        value["tokenPhases"]=["prompt", "thinking", "answer"]
        value["values"]=[[1.0, -2.0, 3.0]]
        XCTAssertThrowsError(try parse())
    }
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
