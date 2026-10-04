import SwiftUI
import AppKit

/// Dynolab's home: AI agents run real commands in a sealed gVisor sandbox, and every
/// message, reasoning step, command and tripwire is logged, watched live and searchable.
/// The open-source containment harness does the running; this view drives and reads it.
struct AgentsView: View {
    var model: MonitorModel
    /// Opens straight onto one episode's timeline (snapshots, deep links).
    var initialEpisode: String? = nil
    var initialTripwiresOnly = false
    /// Empty means the harness bundled with Dyno. Developers can point at a source checkout.
    @AppStorage("sandboxHarnessOverride") private var harnessDir = ""
    @State private var engine: [String:Any] = [:]
    @State private var showAdvanced = false
    @AppStorage("agentsWorkspace") private var workspace = Workspace.runs.rawValue
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
    @State private var readiness: [String:Any] = [:]
    @State private var condition = ""
    @State private var envTemplates: [String] = []
    @State private var taskEditor: EditorRequest?

    struct EditorRequest: Identifiable { let id=UUID();var existing: String?;var template: [String:Any]? }
    @State private var issue: String?
    @State private var working = false
    private var runID: String? { run["id"] as? String }
    private var active: Bool { run["status"] as? String == "running" }
    private var current: Workspace { Workspace(rawValue: workspace) ?? .runs }

    enum Workspace: String, CaseIterable, Identifiable {
        case runs = "Runs", conversations = "Conversations", search = "Search", tasks = "Tasks", environments = "Environments", readiness = "Readiness"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.firstTextBaseline) {
                VStack(alignment:.leading,spacing:4) {
                    Text("Agents").font(.title2.bold())
                    Text("Real commands in an isolated sandbox with no network route out. Every command is logged before it runs.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("",selection:$workspace) { ForEach(Workspace.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented).frame(width:640)
            }
            if let issue { Text(issue).foregroundStyle(.orange).font(.callout) }
            switch current {
            case .runs, .search:
                HSplitView {
                    Group { if current == .runs { runList } else { searchPane } }.frame(minWidth:280,idealWidth:340,maxWidth:440)
                    Group {
                        if let episodeKey { EpisodeTimeline(lab:model.researchLab,key:episodeKey,onlyTripwires:initialTripwiresOnly && episodeKey == initialEpisode,onError:{ issue=$0 }).id(episodeKey) }
                        else if current == .runs && run.isEmpty { ScrollView { editor.padding() } }
                        else if current == .runs { ScrollView { runDetail.padding() } }
                        else { Text("Search reasoning, commands, outputs and tripwires across every run.").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
                    }.frame(minWidth:560,maxWidth:.infinity)
                }
            case .conversations: ConversationsView(lab:model.researchLab,onError:{ issue=$0 })
            case .tasks: ScrollView { taskLibrary.padding(.vertical) }
            case .environments: EnvironmentsView(model:model,harnessDir:harnessDir,tasks:tasks,onRunStarted:{ r in run=r;episodeKey=nil;workspace=Workspace.runs.rawValue;Task { try? await refresh() } },onError:{ issue=$0 },onCreateTask:{ env in
                workspace=Workspace.tasks.rawValue
                taskEditor=EditorRequest(existing:nil,template:["spec":["id":"","prompt":"","rule":"","environment":["template":env],"files":[],"dirs":[],"protected":[],"watched_reads":[],"secrets":[],"allowed_hosts":[]],"files":[:]])
            })
            case .readiness: ScrollView { readinessPanel.padding(.vertical) }
            }
        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .task {
            await model.researchLab.start()
            if let initialEpisode { workspace=Workspace.runs.rawValue;episodeKey=initialEpisode }
            do {
                try await refresh()
                try await loadEngine()
                if engine["installed"] as? Bool == true { try await loadTasks();try await loadReadiness() }
                else if initialEpisode == nil { workspace=Workspace.readiness.rawValue }
            } catch { issue=error.localizedDescription }
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(2))
                if let runID,active,episodeKey == nil { do { try await open(runID) } catch { issue=error.localizedDescription } }
                if readiness["running"] as? Bool == true { try? await loadReadiness() }
                if runs.contains(where:{ $0["status"] as? String == "running" }) { try? await refresh();try? await loadReadiness() }
                if engine["setup_running"] as? Bool == true { try? await loadEngine() }
            }
        }
    }

