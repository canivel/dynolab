import Foundation
import Testing
@testable import DynoKit

struct ServerLogsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func listsServeAndLaunchLogsNewestFirstWithTheirPorts() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let handle = try #require(ServerLogs.create(port: 8971, header: "dyno serve qwen on :8971", in: dir))
        try handle.write(contentsOf: Data("12:00:01 request 1 · received\n".utf8)); try handle.close()
        let launch = dir.appendingPathComponent("launch-8972.log")
        try Data("old\n".utf8).write(to: launch)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: launch.path)
        try Data("x".utf8).write(to: dir.appendingPathComponent("pool-1.log"))
        let logs = ServerLogs.list(in: dir)
        #expect(logs.map(\.port) == [8971, 8972])
        #expect(logs.map(\.source) == ["Dyno app", "dyno launch"])
        let text = ServerLogs.tail(logs[0].url)
        #expect(text.hasPrefix("== ") && text.contains("dyno serve qwen on :8971") && text.contains("request 1 · received"))
    }

    @Test func tailStartsOnAWholeLineAndKeepsTheLastProgressState() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("serve-1.log")
        let lines = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\nFetching 10%\r Fetching 55%\r Fetching 100%\n"
        try Data(lines.utf8).write(to: url)
        let tail = ServerLogs.tail(url, maxBytes: 200)
        #expect(tail.split(separator: "\n").first?.hasPrefix("line ") == true)
        #expect(tail.contains(" Fetching 100%") && !tail.contains("10%"))
        #expect(tail.contains("line 500"))
    }

    @Test func requestLines() {
        #expect(ServerLogs.isRequestLine("12:38:57 request 1 · reading 39,470 new prompt tokens"))
        #expect(!ServerLogs.isRequestLine("Speculative decoding: DFlash2 draft model from /x"))
    }
}
