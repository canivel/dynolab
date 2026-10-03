import SwiftUI

/// A forum-style view of what agents said and did: one thread per episode, each agent a
/// participant, plus a live feed of activity across every episode.
struct ConversationsView: View {
    var lab: ResearchLab
    var onError: (String) -> Void
    @State private var threads: [[String:Any]] = []
    @State private var feed: [[String:Any]] = []
    @State private var feedLast = 0
    @State private var selected: String? = ConversationsView.all
    @State private var filter = ""
    @State private var showEvaluationInFeed = false
    static let all = "__all_activity__"

    var body: some View {
        HSplitView {
            VStack(alignment:.leading,spacing:8) {
                TextField("Filter threads by task, model or outcome",text:$filter).textFieldStyle(.roundedBorder)
                List(selection:$selected) {
                    Label("All activity",systemImage:"dot.radiowaves.left.and.right").tag(Optional(ConversationsView.all))
                    Section("Threads") {
                        ForEach(Array(visibleThreads.enumerated()),id:\.offset) { _,t in
                            ThreadRow(thread:t).tag(Optional(t["key"] as? String ?? ""))
                        }
                    }
                }
            }.frame(minWidth:300,idealWidth:340,maxWidth:440)
            Group {
                if let selected,selected != ConversationsView.all {
                    ConversationThread(lab:lab,key:selected,onError:onError,onBack:{ self.selected=ConversationsView.all }).id(selected)
                } else { activityFeed }
            }.frame(minWidth:560,maxWidth:.infinity)
        }
        .task {
            while !Task.isCancelled {
                do {
                    threads=try await lab.request("/sandbox/threads?limit=300",timeout:15)["threads"] as? [[String:Any]] ?? []
                    let page=try await lab.request("/sandbox/feed?after=\(feedLast)&limit=200",timeout:15)
                    let items=page["items"] as? [[String:Any]] ?? []
                    if !items.isEmpty { feed=Array((items+feed).prefix(400));feedLast=page["last"] as? Int ?? feedLast }
                } catch { onError(error.localizedDescription) }
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }

    private var visibleThreads: [[String:Any]] {
        let q=filter.lowercased().trimmingCharacters(in:.whitespaces)
        guard !q.isEmpty else { return threads }
        return threads.filter { t in ["task_id","model_id","outcome","episode_id"].contains { (t[$0] as? String ?? "").lowercased().contains(q) } }
    }

    private var activityFeed: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("All activity").font(.headline)
                    Text("What agents said and ran in every episode, newest first. Select one to open its thread.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Include evaluation events",isOn:$showEvaluationInFeed).toggleStyle(.switch).controlSize(.small)
                    .help("Tripwires are recorded by the harness and never shown to the agent.")
            }
            if feed.isEmpty { Text("No agent activity yet.").foregroundStyle(.secondary).padding(.top) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:6) {
                    ForEach(Array(feed.filter { showEvaluationInFeed || $0["event"] as? String != "tripwire" }.enumerated()),id:\.offset) { _,item in
                        Button { selected=item["key"] as? String } label: { FeedItem(item:item) }.buttonStyle(.plain)
                    }
                }
            }
        }.padding()
    }
}

