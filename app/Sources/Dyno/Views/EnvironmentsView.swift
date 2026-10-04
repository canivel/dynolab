import SwiftUI
import AppKit

/// Environment templates and their running instances. An instance is a small network of
/// service nodes behind policy gateways; while it is on, tasks can be run against it, each
/// episode on a fresh workstation.
struct EnvironmentsView: View {
    var model: MonitorModel
    var harnessDir: String
    var tasks: [[String:Any]]
    var onRunStarted: ([String:Any]) -> Void
    var onError: (String) -> Void
    var initialSelection: String? = nil
    var onCreateTask: (String) -> Void = { _ in }
    @State private var data: [String:Any] = [:]
    @State private var selected: String?
    @State private var instanceName = ""
    @State private var events: [[String:Any]] = []
    @State private var runTask = ""
    @State private var runCount = 1
    @State private var endpoint = ""
    @State private var working = false
    @State private var editor: EnvEditorRequest?
    @State private var justSaved: String?
    struct EnvEditorRequest: Identifiable { let id=UUID();var existing: String?;var template: [String:Any]? }

    private var templates: [[String:Any]] { data["templates"] as? [[String:Any]] ?? [] }
    private var instances: [[String:Any]] { data["instances"] as? [[String:Any]] ?? [] }
    private var operations: [String:[String:Any]] { data["operations"] as? [String:[String:Any]] ?? [:] }
    private var template: [String:Any]? { templates.first { $0["id"] as? String == selected } }
    private var running: [[String:Any]] { instances.filter { $0["template"] as? String == selected && $0["status"] as? String == "on" } }

