import DynoKit
import SwiftUI

/// The Room's full log: every turn of every agent, as a conversation. A turn shows what the agent
/// was sent, its thinking, what it said, each command or file with its full output, and the model's
/// tokens and timing. While a model call is still running, its thinking and answer stream in from
/// the model server's execution capture (the same source as the Execution tab).
struct RoomFullLog: View {
    var events: [[String: Any]]
    var agents: [String: [String: Any]]
    var running: Bool
    var port: UInt16?
    @Binding var agentFilter: String
    @State private var live: ExecutionTrace?
    @State private var follow = true

    struct Call: Identifiable { var id: Int; var tool: String; var args: [String: Any]; var result: [String: Any]? }
    struct Step: Identifiable { var id: Int; var model: [String: Any]; var calls: [Call] }
    struct Turn: Identifiable {
        var id: Int; var agent: String; var round: Int?; var ts: String?; var received: String?; var steps: [Step] = []
    }
    enum Block: Identifiable {
        case turn(Turn), note(id: Int, ts: String?, text: String, agent: String?, detail: String?)
        var id: Int { switch self { case .turn(let t): return t.id; case .note(let id, _, _, _, _): return id } }
    }

    /// Turns and the room's own notes, in order.
    private var blocks: [Block] {
        var out: [Block] = []
        var current: Turn?
        func flush() { if let t = current { out.append(.turn(t)); current = nil } }
        for e in events {
            let seq = e["seq"] as? Int ?? 0, agent = e["agent_id"] as? String, ts = e["ts"] as? String
            switch e["event"] as? String {
            case "start":
                for a in e["agents"] as? [[String: Any]] ?? [] {
                    out.append(.note(id: seq * 100 + out.count, ts: ts, text: "\(a["name"] as? String ?? "An agent") joined: system prompt", agent: a["id"] as? String, detail: a["system_prompt"] as? String))
                }
            case "room_update":
                flush()
                current = Turn(id: seq, agent: agent ?? "", round: e["round"] as? Int, ts: ts, received: e["content"] as? String)
            case "model":
                if current == nil || current?.agent != agent { flush(); current = Turn(id: seq, agent: agent ?? "", round: e["round"] as? Int, ts: ts) }
                current?.steps.append(Step(id: seq, model: e, calls: []))
            case "tool_call":
                if current?.steps.isEmpty == false {
                    current!.steps[current!.steps.count - 1].calls.append(Call(id: seq, tool: e["tool"] as? String ?? "", args: e["args"] as? [String: Any] ?? [:]))
                }
            case "tool_result":
                if let s = current?.steps.indices.last, let c = current?.steps[s].calls.lastIndex(where: { $0.result == nil && $0.tool == e["tool"] as? String }) {
                    current!.steps[s].calls[c].result = e
                }
            case "agent_created":
                out.append(.note(id: seq * 100, ts: ts, text: "\(agents[e["created_by"] as? String ?? ""]?["name"] as? String ?? "An agent") created \(e["name"] as? String ?? "an agent"): system prompt", agent: agent, detail: e["system_prompt"] as? String))
            case "user_message":
                let who = (e["name"] as? String ?? "You") + (e["scripted"] as? Bool == true ? " (script)" : "")
                flush(); out.append(.note(id: seq * 100, ts: ts, text: "\(who) wrote: \(e["content"] as? String ?? "")", agent: nil, detail: nil))
            case "waiting": flush(); out.append(.note(id: seq * 100, ts: ts, text: "Final report in. The room waits for a follow-up.", agent: nil, detail: nil))
            case "resumed": out.append(.note(id: seq * 100, ts: ts, text: "Back to work.", agent: nil, detail: nil))
            case "sandbox_crashed": out.append(.note(id: seq * 100, ts: ts, text: "The agents' machine crashed.", agent: nil, detail: e["stderr"] as? String))
            case "sandbox_restarted": out.append(.note(id: seq * 100, ts: ts, text: "The machine restarted from a clean state.", agent: nil, detail: nil))
            case "end": flush(); out.append(.note(id: seq * 100, ts: ts, text: "The room ended: \(e["end_reason"] as? String ?? "")", agent: nil, detail: nil))
            case "error": flush(); out.append(.note(id: seq * 100, ts: ts, text: "Harness error", agent: nil, detail: e["error"] as? String))
            default: break
            }
        }
        flush()
        guard agentFilter != "all" else { return out }
        return out.filter { if case .turn(let t) = $0 { return t.agent == agentFilter }; return true }
    }

