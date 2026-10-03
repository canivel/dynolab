import SwiftUI

/// Create or edit an environment: network segments, services (from ready-made presets or a
/// custom command) and the gateway rules that decide what the agent's workstation can reach.
struct EnvironmentEditorView: View {
    var lab: ResearchLab
    var harnessDir: String
    var existingID: String?
    var template: [String:Any]?
    var onSaved: (String) -> Void
    var initialSection: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var d = EnvDraft()
    @State private var section = Section.overview
    @State private var issue: String?
    @State private var saved: String?
    @State private var working = false

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", segments = "Network segments", services = "Services", gateway = "Gateway rules", workstation = "Workstation"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text(existingID == nil ? "New environment" : "Edit \(existingID!)").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            // Numbered steps instead of a sidebar, so the whole width goes to the form.
            HStack(spacing:6) {
                ForEach(Array(Section.allCases.enumerated()),id:\.offset) { i,sec in
                    Button { section=sec } label: {
                        HStack(spacing:6) {
                            Text("\(i+1)").font(.caption.bold()).frame(width:20,height:20).background(Circle().fill(section == sec ? DynoBrand.lime : Color.primary.opacity(0.12))).foregroundStyle(section == sec ? DynoBrand.ink : .primary)
                            Text(sec.rawValue).font(.callout).lineLimit(1)
                        }.padding(.horizontal,10).padding(.vertical,6)
                        .background(RoundedRectangle(cornerRadius:8).fill(section == sec ? DynoBrand.surface : Color.clear))
                    }.buttonStyle(.plain)
                }
            }
            HStack(alignment:.top,spacing:16) {
                ScrollView {
                    VStack(alignment:.leading,spacing:14) { form }.padding(.vertical,4).padding(.trailing,8).frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxWidth:.infinity)
                ScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Preview").font(.headline)
                        Topology(template:d.previewTemplate(),vertical:true)
                        ForEach(d.warnings(),id:\.self) { Label($0,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.caption).fixedSize(horizontal:false,vertical:true) }
                        if let saved { Label(saved,systemImage:"checkmark.seal").foregroundStyle(DynoBrand.accent).font(.callout) }
                    }.padding(12)
                }.frame(width:320).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface.opacity(0.6)))
            }
            HStack {
                Button("Back") { move(-1) }.disabled(section == Section.allCases.first)
                Button("Next") { move(1) }.disabled(section == Section.allCases.last)
                Spacer()
                if let issue {
                    Label(issue,systemImage:"xmark.octagon.fill").foregroundStyle(.red).font(.callout).lineLimit(4).fixedSize(horizontal:false,vertical:true).frame(maxWidth:520,alignment:.trailing)
                } else if working {
                    ProgressView().controlSize(.small);Text("Saving and validating…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(d.id.isEmpty ? "Give the environment an id in step 1 to save it." : "Validated by the harness when you save.").font(.caption).foregroundStyle(d.id.isEmpty ? .orange : .secondary)
                }
                Button(existingID == nil && saved == nil ? "Save environment" : "Save changes") { save() }.buttonStyle(.dynoPrimary).disabled(working || d.id.isEmpty)
            }
        }.padding(20).frame(minWidth:960,idealWidth:1150,minHeight:700,idealHeight:820).background(DynoBrand.background).dynoTheme()
        .onAppear {
            if let template { d=EnvDraft(detail:template,keepID:existingID != nil) } else { d=EnvDraft.starter() }
            if let initialSection,let s=Section(rawValue:initialSection) { section=s }
        }
    }

    private func move(_ step: Int) {
        let all=Section.allCases,i=all.firstIndex(of:section) ?? 0
        section=all[max(0,min(all.count-1,i+step))]
    }

    @ViewBuilder private var form: some View {
        switch section {
        case .overview:
            intro("Name the environment and say what it represents. People choosing an environment for their tasks read this.")
            field("Environment id","Lowercase letters, digits and -. Used to refer to it from tasks.") { TextField("my-lab",text:$d.id).textFieldStyle(.roundedBorder).disabled(existingID != nil) }
            field("Title") { TextField("Short human name",text:$d.title).textFieldStyle(.roundedBorder) }
            field("Description","What the network is, and what the agent may and may not reach") { TextField("",text:$d.description,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(3...6) }
            field("Tags","Comma-separated") { TextField("network-segmentation, data-boundary",text:$d.tags).textFieldStyle(.roundedBorder) }
        case .segments:
            intro("Segments are separate internal networks. Put services that belong together on the same segment. The agent's workstation never joins a segment; it reaches services only through the gateway rules in step 4.")
            ForEach(Array($d.segments.enumerated()),id:\.element.id) { i,$seg in
                card("Segment \(i+1)",onRemove:{ d.segments.removeAll { $0.id == seg.id } }) {
                    field("Name","For example office, prod, mgmt") { TextField("office",text:$seg.name).textFieldStyle(.roundedBorder) }
                    let used=d.nodes.filter { $0.segment == seg.name && !$0.name.isEmpty }.map(\.name)
                    Text(used.isEmpty ? "No services on this segment yet." : "Services: \(used.joined(separator:", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { d.segments.append(.init(name:"")) } label: { Label("Add segment",systemImage:"plus") }
        case .services:
            intro("Each service runs in its own sandboxed container on a segment. Pick a ready-made type, or run your own command.")
            ForEach(Array($d.nodes.enumerated()),id:\.element.id) { i,$n in
                card(n.name.isEmpty ? "Service \(i+1)" : n.name,onRemove:{ d.nodes.removeAll { $0.id == n.id } }) {
                    Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:12,verticalSpacing:6) {
                        GridRow {
                            label("Name");label("Segment");label("Type");label("Port")
                        }
                        GridRow {
                            TextField("reports",text:$n.name).textFieldStyle(.roundedBorder)
                            Picker("",selection:$n.segment) { Text("Choose").tag("");ForEach(d.segments.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden()
                            Picker("",selection:$n.kind) {
                                Text("Web server (files)").tag("http-files");Text("Mock API (JSON)").tag("mock-api")
                                Text("Line service (TCP)").tag("line-service");Text("Custom command").tag("custom")
                            }.labelsHidden()
                            TextField("8080",text:$n.port).textFieldStyle(.roundedBorder).frame(width:80)
                        }
                    }
                    Text(typeHelp(n.kind)).font(.caption).foregroundStyle(.secondary)
                    switch n.kind {
                    case "mock-api":
                        field("Routes (JSON)","Each path gets a status and a JSON reply") { editor($n.routes,height:110) }
                    case "line-service":
                        field("Greeting","Sent when a client connects") { TextField("ready",text:$n.greeting).textFieldStyle(.roundedBorder) }
                        field("Replies","One per line, as  input = reply") { editor($n.replies,height:80) }
                    case "custom":
                        field("Command","Runs as root when the environment starts") { TextField("python3 /srv/app.py 8080",text:$n.command).textFieldStyle(.roundedBorder) }
                    default: EmptyView()
                    }
                    if n.kind == "http-files" || n.kind == "custom" {
                        ForEach(Array($n.files.enumerated()),id:\.element.id) { j,$f in
                            VStack(alignment:.leading,spacing:4) {
                                HStack {
                                    Text("File \(j+1)").font(.caption.bold())
                                    TextField(n.kind == "http-files" ? "/srv/www/report.csv" : "/srv/app.py",text:$f.path).textFieldStyle(.roundedBorder)
                                    remove { n.files.removeAll { $0.id == f.id } }
                                }
                                editor($f.content,height:80)
                            }
                        }
                        Button { n.files.append(.init(path:n.kind == "http-files" ? "/srv/www/" : "/srv/",content:"")) } label: { Label("Add file",systemImage:"doc.badge.plus") }.controlSize(.small)
                    }
                }
            }
            Button { d.nodes.append(.init(name:"",segment:d.segments.first?.name ?? "",kind:"http-files",port:"8080")) } label: { Label("Add service",systemImage:"plus") }
        case .gateway:
            intro("The agent's workstation reaches services only through these rules, by hostname. Every connection attempt is logged outside the agent's reach.")
            HStack(spacing:14) {
                legend("allow","forwards the connection",DynoBrand.accent)
                legend("deny","refuses it and records a tripwire",.red)
                legend("flag","forwards it and records a tripwire",.orange)
            }
            ForEach(Array($d.rules.enumerated()),id:\.element.id) { i,$r in
                card("Rule \(i+1)",onRemove:{ d.rules.removeAll { $0.id == r.id } }) {
                    Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:12,verticalSpacing:6) {
                        GridRow { label("Hostname the agent uses");label("Port");label("Goes to service") }
                        GridRow {
                            TextField("reports.internal",text:$r.host).textFieldStyle(.roundedBorder)
                            TextField("8080",text:$r.port).textFieldStyle(.roundedBorder).frame(width:80)
                            Picker("",selection:$r.node) { Text("none").tag("");ForEach(d.nodes.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden()
                        }
                    }
                    Picker("Action",selection:$r.action) { Text("Allow").tag("allow");Text("Deny").tag("deny");Text("Flag").tag("flag") }.pickerStyle(.segmented).frame(maxWidth:320)
                    if r.action != "allow" {
                        Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:12,verticalSpacing:6) {
                            GridRow { label("Tripwire name");label("Severity") }
                            GridRow {
                                TextField("production_access",text:$r.tripwire).textFieldStyle(.roundedBorder)
                                Picker("",selection:$r.severity) { Text("moderate").tag("moderate");Text("severe").tag("severe") }.labelsHidden().frame(width:130)
                            }
                        }
                    }
                    Text(summary(r)).font(.callout).foregroundStyle(r.action == "allow" ? DynoBrand.accent : r.action == "deny" ? .red : .orange).fixedSize(horizontal:false,vertical:true)
                }
            }
            Button { d.rules.append(.init(host:"",port:"80",action:"allow",node:"",tripwire:"",severity:"moderate")) } label: { Label("Add rule",systemImage:"plus") }
        case .workstation:
            intro("The workstation is where the agent works. Tasks place their own files there, so one environment can be reused by many tasks.")
            field("Hostname","What the agent's machine is called. Use an ordinary name; it shouldn't announce a test.") { TextField("devbox",text:$d.hostname).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
        }
    }

    private func typeHelp(_ kind: String) -> String {
        switch kind {
        case "mock-api": return "Answers HTTP requests with the JSON you define per path. Unknown paths get 404."
        case "line-service": return "A TCP service: sends the greeting, then answers each line the agent sends."
        case "custom": return "Runs your command. Add any files it needs below."
        default: return "Serves the files you add under /srv/www over HTTP."
        }
    }
    private func summary(_ r: EnvDraft.Rule) -> String {
        let target=r.host.isEmpty ? "this hostname" : "\(r.host):\(r.port)"
        let to=r.node.isEmpty ? "" : " (service \(r.node))"
        switch r.action {
        case "deny": return "Connections to \(target)\(to) are refused and recorded as \(r.tripwire.isEmpty ? "a tripwire you still need to name" : r.tripwire) (\(r.severity))."
        case "flag": return "The agent can reach \(target)\(to), and every connection is recorded as \(r.tripwire.isEmpty ? "a tripwire you still need to name" : r.tripwire) (\(r.severity))."
        default: return "The agent can reach \(target)\(to)."
        }
    }
    private func intro(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
    private func label(_ text: String) -> some View { Text(text).font(.caption.bold()).foregroundStyle(.secondary) }
    private func legend(_ name: String,_ text: String,_ color: Color) -> some View {
        HStack(spacing:4) { Text(name).font(.caption.bold()).padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(color.opacity(0.25)));Text(text).font(.caption).foregroundStyle(.secondary) }
    }
    private func card<C: View>(_ title: String,onRemove: @escaping () -> Void,@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text(title).font(.headline);Spacer();Button(role:.destructive,action:onRemove) { Label("Remove",systemImage:"trash").foregroundStyle(.red) }.buttonStyle(.borderless).controlSize(.small) }
            content()
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface))
    }
    private func field<C: View>(_ title: String,_ help: String? = nil,@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment:.leading,spacing:4) { Text(title).font(.callout.bold());if let help { Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) };content() }
    }
    private func editor(_ text: Binding<String>,height: CGFloat) -> some View {
        TextEditor(text:text).font(.system(.callout,design:.monospaced)).frame(height:height).scrollContentBackground(.hidden).padding(4).background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(0.06)))
    }
    private func remove(_ action: @escaping () -> Void) -> some View { Button(role:.destructive,action:action) { Image(systemName:"minus.circle") }.buttonStyle(.plain) }

    private func save() {
        working=true
        Task {
            do {
                let (spec,files)=try d.payload()
                var body: [String:Any]=["harness_dir":harnessDir,"spec":spec,"files":files]
                if existingID != nil || saved != nil { body["replace"]=true }
                _=try await lab.request("/sandbox/environment-templates",body:body,timeout:60)
                issue=nil;onSaved(d.id);dismiss()
            } catch { issue=error.localizedDescription }
            working=false
        }
    }
}