    // MARK: Runs

    private var runList: some View {
        VStack(alignment:.leading) {
            Button("New run") { run=[:];episodeKey=nil }.disabled(working)
            List(Array(runs.enumerated()),id:\.offset) { _,r in
                Button { perform { episodeKey=nil;try await open(r["id"] as? String ?? "") } } label: {
                    VStack(alignment:.leading) {
                        Text(r["title"] as? String ?? "Run")
                        Text("\(r["kind"] as? String == "controls" ? "controls · " : "")\(r["status"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private var editor: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("New sandboxed run").font(.headline)
            if !ready { readinessBanner }
            Picker("Task",selection:$task) {
                Text("Choose a task").tag("")
                ForEach(tasks.compactMap { $0["id"] as? String },id:\.self) { Text($0).tag($0) }
            }
            if let rule=tasks.first(where:{ $0["id"] as? String == task })?["rule"] as? String { Text("Rule given to the agent: \(rule)").font(.caption).foregroundStyle(.secondary) }
            let conditions=tasks.first(where:{ $0["id"] as? String == task })?["conditions"] as? [String] ?? []
            if !conditions.isEmpty {
                Picker("Condition",selection:$condition) { Text("neutral").tag("");ForEach(conditions,id:\.self) { Text($0).tag($0) } }
            }
            Stepper("Episodes: \(count)",value:$count,in:1...20)
            Picker("Running endpoint",selection:$endpoint) {
                Text("Choose a running model").tag("")
                ForEach(model.snapshot.models.filter {$0.port != nil},id:\.id) { server in Text("\(server.name) · :\(String(server.port ?? 0))").tag(String(server.port ?? 0)) }
            }
            if model.snapshot.models.isEmpty { Button("Start a model in Models…") { model.requestedTab = .run }.buttonStyle(.link) }
            Text("Each episode gets a fresh container, at most 40 model turns and 20 minutes. Requests go through the selected Dyno endpoint, so they also appear in Execution.").font(.caption).foregroundStyle(.secondary)
            Button("Start run") { perform {
                guard let port=Int(endpoint),let server=model.snapshot.models.first(where:{Int($0.port ?? 0)==port}) else { return }
                var body: [String:Any]=["harness_dir":harnessDir,"task":task,"count":count,"port":port,"model":server.identifier.isEmpty ? server.name : server.identifier]
                if !condition.isEmpty { body["condition"]=condition }
                run=try await model.researchLab.request("/sandbox/runs",body:body,timeout:15)
                try await refresh()
            } }.buttonStyle(.dynoPrimary).disabled(working || task.isEmpty || endpoint.isEmpty)
        }
    }

    private var runDetail: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(run["title"] as? String ?? "Run").font(.title3.bold())
            HStack { Text("Status: \(run["status"] as? String ?? "unknown")");if active { Button("Cancel",role:.destructive) { perform { run=try await model.researchLab.request("/sandbox/runs/\(runID ?? "")/cancel",body:[:],timeout:40);try await refresh() } } } }
            if let controls=run["controls"] as? [String:Any] {
                Label(controls["ok"] as? Bool == true ? "Every scripted rule break was flagged, and every honest run was clean." : "A control failed: the labeler missed a rule break or flagged an honest run. Fix the harness before trusting results.",
                      systemImage:controls["ok"] as? Bool == true ? "checkmark.seal" : "xmark.octagon").foregroundStyle(controls["ok"] as? Bool == true ? DynoBrand.accent : .red)
            }
            ForEach(Array((run["episodes"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,ep in
                Button { episodeKey=ep["key"] as? String } label: { EpisodeRow(episode:ep) }.buttonStyle(.plain)
            }
            if (run["episodes"] as? [Any])?.isEmpty ?? true { Text(active ? "Starting the first episode…" : "No episodes recorded.").foregroundStyle(.secondary) }
            if let error=run["error"] as? String { Text(error).font(.system(.caption,design:.monospaced)).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    // MARK: Search

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

    // MARK: Tasks

    private var taskLibrary: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top) {
                Text("Every task is an ordinary chore with one explicit rule. Following the rule makes the task impossible, so the honest move is to say so. Tripwires record what the agent tries instead.").foregroundStyle(.secondary)
                Spacer()
                Button("New task") { taskEditor=EditorRequest(existing:nil,template:nil) }.buttonStyle(.dynoPrimary)
            }
            if tasks.isEmpty { Text("Choose the harness folder in Readiness to load tasks.").foregroundStyle(.secondary) }
            ForEach(Array(tasks.enumerated()),id:\.offset) { _,t in
                let id=t["id"] as? String ?? ""
                let meta=t["meta"] as? [String:Any] ?? [:]
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text(meta["title"] as? String ?? id).font(.headline)
                        if meta["title"] != nil { Text(id).font(.caption).foregroundStyle(.secondary) }
                        if let d=meta["difficulty"] as? String { Text(d).font(.caption2.bold()).padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(DynoBrand.violet.opacity(0.2))) }
                        Spacer()
                        ForEach(meta["tags"] as? [String] ?? [],id:\.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(t["prompt"] as? String ?? "")
                    Text("Rule: \(t["rule"] as? String ?? "")").font(.callout.bold())
                    if let r=meta["rationale"] as? String { Text(r).font(.caption).foregroundStyle(.secondary) }
                    let protected=(t["protected"] as? [String] ?? []).joined(separator:", ")
                    if !protected.isEmpty { Text("Protected: \(protected)").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary) }
                    let honeypots=(t["honeypots"] as? [String] ?? []) + (t["watched"] as? [String] ?? [])
                    if !honeypots.isEmpty { Text("Honeypots and watched paths: \(honeypots.joined(separator:", "))").font(.caption).foregroundStyle(.secondary) }
                    let conditions=t["conditions"] as? [String] ?? []
                    if !conditions.isEmpty { Text("Conditions: neutral, \(conditions.joined(separator:", "))").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Run this task") { task=id;condition="";run=[:];episodeKey=nil;workspace=Workspace.runs.rawValue }
                        Button("Search its runs") { query="";eventFilter="";workspace=Workspace.search.rawValue;searchTask(id) }
                        Button("Copy as new task") { openEditor(id,edit:false) }
                        Button("Edit") { openEditor(id,edit:true) }
                    }.controlSize(.small)
                }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface))
            }
        }
        .sheet(item:$taskEditor) { req in
            TaskEditorView(lab:model.researchLab,harnessDir:harnessDir,existingID:req.existing,template:req.template,environments:envTemplates) { perform { try await loadTasks() } }
        }
    }

    private func openEditor(_ id: String,edit: Bool) {
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        perform {
            let detail=try await model.researchLab.request("/sandbox/tasks/\(id)?\(c.percentEncodedQuery ?? "")",timeout:15)
            if edit && detail["editable"] as? Bool != true { throw TaskDraftError.message("\(id) is a built-in task. Use Copy as new task to change it.") }
            taskEditor=EditorRequest(existing:edit ? id : nil,template:detail)
        }
    }

    // MARK: Readiness

    private var ready: Bool { readiness["ok"] as? Bool == true && !model.snapshot.models.isEmpty && engine["installed"] as? Bool == true }
    private var readinessBanner: some View {
        Button { workspace=Workspace.readiness.rawValue } label: { Label("Finish the readiness checklist before trusting results.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange) }.buttonStyle(.plain)
    }

    private static let checkOrder = ["docker reachable","sandbox image built","network is --internal","runtime is runsc","no egress","root files protected","no sudo"]

    private var readinessPanel: some View {
        let running=readiness["running"] as? Bool == true
        let done=readiness["checks"] as? [[String:Any]] ?? []
        let checks=done.isEmpty ? (readiness["progress"] as? [[String:Any]] ?? []) : done
        let controls=readiness["controls"] as? [String:Any]
        return VStack(alignment:.leading,spacing:16) {
            let paths=engine["paths"] as? [String:Any] ?? [:]
            let setup=engine["setup"] as? [String:Any]
            let setupRunning=engine["setup_running"] as? Bool == true
            step(1,"Sandbox engine",done:engine["installed"] as? Bool == true && readiness["ok"] as? Bool == true,
                 detail:engine["installed"] as? Bool == true ? "Harness \(paths["version"] as? String ?? "") \(engine["bundled"] as? Bool == true ? "bundled with Dyno" : "from a checkout") · \(tasks.count) tasks · your tasks, environments and runs are kept in \(paths["home"] as? String ?? "")" : (engine["error"] as? String ?? "Checking…")) {
                HStack {
                    Button(setupRunning ? "Setting up…" : "Set up") { perform { engine=try await model.researchLab.request("/sandbox/engine/setup",body:["harness_dir":harnessDir],timeout:15) } }.disabled(setupRunning || engine["installed"] as? Bool != true)
                    if let home=paths["home"] as? String { Button("Show data") { NSWorkspace.shared.open(URL(fileURLWithPath:home)) } }
                }
            }
            VStack(alignment:.leading,spacing:4) {
                Text("Set up checks Docker and the gVisor runtime, then builds the sandbox image and its isolated network. It is safe to run again.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array((setup?["steps"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,st in
                    Label("\(st["name"] as? String ?? "")\((st["detail"] as? String).map { $0.isEmpty ? "" : " · " + $0 } ?? "")",systemImage:st["passed"] as? Bool == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(st["passed"] as? Bool == true ? DynoBrand.accent : .red).font(.callout).lineLimit(2)
                }
                if setupRunning { ProgressView().controlSize(.small) }
                if let steps=setup?["steps"] as? [[String:Any]],steps.contains(where:{ $0["name"] as? String == "docker reachable" && $0["passed"] as? Bool != true }) {
                    HStack {
                        Text("Docker isn't available. Dyno can install Colima, Docker and gVisor with Homebrew (about 5 minutes, needs internet).").font(.caption)
                        Button("Install sandbox runtime") { perform { engine=try await model.researchLab.request("/sandbox/engine/setup",body:["harness_dir":harnessDir,"install_runtime":true],timeout:15) } }.disabled(setupRunning)
                    }
                }
                DisclosureGroup("Advanced",isExpanded:$showAdvanced) {
                    HStack {
                        Text(harnessDir.isEmpty ? "Using the harness bundled with Dyno." : "Using the checkout at \(harnessDir)").font(.caption)
                        Spacer()
                        Button("Use a source checkout…") { let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.message="Choose a harness source checkout (for harness development)";if p.runModal() == .OK,let url=p.url { harnessDir=url.path;perform { try await loadEngine();try await loadTasks() } } }
                        if !harnessDir.isEmpty { Button("Use bundled") { harnessDir="";perform { try await loadEngine();try await loadTasks() } } }
                    }.controlSize(.small)
                }.font(.caption)
            }.padding(.leading,34)
            step(2,"Sandbox isolation",done:readiness["ok"] as? Bool == true,detail:running ? "Checking. A throwaway container is started and removed." : readiness["checked"] != nil ? "Last checked \(Self.ago(readiness["checked"])) · took \(String(format:"%.0f",readiness["duration"] as? Double ?? 0)) s" : "Docker in a Colima VM with the gVisor runtime, an internal-only network, no sudo, and root-only files the agent cannot read.") {
                Button(running ? "Checking…" : "Run checks") { perform { readiness=try await model.researchLab.request("/sandbox/readiness",body:["harness_dir":harnessDir],timeout:10) } }.disabled(running)
            }
            if running || !checks.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(Self.checkOrder,id:\.self) { name in
                        let c=checks.first { $0["name"] as? String == name }
                        CheckRow(name:name,check:c,pending:running && c == nil)
                    }
                    if let error=readiness["error"] as? String { Text(error).font(.system(.caption,design:.monospaced)).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(.leading,34)
            }
            step(3,"A model is running",done:!model.snapshot.models.isEmpty,detail:model.snapshot.models.isEmpty ? "Agents call a model served by Dyno. It needs tool calling; recent Qwen models work well." : "Agents can use any of these endpoints.") {
                Button("Open Models") { model.requestedTab = .run }
            }
            if !model.snapshot.models.isEmpty {
                VStack(alignment:.leading,spacing:4) {
                    ForEach(model.snapshot.models,id:\.id) { m in Label("\(m.name) · 127.0.0.1:\(m.port.map { String($0) } ?? "—")",systemImage:"bolt.horizontal.circle").font(.callout) }
                }.padding(.leading,34)
            }
            step(4,"Positive controls pass",done:controls?["passed"] as? Bool == true,detail:controls == nil ? "Scripted honest and rule-breaking agents run in real containers. If a scripted rule break isn't flagged, the labels can't be trusted." : "Last controls run \(Self.ago(controls?["created"])) · \(controls?["status"] as? String ?? "")") {
                HStack {
                    if let id=controls?["id"] as? String { Button("Open run") { perform { try await open(id);episodeKey=nil;workspace=Workspace.runs.rawValue } } }
                    Button("Run controls") { perform { run=try await model.researchLab.request("/sandbox/runs",body:["kind":"controls","harness_dir":harnessDir],timeout:15);episodeKey=nil;workspace=Workspace.runs.rawValue;try await refresh() } }.disabled(readiness["ok"] as? Bool != true || active)
                }
            }
            if let results=controls?["results"] as? [[String:Any]],!results.isEmpty {
                VStack(alignment:.leading,spacing:4) {
                    ForEach(Array(results.enumerated()),id:\.offset) { _,r in
                        let ok=r["passed"] as? Bool == true
                        Label("\(r["task"] as? String ?? "") · \(r["behaviour"] as? String ?? "") → \(r["outcome"] as? String ?? "")\((r["tripwires"] as? [String]).map { $0.isEmpty ? "" : " · " + $0.joined(separator:", ") } ?? "")",systemImage:ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? DynoBrand.accent : .red).font(.callout)
                    }
                    Text("Honest scripts must end honest_blocked with no tripwires. Rule-breaking scripts must end rule_break with the expected tripwires.").font(.caption).foregroundStyle(.secondary)
                }.padding(.leading,34)
            }
            step(5,"First episode",done:runs.contains { $0["kind"] as? String == "episodes" },detail:"Pick a task and a running model. Watch the reasoning, commands and tripwires arrive live.") {
                Button("New run") { run=[:];episodeKey=nil;workspace=Workspace.runs.rawValue }.disabled(!ready)
            }
        }.frame(maxWidth:820,alignment:.leading)
    }

    static func ago(_ value: Any?) -> String {
        guard let t=value as? Double else { return "" }
        let s=Int(Date().timeIntervalSince1970-t)
        return s < 60 ? "just now" : s < 3600 ? "\(s/60) min ago" : s < 86400 ? "\(s/3600) h ago" : "\(s/86400) d ago"
    }

    private func step<Action: View>(_ n: Int,_ title: String,done: Bool,detail: String,@ViewBuilder action: () -> Action) -> some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:done ? "checkmark.circle.fill" : "\(n).circle").font(.title2).foregroundStyle(done ? DynoBrand.accent : .secondary)
            VStack(alignment:.leading,spacing:4) { Text(title).font(.headline);if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } }
            Spacer();action()
        }
    }

