import Foundation
import Testing
@testable import DynoKit

@Suite struct BrowserPolicyTests {
    let link = BrowserElement(kind: .link, label: "Pricing", href: "https://example.com/pricing")
    let more = BrowserElement(kind: .button, label: "Show more")
    let buy = BrowserElement(kind: .button, label: "Buy now")
    let submit = BrowserElement(kind: .submit, label: "Search", inForm: true)
    let field = BrowserElement(kind: .field, label: "Search", inForm: true)

    @Test func readOnlyFollowsLinksButNeverPressesOrTypes() {
        #expect(BrowserPolicy.click(link, mode: .readOnly, host: "example.com") == .allow)
        if case .refuse = BrowserPolicy.click(more, mode: .readOnly, host: "example.com") {} else { Issue.record("a button was pressed") }
        if case .refuse = BrowserPolicy.type(into: field, submit: false, mode: .readOnly, host: "example.com") {} else { Issue.record("typed") }
        // A javascript: link is a button in disguise.
        let script = BrowserElement(kind: .link, label: "Delete", href: "javascript:del()")
        if case .refuse = BrowserPolicy.click(script, mode: .readOnly, host: "x") {} else { Issue.record("javascript link") }
    }

    @Test func askModeAsksBeforeAnythingThatSubmitsSendsOrBuys() {
        #expect(BrowserPolicy.click(more, mode: .ask, host: "example.com") == .allow)
        #expect(BrowserPolicy.click(buy, mode: .ask, host: "shop.example") == .ask("The model wants to press “Buy now” on shop.example."))
        if case .ask = BrowserPolicy.click(submit, mode: .ask, host: "x") {} else { Issue.record("submit without asking") }
        if case .ask = BrowserPolicy.click(BrowserElement(kind: .button, label: "Next", inForm: true), mode: .ask, host: "x") {} else { Issue.record("form button") }
        #expect(BrowserPolicy.type(into: field, submit: false, mode: .ask, host: "x") == .allow)
        if case .ask = BrowserPolicy.type(into: field, submit: true, mode: .ask, host: "x") {} else { Issue.record("submitted without asking") }
        // Words inside other words don't count: "Postcode" is not "post".
        #expect(BrowserPolicy.click(BrowserElement(kind: .button, label: "Postcode lookup"), mode: .ask, host: "x") == .allow)
    }

    @Test func fullControlDoesEverythingButPasswordsAndCards() {
        #expect(BrowserPolicy.click(buy, mode: .full, host: "x") == .allow)
        #expect(BrowserPolicy.type(into: field, submit: true, mode: .full, host: "x") == .allow)
        for kind in [BrowserElement.Kind.password, .payment] {
            if case .refuse = BrowserPolicy.type(into: BrowserElement(kind: kind, label: "x"), submit: false, mode: .full, host: "x") {} else { Issue.record("typed a secret") }
        }
    }

    @Test func onlyPublicAddresses() {
        for address in ["127.0.0.1", "10.1.2.3", "192.168.86.112", "172.20.0.1", "169.254.1.1", "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fd00::1", "::ffff:192.168.1.1"] {
            #expect(!BrowserPolicy.isPublic(address), "\(address)")
        }
        for address in ["8.8.8.8", "140.82.112.3", "2606:4700::1111"] { #expect(BrowserPolicy.isPublic(address), "\(address)") }
        for url in ["http://localhost:8971/v1/models", "http://127.0.0.1:8970/", "http://printer.local/", "file:///etc/passwd", "http://[::1]:8973/"] {
            #expect(BrowserPolicy.publicAddressProblem(URL(string: url)!) != nil, "\(url)")
        }
    }

    @Test func everyModeTellsTheModelWhatItMayDo() {
        #expect(BrowserMode(rawValue: "read") == .readOnly)
        for mode in BrowserMode.allCases { #expect(!mode.forModel.isEmpty && !mode.detail.isEmpty) }
    }
}

@Suite struct BrowserBridgeTests {
    func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dyno-browser-\(UUID().uuidString).json") }

    func post(_ port: UInt16, _ action: String, token: String?, origin: String? = nil, body: [String: Any] = [:]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/browser/\(action)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    @Test func answersOnlyWithTheTokenAndNeverAWebPage() async throws {
        let path = file()
        let bridge = BrowserBridge(file: path) { action, body in ["ok": true, "action": action, "url": body["url"] as? String ?? ""] }
        let port = try bridge.start()
        defer { bridge.stop() }
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        #expect(written["port"] as? Int == Int(port))
        #expect(written["token"] as? String == bridge.token)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let (status, answer) = try await post(port, "open", token: bridge.token, body: ["url": "https://example.com"])
        #expect(status == 200 && answer["action"] as? String == "open" && answer["url"] as? String == "https://example.com")
        #expect(try await post(port, "open", token: "wrong").0 == 401)
        #expect(try await post(port, "open", token: nil).0 == 401)
        #expect(try await post(port, "open", token: bridge.token, origin: "https://evil.example").0 == 403)
        bridge.stop()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func parsesRequestsThatArriveInPieces() {
        let head = "POST /browser/read HTTP/1.1\r\nContent-Length: 2\r\nAuthorization: Bearer t\r\n\r\n"
        if case .incomplete = BrowserBridge.parse(Data(head.utf8)) {} else { Issue.record("body not awaited") }
        guard case let .request(method, path, headers, body) = BrowserBridge.parse(Data((head + "{}").utf8)) else { Issue.record("not parsed"); return }
        #expect(method == "POST" && path == "/browser/read" && headers["authorization"] == "Bearer t" && body == Data("{}".utf8))
        if case .bad(413, _) = BrowserBridge.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) {} else { Issue.record("huge body") }
    }
}