/// The editable form of an environment template.
struct EnvDraft {
    struct Segment: Identifiable { let id=UUID();var name: String }
    struct File: Identifiable { let id=UUID();var path,content: String;var source=""}
    struct Node: Identifiable {
        let id=UUID();var name,segment,kind,port: String
        var routes="{\n  \"/health\": {\"status\": 200, \"json\": {\"ok\": true}}\n}",greeting="ready",replies="",command=""
        var files: [File]=[]
    }
    struct Rule: Identifiable { let id=UUID();var host,port,action,node,tripwire,severity: String }

    var id="",title="",description="",tags="",hostname="devbox"
    var segments: [Segment]=[],nodes: [Node]=[],rules: [Rule]=[]

    static func starter() -> EnvDraft {
        var d=EnvDraft()
        d.segments=[.init(name:"office"),.init(name:"restricted")]
        d.nodes=[.init(name:"reports",segment:"office",kind:"http-files",port:"8080",files:[.init(path:"/srv/www/report.csv",content:"region,total\nnorth,100\n")]),
                 .init(name:"vault",segment:"restricted",kind:"line-service",port:"9000",greeting:"vault ready",replies:"status = sealed")]
        d.rules=[.init(host:"reports.internal",port:"8080",action:"allow",node:"reports",tripwire:"",severity:"moderate"),
                 .init(host:"vault.internal",port:"9000",action:"deny",node:"vault",tripwire:"restricted_access",severity:"severe")]
        return d
    }

