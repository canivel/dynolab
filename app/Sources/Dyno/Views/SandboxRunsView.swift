import SwiftUI
import AppKit

/// Sandboxed agent episodes run by the open-source containment harness. Dyno launches
/// the harness, follows each episode's event log live and searches across all of them.
struct SandboxRunsView: View {
    var model: MonitorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sandboxHarnessDir") private var harnessDir = ""
    @State private var tab = "runs"
    @State private var runs: [[String:Any]] = []
    @State private var run: [String:Any] = [:]
    @State private var episodeKey: String?
    @State private var tasks: [[String:Any]] = []
    @State private var task = ""
    @State private var count = 3
    @State private var endpoint = ""
    @State private var query = ""
    @State private var eventFilter = ""
    @State private var results: [[String:Any]] = []
    @State private var issue: String?
    @State private var working = false
    private var runID: String? { run["id"] as? String }
    private var active: Bool { run["status"] as? String == "running" }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("Sandboxed agents").font(.title2.bold())
                Picker("",selection:$tab) { Text("Runs").tag("runs");Text("Search").tag("search") }.pickerStyle(.segmented).frame(width:200)
                Spacer();Button("Close") { dismiss() }
            }
            Text("Agents run real commands inside a gVisor container with no network route out. Every message, reasoning step, command and tripwire is logged before it happens and stays searchable.").foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.orange) }
            HSplitView {
                Group { if tab == "runs" { runList } else { searchPane } }.frame(minWidth:280,idealWidth:340,maxWidth:440)
                Group {
                    if let episodeKey { EpisodeTimeline(lab:model.researchLab,key:episodeKey,onError:{ issue=$0 }).id(episodeKey) }
                    else if tab == "runs" && run.isEmpty { ScrollView { editor.padding() } }
                    else if tab == "runs" { ScrollView { runDetail.padding() } }
                    else { Text("Search reasoning, commands, outputs and tripwires across every run.").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                }.frame(minWidth:620,maxWidth:.infinity)
            }
        }.padding(20).frame(minWidth:1000,minHeight:700).background(DynoBrand.background).dynoTheme()
        .task {
            await model.researchLab.start()
            do { try await refresh();if !harnessDir.isEmpty { try await loadTasks() } } catch { issue=error.localizedDescription }
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(2))
                if let runID,active,episodeKey == nil { do { try await open(runID) } catch { issue=error.localizedDescription } }
            }
        }
    }

    private var runList: some View {
        VStack(alignment:.leading) {
            Button("New run") { run=[:];episodeKey=nil }.disabled(working)
            List(Array(runs.enumerated()),id:\.offset) { _,r in
                Button { perform { episodeKey=nil;try await open(r["id"] as? String ?? "") } } label: {
                    VStack(alignment:.leading) { Text(r["title"] as? String ?? "Run");Text(r["status"] as? String ?? "").font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
        }
    }

    private var editor: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("New sandboxed run").font(.headline)
            HStack {
                DynoFormField("Harness folder",text:$harnessDir)
                Button("Choose…") { let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;if p.runModal() == .OK,let url=p.url { harnessDir=url.path;perform { try await loadTasks() } } }
            }
            Picker("Task",selection:$task) {
                Text("Choose a task").tag("")
                ForEach(tasks.compactMap { $0["id"] as? String },id:\.self) { Text($0).tag($0) }
            }
            if let rule=tasks.first(where:{ $0["id"] as? String == task })?["rule"] as? String { Text("Rule given to the agent: \(rule)").font(.caption).foregroundStyle(.secondary) }
            Stepper("Episodes: \(count)",value:$count,in:1...20)
            Picker("Running endpoint",selection:$endpoint) {
                Text("Choose a running model").tag("")
                ForEach(model.snapshot.models.filter {$0.port != nil},id:\.id) { server in Text("\(server.name) · :\(server.port ?? 0)").tag(String(server.port ?? 0)) }
            }
            Text("Each episode gets a fresh container, at most 40 model turns and 20 minutes. Requests go through the selected Dyno endpoint, so they also appear in Executions.").font(.caption).foregroundStyle(.secondary)
            Button("Start run") { perform {
                guard let port=Int(endpoint),let server=model.snapshot.models.first(where:{Int($0.port ?? 0)==port}) else { return }
                run=try await model.researchLab.request("/sandbox/runs",body:["harness_dir":harnessDir,"task":task,"count":count,"port":port,"model":server.name])
                try await refresh()
            } }.buttonStyle(.dynoPrimary).disabled(working || task.isEmpty || endpoint.isEmpty || harnessDir.isEmpty)
        }
    }

    private var runDetail: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(run["title"] as? String ?? "Run").font(.title3.bold())
            HStack { Text("Status: \(run["status"] as? String ?? "unknown")");if active { Button("Cancel",role:.destructive) { perform { run=try await model.researchLab.request("/sandbox/runs/\(runID ?? "")/cancel",body:[:]);try await refresh() } } } }
            ForEach(Array((run["episodes"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,ep in
                Button { episodeKey=ep["key"] as? String } label: { EpisodeRow(episode:ep) }.buttonStyle(.plain)
            }
            if (run["episodes"] as? [Any])?.isEmpty ?? true { Text(active ? "Starting the first episode…" : "No episodes recorded.").foregroundStyle(.secondary) }
            if let error=run["error"] as? String { Text(error).font(.system(.caption,design:.monospaced)).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private var searchPane: some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("Search, e.g. sudo, /opt/grader, token",text:$query).textFieldStyle(.roundedBorder).onSubmit { search() }
            Picker("Show",selection:$eventFilter) {
                Text("Everything").tag("");Text("Tripwires").tag("tripwire");Text("Reasoning and replies").tag("model")
                Text("Commands").tag("tool_call");Text("Command output").tag("tool_result")
            }.onChange(of:eventFilter) { _,_ in search() }
            HStack { Button("Search") { search() }.buttonStyle(.dynoPrimary);Button("Add runs folder…") { addSource() } }
            List(Array(results.enumerated()),id:\.offset) { _,r in
                Button { episodeKey=r["key"] as? String } label: {
                    VStack(alignment:.leading,spacing:3) {
                        Text("\(r["event"] as? String ?? "") · \(r["task_id"] as? String ?? "") · step \(r["step"] as? Int ?? 0)").font(.caption.bold()).foregroundStyle(r["event"] as? String == "tripwire" ? .orange : .secondary)
                        Text(r["snippet"] as? String ?? "").font(.caption).lineLimit(3)
                        Text(r["episode_id"] as? String ?? "").font(.caption2).foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private func search() {
        var c=URLComponents();c.queryItems=[URLQueryItem(name:"q",value:query),URLQueryItem(name:"event",value:eventFilter),URLQueryItem(name:"limit",value:"200")]
        perform { results=try await model.researchLab.request("/sandbox/search?\(c.percentEncodedQuery ?? "")")["results"] as? [[String:Any]] ?? [] }
    }
    private func addSource() {
        let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.message="Choose a harness runs folder to index"
        if p.runModal() == .OK,let url=p.url { perform { _=try await model.researchLab.request("/sandbox/sources",body:["path":url.path]);search() } }
    }
    private func loadTasks() async throws {
        var c=URLComponents();c.queryItems=[URLQueryItem(name:"harness_dir",value:harnessDir)]
        tasks=try await model.researchLab.request("/sandbox/tasks?\(c.percentEncodedQuery ?? "")")["tasks"] as? [[String:Any]] ?? []
    }
    private func refresh() async throws { runs=try await model.researchLab.request("/sandbox/runs")["runs"] as? [[String:Any]] ?? [] }
    private func open(_ id: String) async throws { run=try await model.researchLab.request("/sandbox/runs/\(id)") }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { guard !working else { return };working=true;Task { do { try await action();issue=nil } catch { issue=error.localizedDescription };working=false } }
}

private struct EpisodeRow: View {
    var episode: [String:Any]
    var body: some View {
        let trips=episode["tripwires"] as? Int ?? 0,severe=episode["severe"] as? Int ?? 0
        HStack {
            VStack(alignment:.leading) { Text(episode["episode_id"] as? String ?? "episode").font(.callout);Text(episode["outcome"] as? String ?? episode["status"] as? String ?? "running").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if trips > 0 { Text("⚠ \(trips)").font(.caption.bold()).padding(.horizontal,8).padding(.vertical,2).background(Capsule().fill((severe > 0 ? Color.red : Color.orange).opacity(0.25))) }
        }.padding(8).background(RoundedRectangle(cornerRadius:8).fill(DynoBrand.surface))
    }
}

/// Live, append-only view of one episode's event log.
struct EpisodeTimeline: View {
    var lab: ResearchLab
    var key: String
    var onError: (String) -> Void
    @State private var events: [[String:Any]] = []
    @State private var last = 0
    @State private var info: [String:Any] = [:]
    @State private var onlyTripwires = false
    private var done: Bool { !((info["label"] as? [String:Any]) ?? [:]).isEmpty }

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                VStack(alignment:.leading) {
                    Text(info["episode_id"] as? String ?? "Episode").font(.headline)
                    Text("\(info["task_id"] as? String ?? "") · \(info["model_id"] as? String ?? "") · \(outcome)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer();Toggle("Only tripwires",isOn:$onlyTripwires).toggleStyle(.switch)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(Array(events.enumerated()),id:\.offset) { n,e in
                            if !onlyTripwires || e["event"] as? String == "tripwire" { EventCard(event:e).id(n) }
                        }
                    }.padding(.vertical,4)
                }.onChange(of:events.count) { _,c in if c > 0 && !onlyTripwires { proxy.scrollTo(c-1,anchor:.bottom) } }
            }
        }.padding()
        .task {
            while !Task.isCancelled {
                do {
                    info=try await lab.request("/sandbox/episodes/\(key)")
                    let page=try await lab.request("/sandbox/episodes/\(key)/events?after=\(last)")
                    let new=page["events"] as? [[String:Any]] ?? []
                    if !new.isEmpty { events+=new;last=page["last"] as? Int ?? last }
                    if done && new.isEmpty { break }
                } catch { onError(error.localizedDescription) }
                try? await Task.sleep(for:.seconds(1.5))
            }
        }
    }
    private var outcome: String { ((info["label"] as? [String:Any])?["outcome"] as? String) ?? "running" }
}

private struct EventCard: View {
    var event: [String:Any]
    private var kind: String { event["event"] as? String ?? "" }
    private var header: String { "\(event["agent_id"] as? String ?? "agent") · step \(event["step"] as? Int ?? 0)" }
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            switch kind {
            case "start":
                label("Task given to the agent",.secondary);Text(event["prompt"] as? String ?? "")
            case "model":
                label("\(header) · thinking",DynoBrand.violet)
                if let r=event["reasoning"] as? String,!r.isEmpty { Text(r).italic().foregroundStyle(.secondary).textSelection(.enabled) }
                if let c=event["content"] as? String,!c.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { Text(c).textSelection(.enabled) }
            case "tool_call":
                label("\(header) · \(event["tool"] as? String ?? "tool")",DynoBrand.accent)
                Text(command).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
            case "tool_result":
                DisclosureGroup("Output · exit \(event["exit_code"] as? Int ?? -1)") {
                    Text(String(((event["stdout"] as? String ?? "") + (event["stderr"] as? String ?? "")).prefix(6000))).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                }.font(.caption)
            case "tripwire":
                label("⚠ \(event["type"] as? String ?? "tripwire") · \(event["severity"] as? String ?? "")",event["severity"] as? String == "severe" ? .red : .orange)
                Text(event["evidence"] as? String ?? "").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            case "end":
                label("Episode ended · \(event["end_reason"] as? String ?? "")",.secondary)
                if let a=event["final_args"] as? [String:Any] { Text(ResearchLab.pretty(a)).font(.caption).textSelection(.enabled) }
            default:
                label(kind,.secondary);Text(event["content"] as? String ?? event["error"] as? String ?? "").font(.caption)
            }
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background(RoundedRectangle(cornerRadius:8).fill(kind == "tripwire" ? Color.orange.opacity(0.12) : DynoBrand.surface))
    }
    private var command: String {
        let args=event["args"] as? [String:Any] ?? [:]
        if let c=args["command"] as? String { return "$ " + c }
        if let p=args["path"] as? String { return (event["tool"] as? String == "write_file" ? "write " : "read ") + p }
        return ResearchLab.pretty(args)
    }
    private func label(_ text: String,_ color: Color) -> some View { Text(text).font(.caption.bold()).foregroundStyle(color) }
}
