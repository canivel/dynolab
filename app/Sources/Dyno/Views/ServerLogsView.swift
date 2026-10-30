import AppKit
import DynoKit
import SwiftUI

/// Performance → Logs: what a model server is doing right now, and everything it printed.
///
/// The status comes from the server's /stats (`live.requests`: phase and how far it has read the prompt); the log is
/// the file in ~/.mlx-dyno/logs, written by the app for servers it starts and by `dyno launch` for its own.
struct ServerLogsView: View {
    @State private var logs: [ServerLogs.Entry] = []
    @State private var selected: String?
    @State private var text = ""
    @State private var stats: [String: Any]?
    @State private var follow = true
    @State private var requestsOnly = false

    private var entry: ServerLogs.Entry? { logs.first { $0.id == selected } ?? logs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("Server log", selection: Binding(get: { entry?.id ?? "" }, set: { selected = $0 })) {
                    ForEach(logs) { log in
                        Text("\(log.port.map { ":\($0)" } ?? log.url.lastPathComponent) · \(log.source) · \(Self.age(log.modified))").tag(log.id)
                    }
                }.frame(maxWidth: 380)
                Toggle("Requests only", isOn: $requestsOnly).toggleStyle(.checkbox)
                    .help("Show only Dyno's request lines: received, reading the prompt, first token, done")
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).help("Keep scrolled to the newest line")
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown, forType: .string)
                }.disabled(text.isEmpty)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry?.url ?? ServerLogs.directory])
                }
            }
            status
            log
        }
        .padding(16)
        .task { await refresh() }
    }

    private var shown: String {
        guard requestsOnly else { return text }
        return text.split(separator: "\n").filter { ServerLogs.isRequestLine($0) }.joined(separator: "\n")
    }

    // -- status: what the server is doing now ---------------------------------

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry == nil {
                Text("No server logs yet. Start a model in Models, or run `dyno launch`, and its log appears here.")
                    .foregroundStyle(.secondary)
            } else if let stats {
                let live = stats["live"] as? [String: Any] ?? [:]
                let requests = live["requests"] as? [[String: Any]] ?? []
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(serverLine(stats)).font(.callout.weight(.medium))
                }
                if requests.isEmpty {
                    Text(idleLine(stats)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(requests.indices, id: \.self) { index in
                    requestRow(requests[index])
                }
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text("Not answering on :\(entry?.port.map(String.init) ?? "?") · the log below is from its last run")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func requestRow(_ request: [String: Any]) -> some View {
        let toRead = request["prompt_to_read"] as? Int ?? 0
        let read = request["prompt_read"] as? Int ?? 0
        let quiet = request["seconds_since_last_token"] as? Double ?? 0
        let phase = request["phase"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Text(Self.describe(request))
            if phase == "reading" && toRead > 0 {
                ProgressView(value: Double(min(read, toRead)), total: Double(toRead))
            } else if phase == "reading" {
                ProgressView().controlSize(.small)
            } else if phase == "generating" && quiet >= 30 {
                Text("No new token for \(Self.duration(quiet)).").foregroundStyle(.orange)
            }
        }
        .font(.caption).monospacedDigit()
    }

    /// One request's state in words, from /stats `live.requests`.
    static func describe(_ request: [String: Any]) -> String {
        let id = request["request_id"] as? Int ?? 0
        let seconds = duration(request["seconds"] as? Double ?? 0)
        switch request["phase"] as? String {
        case "reading":
            let toRead = request["prompt_to_read"] as? Int ?? 0
            guard toRead > 0 else { return "Request \(id) · preparing (loading the model or the prompt cache) · \(seconds)" }
            let read = request["prompt_read"] as? Int ?? 0
            var parts = ["Request \(id) · reading the prompt", "\(read.formatted()) of \(toRead.formatted()) tokens"]
            if let rate = request["prompt_read_tokens_per_second"] as? Double, rate > 0 {
                parts.append("\(Int(rate)) tok/s")
                if read < toRead { parts.append("about \(duration(Double(toRead - read) / rate)) left") }
            }
            parts.append(seconds)
            return parts.joined(separator: " · ")
        case "generating":
            let tokens = request["completion_tokens"] as? Int ?? 0
            var parts = ["Request \(id) · generating", "\(tokens.formatted()) tokens"]
            if let rate = request["decode_tokens_per_second"] as? Double { parts.append(String(format: "%.1f tok/s", rate)) }
            parts.append(seconds)
            return parts.joined(separator: " · ")
        default:
            return "Request \(id) · waiting for the request before it · \(seconds)"
        }
    }

    private func serverLine(_ stats: [String: Any]) -> String {
        let model = stats["model"] as? [String: Any] ?? [:]
        // mlx_lm calls a model loaded at startup "default_model"; its cache path names it.
        let path = model["path"] as? String ?? ""
        let fromPath = path.range(of: #"models--([^/]+)--([^/]+)"#, options: .regularExpression)
            .map { String(path[$0].dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/") }
        let named = (model["name"] as? String).flatMap { $0 == "default_model" || $0.isEmpty ? nil : $0 }
        let name = named ?? fromPath ?? (path.isEmpty ? "model" : (path as NSString).lastPathComponent)
        var parts = [":\(entry?.port.map(String.init) ?? "?")", name]
        if let mode = stats["mode"] as? String { parts.append(mode == "serve" ? "Serve only" : "Research") }
        let speculative = (stats["speculative"] as? [String: Any])?["mode"] as? String
        parts.append(speculative == "dflash" ? "speculative decoding: DFlash2 draft model"
                     : speculative == "mtp" ? "speculative decoding: MTP head" : "no speculative decoding yet")
        return parts.joined(separator: " · ")
    }

    private func idleLine(_ stats: [String: Any]) -> String {
        let totals = stats["totals"] as? [String: Any] ?? [:]
        let served = totals["requests"] as? Int ?? 0
        guard let last = (stats["recent_requests"] as? [[String: Any]])?.last else { return "Idle · no requests yet" }
        var parts = ["Idle · \(served) request\(served == 1 ? "" : "s") served"]
        if let ttft = last["time_to_first_token"] as? Double { parts.append("last: first token after \(Self.duration(ttft))") }
        if let rate = last["decode_tokens_per_second"] as? Double { parts.append(String(format: "%.1f tok/s", rate)) }
        return parts.joined(separator: " · ")
    }

    // -- the log --------------------------------------------------------------

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(shown.isEmpty ? (entry == nil ? "" : "The log is empty.") : shown)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
            .onChange(of: shown) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // -- refresh --------------------------------------------------------------

    private func refresh() async {
        while !Task.isCancelled {
            let found = await Task.detached { ServerLogs.list() }.value
            if found != logs { logs = found }
            if let entry {
                let url = entry.url
                let latest = await Task.detached { ServerLogs.tail(url) }.value
                if latest != text { text = latest }
                stats = await Self.stats(port: entry.port)
            } else {
                text = ""; stats = nil
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func stats(port: UInt16?) async -> [String: Any]? {
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)/stats") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int(seconds) / 60
        return minutes < 90 ? "\(minutes) min \(Int(seconds) % 60) s" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        return seconds < 10 ? "live" : "updated " + duration(seconds) + " ago"
    }
}