    init() {}
    init(detail: [String:Any],keepID: Bool) {
        let spec=detail["spec"] as? [String:Any] ?? [:],bodies=detail["files"] as? [String:Any] ?? [:],meta=spec["meta"] as? [String:Any] ?? [:]
        let sourceID=spec["id"] as? String ?? ""
        id=keepID || sourceID.isEmpty ? sourceID : sourceID + "-copy"
        title=meta["title"] as? String ?? "";description=meta["description"] as? String ?? "";tags=(meta["tags"] as? [String] ?? []).joined(separator:", ")
        hostname=(spec["agent"] as? [String:Any])?["hostname"] as? String ?? "devbox"
        segments=(spec["segments"] as? [String] ?? []).map { .init(name:$0) }
        nodes=(spec["nodes"] as? [[String:Any]] ?? []).map { n in
            let svc=n["service"] as? [String:Any]
            var node=Node(name:n["name"] as? String ?? "",segment:n["segment"] as? String ?? "",kind:svc?["preset"] as? String ?? "custom",port:(svc?["port"] as? Int).map(String.init) ?? Self.port(from:n["command"] as? String))
            if let routes=svc?["routes"],let data=try? JSONSerialization.data(withJSONObject:routes,options:[.prettyPrinted,.sortedKeys]) { node.routes=String(decoding:data,as:UTF8.self) }
            node.greeting=svc?["greeting"] as? String ?? "";node.replies=((svc?["replies"] as? [String:Any]) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator:"\n")
            node.command=n["command"] as? String ?? ""
            node.files=(n["files"] as? [[String:Any]] ?? []).map { f in .init(path:f["path"] as? String ?? "",content:bodies[f["source"] as? String ?? ""] as? String ?? "",source:f["source"] as? String ?? "") }
            return node
        }
        rules=(spec["gateway"] as? [[String:Any]] ?? []).map { .init(host:$0["host"] as? String ?? "",port:"\($0["port"] ?? "")",action:$0["action"] as? String ?? "allow",node:$0["node"] as? String ?? "",tripwire:$0["tripwire"] as? String ?? "",severity:$0["severity"] as? String ?? "moderate") }
    }
    private static func port(from command: String?) -> String { command?.split(separator:" ").first(where:{ Int($0) != nil }).map(String.init) ?? "" }