/// Stable colour per agent id, so the same agent looks the same in every thread.
enum AgentColor {
    static let palette: [Color] = [DynoBrand.accent, DynoBrand.violet, .cyan, .pink, .yellow, .mint]
    static func of(_ agent: String?) -> Color {
        let a=agent ?? "agent-0"
        return palette[abs(a.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % palette.count]
    }
}

private struct AgentAvatar: View {
    var agent: String?
    var body: some View {
        let a=agent ?? "agent"
        Text(String(a.split(separator:"-").last ?? "?").prefix(2).uppercased())
            .font(.caption.bold()).frame(width:28,height:28)
            .background(Circle().fill(AgentColor.of(agent).opacity(0.25))).foregroundStyle(AgentColor.of(agent))
    }
}

private struct ThreadRow: View {
    var thread: [String:Any]
    var body: some View {
        let trips=thread["tripwires"] as? Int ?? 0,severe=thread["severe"] as? Int ?? 0
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Text(thread["task_id"] as? String ?? "episode").font(.callout.bold()).lineLimit(1)
                Spacer()
                if trips > 0 { Text("⚠ \(trips)").font(.caption.bold()).foregroundStyle(severe > 0 ? .red : .orange) }
            }
            HStack(spacing:4) {
                ForEach(thread["agents"] as? [String] ?? [],id:\.self) { a in Circle().fill(AgentColor.of(a)).frame(width:7,height:7) }
                Text("\(thread["messages"] as? Int ?? 0) messages · \(thread["commands"] as? Int ?? 0) commands").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(thread["outcome"] as? String ?? thread["status"] as? String ?? "running") · \(thread["model_id"] as? String ?? "")").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(.vertical,3)
    }
}

private struct FeedItem: View {
    var item: [String:Any]
    var body: some View {
        let kind=item["event"] as? String ?? ""
        HStack(alignment:.top,spacing:10) {
            AgentAvatar(agent:item["agent"] as? String)
            VStack(alignment:.leading,spacing:3) {
                Text("\(item["agent"] as? String ?? "agent") · \(label(kind)) · \(item["task_id"] as? String ?? "") · step \(item["step"] as? Int ?? 0)")
                    .font(.caption.bold()).foregroundStyle(kind == "tripwire" ? (item["severity"] as? String == "severe" ? .red : .orange) : .secondary)
                Text(String(display(kind).prefix(400))).font(kind == "tool_call" ? .system(.caption,design:.monospaced) : .callout).lineLimit(5).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius:8).fill(kind == "tripwire" ? Color.orange.opacity(0.12) : DynoBrand.surface))
    }
    /// The index stores a tool call as "tool\n{json args}"; show it as the command that ran.
    private func display(_ kind: String) -> String {
        let text=(item["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard kind == "tool_call",let newline=text.firstIndex(of:"\n") else { return text }
        let tool=String(text[..<newline]),json=String(text[text.index(after:newline)...])
        guard let data=json.data(using:.utf8),let args=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return text }
        if let command=args["command"] as? String { return "$ " + command }
        if let path=args["path"] as? String { return "\(tool) \(path)" }
        return tool
    }
    private func label(_ kind: String) -> String {
        ["model":"said","tool_call":"ran","tripwire":"tripwire","start":"task","end":"finished","nudge":"nudged"][kind] ?? kind
    }
}

/// One episode as a conversation. The left column is only what the agent saw and did;
/// the right column is the evaluation, which is recorded outside the agent's context.
struct ConversationThread: View {
    var lab: ResearchLab
    var key: String
    var onError: (String) -> Void
    var onBack: () -> Void
    @State private var events: [[String:Any]] = []
    @State private var last = 0
    @State private var info: [String:Any] = [:]
    @State private var agentFilter = ""
    @State private var inlineMarkers = false
    @State private var jump: Int?
    private var agents: [String] { Array(Set(events.compactMap { $0["agent_id"] as? String })).sorted() }
    private var conversation: [(Int,[String:Any])] {
        Array(events.enumerated()).filter { _,e in
            let kind=e["event"] as? String ?? ""
            if kind == "tripwire" && !inlineMarkers { return false }
            return agentFilter.isEmpty || e["agent_id"] as? String == agentFilter || kind == "start"
        }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Button { onBack() } label: { Label("All activity",systemImage:"chevron.left") }.buttonStyle(.link)
                Spacer()
                if agents.count > 1 {
                    Picker("Agent",selection:$agentFilter) { Text("Everyone").tag("");ForEach(agents,id:\.self) { Text($0).tag($0) } }.frame(width:200)
                }
                Toggle("Evaluation markers inline",isOn:$inlineMarkers).toggleStyle(.switch).controlSize(.small)
            }
            HStack(alignment:.firstTextBaseline) {
                Text(info["task_id"] as? String ?? "Thread").font(.headline)
                Text("\(info["model_id"] as? String ?? "") · \(info["condition"] as? String ?? "neutral")").font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                VStack(alignment:.leading,spacing:4) {
                    Label("Conversation · exactly what the agent saw and did",systemImage:"bubble.left.and.bubble.right").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:10) {
                                ForEach(conversation,id:\.0) { n,e in Post(event:e).id(n) }
                            }.padding(.vertical,4)
                        }
                        .onChange(of:events.count) { _,c in if c > 0 && jump == nil { proxy.scrollTo(c-1,anchor:.bottom) } }
                        .onChange(of:jump) { _,target in if let target { withAnimation { proxy.scrollTo(target,anchor:.center) } } }
                    }
                }.frame(minWidth:420)
                EvaluationColumn(lab:lab,info:info,events:events,onError:onError) { step in
                    jump=events.firstIndex { ($0["step"] as? Int) == step && $0["event"] as? String == "tool_call" }
                }.frame(minWidth:300,idealWidth:360,maxWidth:460)
            }
        }.padding()
        .task {
            while !Task.isCancelled {
                do {
                    info=try await lab.request("/sandbox/episodes/\(key)",timeout:10)
                    let page=try await lab.request("/sandbox/episodes/\(key)/events?after=\(last)",timeout:10)
                    let new=page["events"] as? [[String:Any]] ?? []
                    if !new.isEmpty { events+=new;last=page["last"] as? Int ?? last }
                    if new.isEmpty && !((info["label"] as? [String:Any]) ?? [:]).isEmpty { break }
                } catch { onError(error.localizedDescription) }
                try? await Task.sleep(for:.seconds(1.5))
            }
        }
    }
}

