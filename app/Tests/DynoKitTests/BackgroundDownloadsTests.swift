import XCTest
@testable import DynoKit

final class BackgroundDownloadsTests: XCTestCase {
    func testBackgroundProgressAndStaleWriter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("example.json")
        try Data(#"{"repository":"example/model","state":"downloading","updated_at":1000,"downloaded_bytes":20,"total_bytes":100}"#.utf8).write(to: file)
        let fresh = try XCTUnwrap(BackgroundDownloads.read(directory: folder, now: Date(timeIntervalSince1970: 1005)).values.first)
        XCTAssertEqual(fresh.fraction, 0.2)
        XCTAssertTrue(fresh.isExternal)
        XCTAssertFalse(fresh.isStale)
        XCTAssertFalse(fresh.isFinished)
        XCTAssertTrue(try XCTUnwrap(BackgroundDownloads.read(directory: folder, now: Date(timeIntervalSince1970: 1020)).values.first).isStale)
        try Data(#"{"repository":"example/model","state":"complete","updated_at":1000,"downloaded_bytes":100,"total_bytes":100}"#.utf8).write(to: file)
        let done = try XCTUnwrap(BackgroundDownloads.read(directory: folder, now: Date(timeIntervalSince1970: 2000)).values.first)
        XCTAssertTrue(done.isFinished)
        XCTAssertFalse(done.isStale)
        try Data("bad json".utf8).write(to: file)
        XCTAssertTrue(BackgroundDownloads.read(directory: folder).isEmpty)
    }
}