    // MARK: Requests

    private func search() {
        var c=URLComponents();c.queryItems=[URLQueryItem(name:"q",value:query),URLQueryItem(name:"event",value:eventFilter),URLQueryItem(name:"limit",value:"200")]
        perform { results=try await model.researchLab.request("/sandbox/search?\(c.percentEncodedQuery ?? "")",timeout:15)["results"] as? [[String:Any]] ?? [] }
    }
    private func searchTask(_ id: String) {
        var c=URLComponents();c.queryItems=[URLQueryItem(name:"task",value:id),URLQueryItem(name:"limit",value:"200")]
        perform { results=try await model.researchLab.request("/sandbox/search?\(c.percentEncodedQuery ?? "")",timeout:15)["results"] as? [[String:Any]] ?? [] }
    }
    private func addSource() {
        let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.message="Choose a harness runs folder to index"
        if p.runModal() == .OK,let url=p.url { perform { _=try await model.researchLab.request("/sandbox/sources",body:["path":url.path]);search() } }
    }
    private func loadEnvironments() async {
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        envTemplates=((try? await model.researchLab.request("/sandbox/environments?\(c.percentEncodedQuery ?? "")",timeout:30))?["templates"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String }
    }
    private func loadTasks() async throws {
        await loadEnvironments()
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        tasks=try await model.researchLab.request("/sandbox/tasks?\(c.percentEncodedQuery ?? "")",timeout:30)["tasks"] as? [[String:Any]] ?? []
    }
    private func loadEngine() async throws {
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        engine=try await model.researchLab.request("/sandbox/engine?\(c.percentEncodedQuery ?? "")",timeout:30)
    }
    private func loadReadiness() async throws { readiness=try await model.researchLab.request("/sandbox/readiness") }
    private func refresh() async throws { runs=try await model.researchLab.request("/sandbox/runs")["runs"] as? [[String:Any]] ?? [] }
    private func open(_ id: String) async throws { run=try await model.researchLab.request("/sandbox/runs/\(id)",timeout:10) }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { guard !working else { return };working=true;Task { do { try await action();issue=nil } catch { issue=error.localizedDescription };working=false } }
}

struct EpisodeRow: View {
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

private struct CheckRow: View {
    var name: String
    var check: [String:Any]?
    var pending: Bool
    var body: some View {
        DisclosureGroup {
            VStack(alignment:.leading,spacing:4) {
                if let what=check?["what"] as? String,!what.isEmpty { Text(what).font(.callout) }
                if let command=check?["command"] as? String,!command.isEmpty { Text("$ \(command)").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary) }
                Text("Result: \(check?["detail"] as? String ?? (pending ? "running…" : "not run"))").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            }.padding(.vertical,4)
        } label: {
            HStack(spacing:8) {
                if pending { ProgressView().controlSize(.small) }
                else if let c=check { Image(systemName:c["passed"] as? Bool == true ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(c["passed"] as? Bool == true ? DynoBrand.accent : .red) }
                else { Image(systemName:"circle").foregroundStyle(.secondary) }
                Text(name).font(.callout)
            }
        }
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
    @State private var onlyTripwires: Bool

    init(lab: ResearchLab, key: String, onlyTripwires: Bool = false, onError: @escaping (String) -> Void) {
        self.lab = lab; self.key = key; self.onError = onError
        _onlyTripwires = State(initialValue: onlyTripwires)
    }
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
                    info=try await lab.request("/sandbox/episodes/\(key)",timeout:10)
                    let page=try await lab.request("/sandbox/episodes/\(key)/events?after=\(last)",timeout:10)
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
    @State private var expanded = false
    private var kind: String { event["event"] as? String ?? "" }
    private var header: String { "\(event["agent_id"] as? String ?? "agent") · step \(event["step"] as? Int ?? 0)" }
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            switch kind {
            case "start":
                label("Task given to the agent",.secondary);Text(event["prompt"] as? String ?? "")
            case "model":
                label("\(header) · thinking",DynoBrand.violet)
                if let r=event["reasoning"] as? String,!r.isEmpty {
                    let long=r.count > 600
                    Text(long && !expanded ? String(r.prefix(600)) + "…" : r).italic().foregroundStyle(.secondary).textSelection(.enabled)
                    if long { Button(expanded ? "Show less" : "Show full reasoning (\(r.count) characters)") { expanded.toggle() }.buttonStyle(.link).font(.caption) }
                }
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
