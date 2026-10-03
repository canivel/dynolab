import SwiftUI

/// A forum-style view of what agents said and did: one thread per episode, each agent a
/// participant, plus a live feed of activity across every episode.
struct ConversationsView: View {
    var lab: ResearchLab
    var onError: (String) -> Void
    @State private var threads: [[String:Any]] = []
    @State private var feed: [[String:Any]] = []
    @State private var feedLast = 0
    @State private var selected: String?          // nil = all activity
    @State private var filter = ""

    var body: some View {
        HSplitView {
            VStack(alignment:.leading,spacing:8) {
                TextField("Filter threads by task, model or outcome",text:$filter).textFieldStyle(.roundedBorder)
                List(selection:$selected) {
                    Label("All activity",systemImage:"dot.radiowaves.left.and.right").tag(Optional<String>.none)
                    Section("Threads") {
                        ForEach(Array(visibleThreads.enumerated()),id:\.offset) { _,t in
                            ThreadRow(thread:t).tag(Optional(t["key"] as? String ?? ""))
                        }
                    }
                }
            }.frame(minWidth:300,idealWidth:340,maxWidth:440)
            Group {
                if let selected { ConversationThread(lab:lab,key:selected,onError:onError).id(selected) }
                else { activityFeed }
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
            Text("All activity").font(.headline)
            Text("The latest messages, commands and tripwires from every episode, newest first. Select one to open its thread.").font(.caption).foregroundStyle(.secondary)
            if feed.isEmpty { Text("No agent activity yet.").foregroundStyle(.secondary).padding(.top) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:6) {
                    ForEach(Array(feed.enumerated()),id:\.offset) { _,item in
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

/// One episode as a conversation: the task as the opening post, then each agent's
/// thinking, replies, commands and results in order, with tripwires inline.
struct ConversationThread: View {
    var lab: ResearchLab
    var key: String
    var onError: (String) -> Void
    @State private var events: [[String:Any]] = []
    @State private var last = 0
    @State private var info: [String:Any] = [:]
    @State private var agentFilter = ""
    private var agents: [String] { Array(Set(events.compactMap { $0["agent_id"] as? String })).sorted() }

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                VStack(alignment:.leading) {
                    Text(info["task_id"] as? String ?? "Thread").font(.headline)
                    Text("\(info["model_id"] as? String ?? "") · \(((info["label"] as? [String:Any])?["outcome"] as? String) ?? "running")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if agents.count > 1 {
                    Picker("Agent",selection:$agentFilter) { Text("Everyone").tag("");ForEach(agents,id:\.self) { Text($0).tag($0) } }.frame(width:200)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:10) {
                        ForEach(Array(events.enumerated()),id:\.offset) { n,e in
                            if agentFilter.isEmpty || e["agent_id"] as? String == agentFilter || e["event"] as? String == "start" { Post(event:e).id(n) }
                        }
                    }.padding(.vertical,4)
                }.onChange(of:events.count) { _,c in if c > 0 { proxy.scrollTo(c-1,anchor:.bottom) } }
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