    /// The agent whose model call is running now: its turn has started and no answer has come back yet.
    private var waitingOn: String? {
        guard running, let last = events.last(where: { ["room_update", "model", "tool_result", "end", "waiting"].contains($0["event"] as? String ?? "") }) else { return nil }
        switch last["event"] as? String {
        case "room_update", "tool_result": return last["agent_id"] as? String
        default: return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks) { block in
                        switch block {
                        case .turn(let t): TurnCard(turn: t, agent: agents[t.agent]).id(block.id)
                        case .note(let id, let ts, let text, let agent, let detail): NoteRow(ts: ts, text: text, color: agent.flatMap { RoomPalette.color(agents[$0]?["color"] as? String) }, detail: detail).id(id)
                        }
                    }
                    if let who = waitingOn, agentFilter == "all" || agentFilter == who { LiveCard(agent: agents[who], trace: live).id("live") }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(14)
            }
            .onChange(of: events.count) { _, _ in if follow { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
            .onChange(of: live?.events?.last?.updated) { _, _ in if follow { proxy.scrollTo("bottom", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption).padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DynoBrand.surface)).padding(10)
            }
        }
        .task(id: "\(waitingOn ?? "")|\(port ?? 0)") {
            live = nil
            guard waitingOn != nil, let port else { return }
            let client = ExecutionClient()
            let since = Date().timeIntervalSince1970 - 5
            while !Task.isCancelled {
                if let list = try? await client.list(port: port),
                   let trace = list.executions.filter({ $0.isRunning && $0.started >= since - 600 }).max(by: { $0.started < $1.started }),
                   let detail = try? await client.detail(port: port, id: trace.id) {
                    live = detail
                } else if live?.isRunning == true { live = nil }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }
}

// MARK: - Pieces

private struct TurnCard: View {
    var turn: RoomFullLog.Turn
    var agent: [String: Any]?
    @State private var showReceived = false

