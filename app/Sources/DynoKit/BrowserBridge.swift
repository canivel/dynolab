import Foundation
import Network

/// How `dyno serve` reaches the app's browser: a small HTTP server on 127.0.0.1, at a port and with a token the app
/// writes to ~/.mlx-dyno/browser.json (readable by this user only). Each request is `POST /browser/<action>` with a
/// JSON body and `Authorization: Bearer <token>`; requests with an `Origin` header (web pages, including pages open
/// in the browser itself) are refused.
public final class BrowserBridge: @unchecked Sendable {
    public typealias Handler = @Sendable (_ action: String, _ body: [String: Any]) async -> [String: Any]

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/browser.json")
    }

    public let token: String
    public let file: URL
    public private(set) var port: UInt16?
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dyno.browser-bridge")
    static let maxBody = 1_000_000

    public init(file: URL = BrowserBridge.defaultFile, handler: @escaping Handler) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        self.file = file
        self.handler = handler
    }

    /// Listen on a free loopback port; returns once the port is known and written to `file`.
    @discardableResult
    public func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case let .failed(error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { listener.cancel(); throw CocoaError(.fileWriteUnknown) }
        if let failure { listener.cancel(); throw failure }
        guard let port = listener.port?.rawValue else { listener.cancel(); throw CocoaError(.fileWriteUnknown) }
        self.listener = listener
        self.port = port
        try writeFile(port: port)
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if let data = try? Data(contentsOf: file),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], info["token"] as? String == token {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func writeFile(port: UInt16) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["port": Int(port), "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        let data = try JSONSerialization.data(withJSONObject: info)
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .incomplete:
                if done || error != nil || buffer.count > Self.maxBody + 16384 { connection.cancel(); return }
                self.receive(connection, buffer: buffer)
            case let .bad(status, message):
                self.reply(connection, status: status, ["ok": false, "error": message])
            case let .request(method, path, headers, body):
                self.handle(connection, method: method, path: path, headers: headers, body: body)
            }
        }
    }

    enum Parsed {
        case incomplete
        case bad(Int, String)
        case request(method: String, path: String, headers: [String: String], body: Data)
    }

    static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .bad(400, "Bad request") }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .bad(400, "Bad request") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maxBody).contains(length) else { return .bad(413, "The request body is too large") }
        let body = buffer[end.upperBound...]
        if body.count < length { return .incomplete }
        return .request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ connection: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        if headers["origin"] != nil { return reply(connection, status: 403, ["ok": false, "error": "Not available to web pages"]) }
        guard headers["authorization"] == "Bearer \(token)" else { return reply(connection, status: 401, ["ok": false, "error": "Wrong or missing token"]) }
        guard path.hasPrefix("/browser/"), method == "POST" || method == "GET" else { return reply(connection, status: 404, ["ok": false, "error": "Not found"]) }
        let action = String(path.dropFirst("/browser/".count).prefix { $0 != "?" })
        let json = body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        let handler = self.handler
        Task {
            let answer = await handler(action, json)
            self.reply(connection, status: 200, answer)
        }
    }

    private func reply(_ connection: NWConnection, status: Int, _ payload: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large"][status] ?? "Error"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
