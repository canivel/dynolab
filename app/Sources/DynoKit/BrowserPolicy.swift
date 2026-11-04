import Darwin
import Foundation

/// What a model may do in Dyno's browser. The user picks it in Browser; read-only unless they choose another.
public enum BrowserMode: String, CaseIterable, Identifiable, Sendable {
    case readOnly = "read"
    case ask = "ask"
    case full = "full"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .ask: return "Ask before submitting"
        case .full: return "Full control"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly: return "The model opens pages, reads them, scrolls and follows links. It can't type or press buttons."
        case .ask: return "The model can also type and press buttons. Before it submits a form or presses anything that sends, buys, posts or deletes, Dyno asks you."
        case .full: return "The model types and presses buttons without asking. You can watch, pause it or take over at any time."
        }
    }

    /// The line the model reads with every page, so it knows what it may try.
    public var forModel: String {
        switch self {
        case .readOnly: return "Browser mode: read only. You can open pages, read, scroll, go back and click links, but not type or press buttons."
        case .ask: return "Browser mode: ask before submitting. You can type and click; the user approves anything that submits, sends, buys, posts or deletes."
        case .full: return "Browser mode: full control. You can type and click."
        }
    }
}

/// An element on the page, as the browser's page script describes it.
public struct BrowserElement: Equatable, Sendable {
    public enum Kind: String, Sendable { case link, button, submit, field, password, payment, choice }
    public var kind: Kind
    public var label: String
    public var href: String?
    public var inForm: Bool

    public init(kind: Kind, label: String, href: String? = nil, inForm: Bool = false) {
        self.kind = kind; self.label = label; self.href = href; self.inForm = inForm
    }
}

public enum BrowserDecision: Equatable, Sendable {
    case allow
    case ask(String)      // what to ask the user
    case refuse(String)   // what to tell the model
}

public enum BrowserPolicy {
    /// Words on a button that usually mean it changes something, not just shows more.
    static let consequential = ["buy", "order", "pay", "checkout", "check out", "purchase", "send", "post", "publish",
                                "delete", "remove", "confirm", "subscribe", "sign up", "register", "book", "reserve",
                                "transfer", "submit", "place", "donate", "apply", "share", "upload", "save",
                                "agree", "continue to payment", "log out", "sign out", "cancel subscription"]

    static let readOnlyRefusal = "The browser is in read-only mode: you can open pages, read, scroll and follow links, but not type or press buttons. If this step is needed, tell the user; they can change the mode in Dyno's Browser."
    static let secretRefusal = "The model never types passwords or card details. Ask the user to click into the page and enter them, then continue."

    public static func click(_ element: BrowserElement, mode: BrowserMode, host: String) -> BrowserDecision {
        if element.kind == .link, let href = element.href, href.hasPrefix("http://") || href.hasPrefix("https://") { return .allow }
        switch mode {
        case .readOnly: return .refuse(readOnlyRefusal)
        case .full: return .allow
        case .ask:
            let label = element.label.isEmpty ? "an unlabeled \(element.kind.rawValue)" : "“\(element.label)”"
            if element.kind == .submit || (element.kind == .button && element.inForm) || isConsequential(element.label) {
                return .ask("The model wants to press \(label) on \(host).")
            }
            return .allow
        }
    }

    public static func type(into element: BrowserElement, submit: Bool, mode: BrowserMode, host: String) -> BrowserDecision {
        if element.kind == .password || element.kind == .payment { return .refuse(secretRefusal) }
        guard element.kind == .field else { return .refuse("Element \(element.label.isEmpty ? "" : "“\(element.label)” ")is a \(element.kind.rawValue), not a text field.") }
        switch mode {
        case .readOnly: return .refuse(readOnlyRefusal)
        case .full: return .allow
        case .ask:
            let label = element.label.isEmpty ? "a field" : "“\(element.label)”"
            return submit ? .ask("The model wants to fill in \(label) on \(host) and submit it.") : .allow
        }
    }

    static func isConsequential(_ label: String) -> Bool {
        let words = label.lowercased()
        return consequential.contains { phrase in
            words.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
        }
    }

    /// Only public web pages: never this Mac, the local network or link-local addresses, whatever the name resolves to.
    public static func publicAddressProblem(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Only http and https pages can be opened."
        }
        guard let host = url.host, !host.isEmpty else { return "That address has no host." }
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".internal") {
            return "\(host) is on this Mac or the local network; only public web pages can be opened."
        }
        let addresses = resolve(name)
        if addresses.isEmpty { return "\(host) could not be found." }
        if addresses.contains(where: { !isPublic($0) }) {
            return "\(host) is a local or private address; only public web pages can be opened."
        }
        return nil
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return out
    }

    /// A numeric IPv4 or IPv6 address that is on the public internet.
    public static func isPublic(_ address: String) -> Bool {
        let plain = address.split(separator: "%").first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return isPublicV4(b)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, plain, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicV4(Array(b[12..<16])) }  // ::ffff:a.b.c.d
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1) { return false }               // :: and ::1
        if b[0] & 0xfe == 0xfc { return false }                    // fc00::/7 unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }    // fe80::/10 link-local
        if b[0] == 0xff { return false }                           // multicast
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }  // documentation
        return true
    }

    static func isPublicV4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
        case (172, 16...31), (100, 64...127), (198, 18...19): return false
        case (224...239, _), (240...254, _): return false
        case (192, 0) where b[2] == 0 || b[2] == 2: return false
        default: return true
        }
    }
}