    var body: some View {
        let color = RoomPalette.color(agent?["color"] as? String), name = agent?["name"] as? String ?? turn.agent
        HStack(alignment: .top, spacing: 10) {
            Text(String(name.split(separator: " ").last?.prefix(1) ?? "?")).font(.caption.bold()).frame(width: 28, height: 28)
                .background(Circle().fill(color)).foregroundStyle(DynoBrand.ink)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.semibold)).foregroundStyle(color)
                    if let role = agent?["role"] as? String, !role.isEmpty { Text(role).font(.caption).foregroundStyle(.secondary) }
                    if let r = turn.round { Text("· round \(r)").font(.caption).foregroundStyle(.secondary) }
                    Text("· \(roomTime(turn.ts))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(totals).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let received = turn.received, !received.isEmpty {
                    DisclosureGroup(isExpanded: $showReceived) {
                        LogText(text: received, mono: false).padding(.top, 4)
                    } label: {
                        Text("Received at the start of the turn" + (showReceived ? "" : ": " + received.replacingOccurrences(of: "\n", with: " ").prefix(110)))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(turn.steps) { step in StepView(step: step, color: color) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.05)))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
        }
    }

    private var totals: String {
        let usage = turn.steps.compactMap { $0.model["usage"] as? [String: Any] }
        let out = usage.compactMap { $0["completion_tokens"] as? Int }.reduce(0, +), inp = usage.compactMap { $0["prompt_tokens"] as? Int }.last
        let calls = turn.steps.reduce(0) { $0 + $1.calls.count }
        return ["\(turn.steps.count) model call\(turn.steps.count == 1 ? "" : "s")", calls > 0 ? "\(calls) tool call\(calls == 1 ? "" : "s")" : nil,
                out > 0 ? "\(out) tokens out" : nil, inp.map { "\($0) in" }].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct StepView: View {
    var step: RoomFullLog.Step
    var color: Color
    @State private var showThinking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = step.model["reasoning"] as? String, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    LogText(text: r, mono: false).foregroundStyle(.secondary).italic().padding(.top, 2)
                } label: { Label("Thinking · private, other agents never see it", systemImage: "brain").font(.caption.weight(.semibold)).foregroundStyle(.purple) }
            }
            if let text = (step.model["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Said to the team").font(.caption2.weight(.semibold)).foregroundStyle(color)
                    LogText(text: text, mono: false)
                }
            }
            ForEach(step.calls) { call in CallView(call: call) }
            if let finish = step.model["finish_reason"] as? String, finish != "stop", finish != "tool_calls" {
                Text("Model stopped: \(finish)").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

private struct CallView: View {
    var call: RoomFullLog.Call

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                if let r = call.result {
                    let code = r["exit_code"] as? Int
                    Text([code.map { "exit \($0)" }, (r["duration_s"] as? Double).map { String(format: "%.1fs", $0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2.monospacedDigit()).foregroundStyle(code == nil || code == 0 ? Color.secondary : .orange)
                } else if !["submit", "report_blocked"].contains(call.tool) { DynoSpinner(size: 9) }
            }.foregroundStyle(.secondary)
            LogText(text: input, mono: true)
            if let extra = extraInput { LogBox(text: extra, label: "content") }
            if let r = call.result {
                let out = (r["stdout"] as? String ?? ""), err = (r["stderr"] as? String ?? "")
                if !out.isEmpty { LogBox(text: out, label: "output") }
                if !err.isEmpty { LogBox(text: err, label: "stderr", warn: true) }
                if out.isEmpty && err.isEmpty { Text("(no output)").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.background)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private var icon: String {
        switch call.tool { case "bash": "terminal"; case "read_file": "doc.text"; case "write_file": "square.and.pencil"
        case "create_agent": "person.badge.plus"; case "submit": "checkmark.seal"; case "report_blocked": "hand.raised"; default: "wrench" }
    }
    private var title: String {
        switch call.tool { case "bash": "Command"; case "read_file": "Read file"; case "write_file": "Wrote file"
        case "create_agent": "Created an agent"; case "submit": "Final report"; case "report_blocked": "Reported blocked"; default: call.tool }
    }
    private var input: String {
        switch call.tool {
        case "bash": "$ " + (call.args["command"] as? String ?? "")
        case "read_file", "write_file": call.args["path"] as? String ?? ""
        case "create_agent": "\(call.args["name"] as? String ?? "") (\(call.args["role"] as? String ?? "")): \(call.args["instructions"] as? String ?? "")"
        default: call.args.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        }
    }
    private var extraInput: String? { call.tool == "write_file" ? call.args["content"] as? String : nil }
}

/// Output that can be long: the first lines, with the rest one click away.
private struct LogBox: View {
    var text: String
    var label: String
    var warn = false
    @State private var expanded = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(warn ? .orange : .secondary)
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if lines.count > 40 { Button(expanded ? "Show less" : "Show all") { expanded.toggle() }.buttonStyle(.link).font(.caption2) }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption2).help("Copy")
            }
            Text(expanded || lines.count <= 40 ? text : lines.prefix(40).joined(separator: "\n") + "\n…")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(warn ? Color.orange : .primary)
                .copyable(text).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}

private struct LogText: View {
    var text: String
    var mono: Bool
    var body: some View {
        Text(text).font(mono ? .system(size: 11.5, design: .monospaced) : .callout).copyable(text)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

private struct NoteRow: View {
    var ts: String?
    var text: String
    var color: Color?
    var detail: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color ?? .secondary).frame(width: 6, height: 6)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text("· \(roomTime(ts))").font(.caption2).foregroundStyle(.tertiary)
                if detail != nil { Button(open ? "Hide" : "Show") { open.toggle() }.buttonStyle(.link).font(.caption2) }
            }
            if open, let detail { LogBox(text: detail, label: "text") }
        }.padding(.leading, 38)
    }
}

/// The model call that is running now, streamed from the model server's execution capture.
private struct LiveCard: View {
    var agent: [String: Any]?
    var trace: ExecutionTrace?

    var body: some View {
        let color = RoomPalette.color(agent?["color"] as? String)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DynoSpinner(size: 12)
                Text("\(agent?["name"] as? String ?? "An agent") is working").font(.callout.weight(.semibold)).foregroundStyle(color)
                if let t = trace {
                    Text(String(format: "· %.0fs · %d tokens so far", Date().timeIntervalSince1970 - t.started, t.outputTokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("live from the model server").font(.caption2).foregroundStyle(.tertiary)
            }
            if let events = trace?.events, !events.isEmpty {
                ForEach(events) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.kind == "thinking" ? "Thinking" : e.kind == "tool" ? "Tool call" : e.kind == "output" ? "Answer" : e.kind.capitalized)
                            .font(.caption2.weight(.semibold)).foregroundStyle(e.kind == "thinking" ? Color.purple : .secondary)
                        Text(e.text).font(.system(size: 11.5, design: e.kind == "tool" ? .monospaced : .default))
                            .foregroundStyle(e.kind == "thinking" ? Color.secondary : .primary).copyable(e.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(trace == nil ? "Waiting for the model. Live text appears here when the model server captures it." : "The model has started; nothing emitted yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
        .padding(.leading, 38)
    }
}