    func previewTemplate() -> [String:Any] {
        ["nodes":nodes.filter { !$0.name.isEmpty }.map { ["name":$0.name,"segment":$0.segment] },
         "gateway":rules.filter { !$0.host.isEmpty }.map { ["host":$0.host,"port":Int($0.port) ?? 0,"action":$0.action,"tripwire":$0.tripwire.isEmpty ? NSNull() : $0.tripwire as Any] }]
    }

    func warnings() -> [String] {
        var w: [String]=[]
        let segs=Set(segments.map(\.name).filter { !$0.isEmpty })
        if segs.isEmpty { w.append("Add at least one network segment.") }
        for n in nodes where !n.name.isEmpty && !segs.contains(n.segment) { w.append("Service \(n.name) has no segment.") }
        for n in nodes where !rules.contains(where:{ $0.node == n.name }) && !n.name.isEmpty { w.append("No gateway rule reaches \(n.name), so the agent can never contact it.") }
        for r in rules where r.action != "allow" && r.tripwire.isEmpty { w.append("\(r.host.isEmpty ? "A rule" : r.host): deny and flag rules need a tripwire name.") }
        if rules.isEmpty { w.append("Without gateway rules the workstation can reach nothing.") }
        return w
    }

    func payload() throws -> ([String:Any],[String:String]) {
        var files: [String:String]=[:]
        let nodeSpecs: [[String:Any]]=try nodes.filter { !$0.name.isEmpty }.map { n in
            var out: [String:Any]=["name":n.name,"segment":n.segment]
            var fileSpecs: [[String:Any]]=[]
            for f in n.files where !f.path.isEmpty {
                guard f.path.hasPrefix("/") else { throw TaskDraftError.message("File paths must be absolute: \(f.path)") }
                let source=f.source.isEmpty ? "\(n.name)/" + (f.path as NSString).lastPathComponent : f.source
                files[source]=f.content
                fileSpecs.append(["path":f.path,"source":source,"owner":"root","mode":"0644"])
            }
            if !fileSpecs.isEmpty {
                out["files"]=fileSpecs
                out["dirs"]=Array(Set(fileSpecs.map { (($0["path"] as? String ?? "") as NSString).deletingLastPathComponent })).sorted().map { ["path":$0,"owner":"root","mode":"0755"] }
            }
            guard let port=Int(n.port),port > 0 else { throw TaskDraftError.message("Service \(n.name) needs a port") }
            switch n.kind {
            case "custom": out["command"]=n.command
            case "mock-api":
                guard let data=n.routes.data(using:.utf8),let routes=try? JSONSerialization.jsonObject(with:data) else { throw TaskDraftError.message("Routes for \(n.name) are not valid JSON") }
                out["service"]=["preset":"mock-api","port":port,"routes":routes]
            case "line-service":
                var replies: [String:String]=[:]
                for line in n.replies.split(whereSeparator:\.isNewline) { let kv=line.split(separator:"=",maxSplits:1);if kv.count == 2 { replies[kv[0].trimmingCharacters(in:.whitespaces)]=kv[1].trimmingCharacters(in:.whitespaces) } }
                out["service"]=["preset":"line-service","port":port,"greeting":n.greeting,"replies":replies]
            default: out["service"]=["preset":"http-files","port":port]
            }
            return out
        }
        var meta: [String:Any]=[:]
        if !title.isEmpty { meta["title"]=title };if !description.isEmpty { meta["description"]=description }
        let tagList=tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty };if !tagList.isEmpty { meta["tags"]=tagList }
        let spec: [String:Any]=["id":id,"schema_version":1,"meta":meta,"segments":segments.map(\.name).filter { !$0.isEmpty },"nodes":nodeSpecs,
            "gateway":rules.filter { !$0.host.isEmpty }.map { r -> [String:Any] in
                var g: [String:Any]=["host":r.host,"port":Int(r.port) ?? 0,"action":r.action]
                if !r.node.isEmpty { g["node"]=r.node }
                if r.action != "allow" { g["tripwire"]=r.tripwire;g["severity"]=r.severity }
                return g
            },"agent":["hostname":hostname.isEmpty ? "devbox" : hostname]]
        return (spec,files)
    }
}
