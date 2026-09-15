import XCTest
@testable import DynoKit
final class ResearchStreamTests: XCTestCase {
    func testThinkingAnswerUsageAndFinish() throws {
        var stream = ResearchStream()
        try stream.consume(#"data: {"choices":[{"delta":{"reasoning":"Checking"}}]}"#)
        XCTAssertEqual(stream.text.thinking, "Checking")
        XCTAssertEqual(stream.text.answer, "")
        XCTAssertNil(stream.finishReason)
        try stream.consume(#"data: {"choices":[{"delta":{"content":"Answer"}}]}"#)
        try stream.consume(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":2}}"#)
        try stream.consume("data: [DONE]")
        XCTAssertTrue(stream.done)
        XCTAssertEqual(stream.finishReason, "stop")
        XCTAssertEqual(stream.text.answer, "Answer")
        XCTAssertNotNil(stream.response["usage"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: stream.response))
    }
    func testInterruptedThinkingAndMalformedStreamPreservePartialEvidence() throws {
        var stream = ResearchStream()
        try stream.consume(#"data: {"choices":[{"delta":{"content":"<think>Checking"}}]}"#)
        XCTAssertEqual(stream.text.thinking, "Checking")
        XCTAssertEqual(stream.text.answer, "")
        XCTAssertNil(stream.finishReason)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: stream.response))
        XCTAssertThrowsError(try stream.consume("data: invalid"))
        XCTAssertEqual(stream.content, "<think>Checking")
        XCTAssertThrowsError(try stream.consume(#"data: {"error":{"message":"failed"}}"#))
        XCTAssertEqual(stream.chunks.count, 2)
    }
}