/// Everything the harness and evaluators recorded about an episode. None of it is ever
/// sent to the agent: the model only receives the system prompt, the task, tool
/// definitions and tool output.
private struct EvaluationColumn: View {
    var lab: ResearchLab
    var info: [String:Any]
    var events: [[String:Any]]
    var onError: (String) -> Void
    var onJump: (Int) -> Void
    @State private var evaluations: [[String:Any]] = []
    private var label: [String:Any] { info["label"] as? [String:Any] ?? [:] }

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Label("Evaluation · hidden from the agent",systemImage:"eye.slash").font(.caption.bold()).foregroundStyle(DynoBrand.violet)
                Text("Recorded by the harness and evaluators outside the agent's context. Nothing here is ever sent to the model.").font(.caption).foregroundStyle(.secondary)
                section("Outcome") {
                    if label.isEmpty { Text("Episode still running").foregroundStyle(.secondary) }
                    else {
                        Text(label["outcome"] as? String ?? "").font(.title3.bold())
                        Text("Claimed success: \(label["claimed_success"] as? Bool == true ? "yes" : "no") · ended by \(label["end_reason"] as? String ?? "")").font(.caption)
                        if label["needs_review"] as? Bool == true {
                            ForEach(label["review_reasons"] as? [String] ?? [],id:\.self) { Label($0,systemImage:"person.fill.questionmark").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                section("Tripwires") {
                    let trips=tripwires
                    if trips.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(Array(trips.enumerated()),id:\.offset) { _,t in
                        Button { if let s=t["step"] as? Int { onJump(s) } } label: {
                            VStack(alignment:.leading,spacing:2) {
                                Text("\(t["type"] as? String ?? "") · \(t["severity"] as? String ?? "")\((t["step"] as? Int).map { " · step \($0)" } ?? "")").font(.caption.bold()).foregroundStyle(t["severity"] as? String == "severe" ? .red : .orange)
                                Text(t["evidence"] as? String ?? "").font(.system(.caption2,design:.monospaced)).lineLimit(3)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.buttonStyle(.plain)
                    }
                }
                if let checks=label["checks"] as? [String:Any] {
                    section("Honest-outcome checks") {
                        if let m=checks["report_matched"] as? Bool { Label("Report states the expected reason: \(m ? "yes" : "no")",systemImage:m ? "checkmark.circle" : "xmark.circle").font(.caption) }
                        ForEach(Array((checks["state_checks"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,c in
                            Label("\(c["name"] as? String ?? ""): \(c["passed"] as? Bool == true ? "passed" : "failed")",systemImage:c["passed"] as? Bool == true ? "checkmark.circle" : "xmark.circle").font(.caption)
                        }
                    }
                }
                section("Monitors") {
                    if evaluations.isEmpty { Text("No monitor has scored this episode. Configure monitors in Evaluate → Evaluators.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(evaluations.enumerated()),id:\.offset) { _,e in
                        VStack(alignment:.leading,spacing:2) {
                            HStack {
                                Text(e["monitor_name"] as? String ?? "monitor").font(.caption.bold())
                                Spacer()
                                if let score=e["score"] as? Int { Text("\(score)/100").font(.caption.monospacedDigit().bold()).foregroundStyle(e["flagged"] as? Bool == true ? .red : DynoBrand.accent) }
                                else { Text(e["status"] as? String ?? "").font(.caption) }
                            }
                            if let r=e["rationale"] as? String { Text(r).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let err=e["error"] as? String { Text(err).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                section("Hand review") {
                    let history=(info["review"] as? [String:Any])?["history"] as? [[String:Any]] ?? []
                    if history.isEmpty { Text("Not reviewed yet. Review it in Evaluate → Review.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(history.enumerated()),id:\.offset) { _,h in
                        Text("\(h["verdict"] as? String ?? "")\((h["corrected_outcome"] as? String).map { " → \($0)" } ?? "") \(h["note"] as? String ?? "")").font(.caption)
                    }
                }
            }.padding(12)
        }
        .background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.violet.opacity(0.06)))
        .task(id:info["key"] as? String) {
            guard let key=info["key"] as? String else { return }
            while !Task.isCancelled {
                if let r=try? await lab.request("/sandbox/episodes/\(key)/evaluations",timeout:10) { evaluations=r["evaluations"] as? [[String:Any]] ?? [] }
                try? await Task.sleep(for:.seconds(4))
            }
        }
    }
    /// Live tripwires from the log, plus the end-of-episode ones (file changes) from the label.
    private var tripwires: [[String:Any]] {
        var out=events.filter { $0["event"] as? String == "tripwire" }
        out+=(label["tripwires"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == "protected_file_changed" }
        return out
    }
    private func section<Content: View>(_ title: String,@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:4) { Text(title).font(.callout.bold());content() }
    }
}

private struct Post: View {
    var event: [String:Any]
    @State private var expanded = false
    private var kind: String { event["event"] as? String ?? "" }
    var body: some View {
        switch kind {
        case "start":
            VStack(alignment:.leading,spacing:4) {
                Text("Task posted by the harness").font(.caption.bold()).foregroundStyle(.secondary)
                Text(event["prompt"] as? String ?? "").font(.callout)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:10).stroke(DynoBrand.accent.opacity(0.4)))
        case "tripwire":
            Label("\(event["agent_id"] as? String ?? "agent") tripped \(event["type"] as? String ?? "") (\(event["severity"] as? String ?? "")): \(event["evidence"] as? String ?? "")",systemImage:"exclamationmark.triangle.fill")
                .font(.system(.caption,design:.monospaced)).foregroundStyle(event["severity"] as? String == "severe" ? .red : .orange)
                .padding(8).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(Color.orange.opacity(0.12)))
        case "tool_result":
            DisclosureGroup("output · exit \(event["exit_code"] as? Int ?? -1)") {
                Text(String(((event["stdout"] as? String ?? "") + (event["stderr"] as? String ?? "")).prefix(6000))).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            }.font(.caption).padding(.leading,38)
        default:
            HStack(alignment:.top,spacing:10) {
                AgentAvatar(agent:event["agent_id"] as? String)
                VStack(alignment:.leading,spacing:4) {
                    Text("\(event["agent_id"] as? String ?? "agent") · step \(event["step"] as? Int ?? 0)").font(.caption.bold()).foregroundStyle(AgentColor.of(event["agent_id"] as? String))
                    content
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface))
            }
        }
    }
    @ViewBuilder private var content: some View {
        switch kind {
        case "model":
            if let r=event["reasoning"] as? String,!r.isEmpty {
                let long=r.count > 400
                Text(long && !expanded ? String(r.prefix(400)) + "…" : r).italic().foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
                if long { Button(expanded ? "Show less" : "Show full thinking") { expanded.toggle() }.buttonStyle(.link).font(.caption) }
            }
            if let c=event["content"] as? String,!c.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { Text(c).textSelection(.enabled) }
        case "tool_call":
            let args=event["args"] as? [String:Any] ?? [:]
            Text(args["command"].map { "$ \($0)" } ?? (event["tool"] as? String ?? "") + " " + ResearchLab.pretty(args))
                .font(.system(.callout,design:.monospaced)).textSelection(.enabled)
        case "end":
            Text("Finished: \(event["final_action"] as? String ?? event["end_reason"] as? String ?? "")").font(.callout.bold())
            if let a=event["final_args"] as? [String:Any] { Text(ResearchLab.pretty(a)).font(.caption).textSelection(.enabled) }
        default:
            Text(event["content"] as? String ?? event["error"] as? String ?? kind).font(.caption).foregroundStyle(.secondary)
        }
    }
}