    var body: some View {
        HSplitView {
            VStack(alignment:.leading,spacing:6) {
            Button { editor=EnvEditorRequest(existing:nil,template:nil) } label: { Label("New environment",systemImage:"plus") }.buttonStyle(.dynoPrimary).padding([.top,.horizontal],8)
            List(selection:$selected) {
                Section("Templates") {
                    ForEach(templates.compactMap { $0["id"] as? String },id:\.self) { id in
                        let t=templates.first { $0["id"] as? String == id } ?? [:]
                        let on=instances.contains { $0["template"] as? String == id && $0["status"] as? String == "on" }
                        HStack {
                            VStack(alignment:.leading) {
                                Text((t["meta"] as? [String:Any])?["title"] as? String ?? id)
                                Text(id).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if on { Text("ON").font(.caption2.bold()).padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(DynoBrand.accent.opacity(0.3))) }
                            if t["builtin"] as? Bool == false { Text("yours").font(.caption2).foregroundStyle(DynoBrand.violet) }
                            if !((t["errors"] as? [Any])?.isEmpty ?? true) { Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange) }
                        }.tag(id)
                    }
                }
            }
            }.frame(minWidth:260,idealWidth:300,maxWidth:360)
            ScrollView {
                if let t=template { detail(t).padding() } else { Text(templates.isEmpty ? "No environments yet. Check Agents → Readiness → Sandbox engine." : "Choose a template.").foregroundStyle(.secondary).padding() }
            }.frame(minWidth:600,maxWidth:.infinity)
        }
        .task {
            while !Task.isCancelled {
                await reload()
                if let inst=running.first?["name"] as? String { await loadEvents(inst) }
                try? await Task.sleep(for:.seconds(3))
            }
        }
        .onChange(of:selected) { _,id in instanceName=id ?? "";events=[];runTask="" }
        .sheet(item:$editor) { req in
            EnvironmentEditorView(lab:model.researchLab,harnessDir:harnessDir,existingID:req.existing,template:req.template) { saved in
                Task { await reload();selected=saved;instanceName=saved;justSaved=saved }
            }
        }
    }

    @ViewBuilder private func detail(_ t: [String:Any]) -> some View {
        let id=t["id"] as? String ?? ""
        let meta=t["meta"] as? [String:Any] ?? [:]
        VStack(alignment:.leading,spacing:14) {
            if justSaved == id { savedBanner(id) }
            HStack {
                Text(meta["title"] as? String ?? id).font(.title2.bold())
                Spacer()
                Button("Copy as new") { openEditor(id,edit:false) }
                if t["builtin"] as? Bool == false {
                    Button("Edit") { openEditor(id,edit:true) }
                    Button("Delete",role:.destructive) { deleteTemplate(id) }.disabled(!running.isEmpty)
                }
            }.controlSize(.small)
            Text(meta["description"] as? String ?? "").foregroundStyle(.secondary)
            ForEach(t["errors"] as? [String] ?? [],id:\.self) { Label($0,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            Topology(template:t)
            Divider()
            if let inst=running.first, let name=inst["name"] as? String {
                instancePanel(name:name,inst:inst,templateID:id)
            } else {
                HStack {
                    TextField("Instance name",text:$instanceName).frame(width:220)
                    Button("Turn on") { act(["action":"up","template":id,"name":instanceName]) }.buttonStyle(.dynoPrimary).disabled(working || instanceName.isEmpty || operations[instanceName]?["status"] as? String == "working")
                    if let op=operations[instanceName] { opLabel(op) }
                }
                Text("Turning on builds any custom images (cached), starts every node and gateway under gVisor, and waits until each allowed service answers.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func instancePanel(name: String,inst: [String:Any],templateID: String) -> some View {
        let matching=tasks.filter { ($0["environment"] as? [String:Any])?["template"] as? String == templateID }
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("\(name) is on · \(inst["containers_running"] as? Int ?? 0) containers",systemImage:"power").foregroundStyle(DynoBrand.accent).font(.headline)
                Spacer()
                Button("Open shell") { openShell(name:name,templateID:templateID) }.disabled(working)
                Button("Turn off",role:.destructive) { act(["action":"down","name":name]) }.disabled(working)
            }
            if let op=operations[name] { opLabel(op) }
            Text("Run a task against it").font(.headline)
            if matching.isEmpty { Text("No task uses this template yet. Create one in Tasks and set its environment.").font(.caption).foregroundStyle(.secondary) }
            else {
                HStack {
                    Picker("Task",selection:$runTask) { Text("Choose").tag("");ForEach(matching.compactMap { $0["id"] as? String },id:\.self) { Text($0).tag($0) } }.frame(width:280)
                    Stepper("Episodes: \(runCount)",value:$runCount,in:1...20).frame(width:160)
                    Picker("Model",selection:$endpoint) {
                        Text("Choose a running model").tag("")
                        ForEach(model.snapshot.models.filter { $0.port != nil },id:\.id) { m in Text("\(m.name) · :\(String(m.port ?? 0))").tag("\(String(m.port ?? 0))|\(m.identifier.isEmpty ? m.name : m.identifier)") }
                    }.frame(width:300)
                    Button("Run") { run(instance:name) }.buttonStyle(.dynoPrimary).disabled(working || runTask.isEmpty || endpoint.isEmpty)
                }
                Text("Each episode gets a fresh workstation on this instance. Only that workstation's traffic is attributed to the episode.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Gateway decisions").font(.headline)
            Label("Recorded by the gateways, outside the agent's container. The agent never sees this.",systemImage:"eye.slash").font(.caption).foregroundStyle(DynoBrand.violet)
            if events.isEmpty { Text("No traffic yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(events.suffix(60).reversed().enumerated()),id:\.offset) { _,e in
                HStack(spacing:10) {
                    Text(Date(timeIntervalSince1970:e["ts"] as? Double ?? 0),style:.time).font(.caption.monospacedDigit()).frame(width:80,alignment:.leading)
                    Text("\(e["host"] as? String ?? ""):\(String(e["port"] as? Int ?? 0))").font(.system(.caption,design:.monospaced)).frame(width:220,alignment:.leading)
                    Text(e["result"] as? String ?? "").font(.caption).frame(width:120,alignment:.leading)
                    actionBadge(e["action"] as? String ?? "")
                    if let tw=e["tripwire"] as? String,["deny","flag"].contains(e["action"] as? String ?? "") { Text(tw).font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Text(e["client"] as? String ?? "").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// What to do after saving: try the environment, or write a task that uses it.
    private func savedBanner(_ id: String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Label("Saved \(id) and validated it. Turn it on to try it, then run a task against it.",systemImage:"checkmark.seal.fill").foregroundStyle(DynoBrand.accent).font(.callout.bold())
            HStack {
                if running.isEmpty { Button("Turn on now") { justSaved=nil;act(["action":"up","template":id,"name":id]) }.buttonStyle(.dynoPrimary) }
                Button("Create a task for it") { onCreateTask(id);justSaved=nil }
                Button("Dismiss") { justSaved=nil }
            }.controlSize(.small)
            Text("A task uses an environment when its environment is set to \(id). Tasks place their own files on the agent's workstation.").font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.accent.opacity(0.1)))
    }

    private func openEditor(_ id: String,edit: Bool) {
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        Task {
            do { editor=EnvEditorRequest(existing:edit ? id : nil,template:try await model.researchLab.request("/sandbox/environment-templates/\(id)?\(c.percentEncodedQuery ?? "")",timeout:30)) }
            catch { onError(error.localizedDescription) }
        }
    }
    private func deleteTemplate(_ id: String) {
        Task {
            do { _=try await model.researchLab.request("/sandbox/environment-templates/delete",body:["harness_dir":harnessDir,"id":id],timeout:30);selected=nil;await reload() }
            catch { onError(error.localizedDescription) }
        }
    }

    private func opLabel(_ op: [String:Any]) -> some View {
        let status=op["status"] as? String ?? ""
        return HStack(spacing:6) {
            if status == "working" { ProgressView().controlSize(.small) }
            Text("\(op["action"] as? String ?? "") · \(status)").font(.caption)
            if let err=op["error"] as? String { Text(err).font(.caption).foregroundStyle(.orange).lineLimit(3) }
        }
    }

    private func actionBadge(_ action: String) -> some View {
        let color: Color=action == "allow" ? DynoBrand.accent : action == "deny" ? .red : .orange
        return Text(action).font(.caption2.bold()).padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(color.opacity(0.25)))
    }

    private func run(instance: String) {
        let parts=endpoint.split(separator:"|",maxSplits:1)
        guard parts.count == 2,let port=Int(parts[0]) else { return }
        working=true
        Task {
            do {
                let r=try await model.researchLab.request("/sandbox/runs",body:["harness_dir":harnessDir,"task":runTask,"count":runCount,"port":port,"model":String(parts[1]),"instance":instance],timeout:15)
                onRunStarted(r)
            } catch { onError(error.localizedDescription) }
            working=false
        }
    }

    /// A devbox on its own instance, then Terminal attached to it as the agent user.
    private func openShell(name: String,templateID: String) {
        let box="\(name)-box"
        working=true
        Task {
            do {
                _=try await model.researchLab.request("/sandbox/environments",body:["harness_dir":harnessDir,"action":"devbox","template":templateID,"name":box,"size":"m"],timeout:15)
                for _ in 0..<240 {
                    await reload()
                    if let op=operations[box],op["status"] as? String != "working" {
                        if let err=op["error"] as? String { throw TaskDraftError.message(err) }
                        let container="env-\(box)-devbox"
                        let script="tell application \"Terminal\" to do script \"PATH=/opt/homebrew/bin:$PATH docker exec -it -u agent -w /workspace \(container) bash\""
                        NSAppleScript(source:script)?.executeAndReturnError(nil)
                        NSAppleScript(source:"tell application \"Terminal\" to activate")?.executeAndReturnError(nil)
                        break
                    }
                    try await Task.sleep(for:.seconds(1))
                }
            } catch { onError(error.localizedDescription) }
            working=false
        }
    }

    private func act(_ body: [String:Any]) {
        working=true
        Task {
            do { _=try await model.researchLab.request("/sandbox/environments",body:body.merging(["harness_dir":harnessDir]) { a,_ in a },timeout:15);await reload() }
            catch { onError(error.localizedDescription) }
            working=false
        }
    }
    private func reload() async {
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        do {
            data=try await model.researchLab.request("/sandbox/environments?\(c.percentEncodedQuery ?? "")",timeout:30)
            if selected == nil { selected=initialSelection ?? templates.first?["id"] as? String }
        } catch { onError(error.localizedDescription) }
    }
    private func loadEvents(_ name: String) async {
        var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
        events=(try? await model.researchLab.request("/sandbox/environments/\(name)/events?\(c.percentEncodedQuery ?? "")",timeout:30))?["events"] as? [[String:Any]] ?? events
    }
}

/// Workstation → gateway rules → segments with their nodes.
struct Topology: View {
    var template: [String:Any]
    var vertical = false
    var body: some View {
        let nodes=template["nodes"] as? [[String:Any]] ?? []
        let rules=template["gateway"] as? [[String:Any]] ?? []
        let segments=Array(Set(nodes.compactMap { $0["segment"] as? String }.filter { !$0.isEmpty })).sorted()
        let layout=vertical ? AnyLayout(VStackLayout(alignment:.leading,spacing:8)) : AnyLayout(HStackLayout(alignment:.top,spacing:14))
        layout {
            box("Workstation",subtitle:"the agent, on its own access network",color:DynoBrand.violet) { EmptyView() }
            arrow
            box("Gateway rules",subtitle:"every attempt is logged",color:.orange) {
                if rules.isEmpty { Text("No rules yet").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(rules.enumerated()),id:\.offset) { _,r in
                    let action=r["action"] as? String ?? ""
                    VStack(alignment:.leading,spacing:1) {
                        HStack(spacing:6) {
                            Text(action).font(.caption2.bold()).padding(.horizontal,5).background(Capsule().fill((action == "allow" ? DynoBrand.accent : action == "deny" ? Color.red : Color.orange).opacity(0.25)))
                            Text("\(r["host"] as? String ?? ""):\(String(r["port"] as? Int ?? 0))").font(.system(.caption,design:.monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                        if let tw=r["tripwire"] as? String { Text("records \(tw)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            arrow
            VStack(alignment:.leading,spacing:8) {
                if segments.isEmpty { box("Segments",subtitle:"none yet",color:DynoBrand.accent) { EmptyView() } }
                ForEach(segments,id:\.self) { seg in
                    box("Segment: \(seg)",subtitle:"internal network",color:DynoBrand.accent) {
                        ForEach(nodes.filter { $0["segment"] as? String == seg }.compactMap { $0["name"] as? String }.filter { !$0.isEmpty },id:\.self) { Label($0,systemImage:"server.rack").font(.caption) }
                    }
                }
            }
        }
    }
    private var arrow: some View { Image(systemName:vertical ? "arrow.down" : "arrow.right").foregroundStyle(.secondary).padding(vertical ? .leading : .top,vertical ? 20 : 30) }
    private func box<C: View>(_ title: String,subtitle: String,color: Color,@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.callout.bold())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            content()
        }.padding(10).frame(minWidth:vertical ? nil : 180,maxWidth:vertical ? .infinity : 280,alignment:.leading).background(RoundedRectangle(cornerRadius:10).stroke(color.opacity(0.5)))
    }
}
