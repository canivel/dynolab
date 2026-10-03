import SwiftUI

/// Create or edit an environment: network segments, services (from ready-made presets or a
/// custom command) and the gateway rules that decide what the agent's workstation can reach.
struct EnvironmentEditorView: View {
    var lab: ResearchLab
    var harnessDir: String
    var existingID: String?
    var template: [String:Any]?
    var onSaved: (String) -> Void
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
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(existingID == nil ? "New environment" : "Edit \(existingID!)").font(.title2.bold())
                Spacer()
                if let issue { Text(issue).foregroundStyle(.orange).font(.callout).lineLimit(3) }
                Button("Close") { dismiss() }
            }
            HSplitView {
                HStack(alignment:.top,spacing:0) {
                    List(Section.allCases,selection:Binding(get:{ section },set:{ section=$0 ?? .overview })) { Text($0.rawValue).tag($0) }.frame(width:170)
                    ScrollView { VStack(alignment:.leading,spacing:10) { form }.padding(16).frame(maxWidth:.infinity,alignment:.leading) }
                }.frame(minWidth:640)
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Preview").font(.headline)
                        Topology(template:d.previewTemplate())
                        ForEach(d.warnings(),id:\.self) { Label($0,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                        if let saved { Label(saved,systemImage:"checkmark.seal").foregroundStyle(DynoBrand.accent).font(.callout) }
                    }.padding(16)
                }.frame(minWidth:380,idealWidth:460)
            }
            HStack {
                Text("Saved environments live in your Dyno data and are validated by the harness. Built-in environments can be copied but not changed. Turn an environment on from the Environments list to try it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(existingID == nil && saved == nil ? "Save environment" : "Save changes") { save() }.buttonStyle(.dynoPrimary).disabled(working || d.id.isEmpty)
            }
        }.padding(20).frame(minWidth:1150,minHeight:760).background(DynoBrand.background).dynoTheme()
        .onAppear { if let template { d=EnvDraft(detail:template,keepID:existingID != nil) } else { d=EnvDraft.starter() } }
    }

    @ViewBuilder private var form: some View {
        switch section {
        case .overview:
            field("Environment id","Lowercase letters, digits and -. It names the environment.") { TextField("my-lab",text:$d.id).disabled(existingID != nil) }
            field("Title") { TextField("Short human name",text:$d.title) }
            field("Description","What the network is and what the agent may and may not reach") { TextField("",text:$d.description,axis:.vertical).lineLimit(2...5) }
            field("Tags","Comma-separated") { TextField("network-segmentation, data-boundary",text:$d.tags) }
        case .segments:
            Text("Segments are separate internal networks for services. The agent's workstation never joins them; it reaches services only through the gateway rules.").font(.callout).foregroundStyle(.secondary)
            ForEach($d.segments) { $seg in
                HStack { TextField("office",text:$seg.name);remove { d.segments.removeAll { $0.id == seg.id } } }
            }
            Button("Add segment") { d.segments.append(.init(name:"")) }
        case .services:
            Text("Each service runs in its own gVisor container on a segment. Pick a ready-made service or run your own command.").font(.callout).foregroundStyle(.secondary)
            ForEach($d.nodes) { $n in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        TextField("name, e.g. reports",text:$n.name).frame(width:180)
                        Picker("",selection:$n.segment) { Text("Segment").tag("");ForEach(d.segments.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:150)
                        Picker("",selection:$n.kind) {
                            Text("Web server (files)").tag("http-files");Text("Mock API (JSON)").tag("mock-api")
                            Text("Line service (TCP)").tag("line-service");Text("Custom command").tag("custom")
                        }.labelsHidden().frame(width:190)
                        Text("port").font(.caption);TextField("8080",text:$n.port).frame(width:70)
                        Spacer();remove { d.nodes.removeAll { $0.id == n.id } }
                    }
                    switch n.kind {
                    case "mock-api":
                        Text("Routes as JSON: path → status and JSON reply.").font(.caption).foregroundStyle(.secondary)
                        editor($n.routes,height:90)
                    case "line-service":
                        HStack { Text("Greeting").font(.caption);TextField("ready",text:$n.greeting) }
                        Text("Replies, one per line as  input = reply").font(.caption).foregroundStyle(.secondary)
                        editor($n.replies,height:70)
                    case "custom":
                        HStack { Text("Command").font(.caption);TextField("python3 /srv/app.py 8080",text:$n.command) }
                    default:
                        Text("Serves the files below from /srv/www.").font(.caption).foregroundStyle(.secondary)
                    }
                    if n.kind == "http-files" || n.kind == "custom" {
                        ForEach($n.files) { $f in
                            VStack(alignment:.leading) {
                                HStack { TextField(n.kind == "http-files" ? "/srv/www/report.csv" : "/srv/app.py",text:$f.path);remove { n.files.removeAll { $0.id == f.id } } }
                                editor($f.content,height:70)
                            }
                        }
                        Button("Add file") { n.files.append(.init(path:n.kind == "http-files" ? "/srv/www/" : "/srv/",content:"")) }.controlSize(.small)
                    }
                }.padding(10).background(RoundedRectangle(cornerRadius:8).fill(DynoBrand.surface))
            }
            Button("Add service") { d.nodes.append(.init(name:"",segment:d.segments.first?.name ?? "",kind:"http-files",port:"8080")) }
        case .gateway:
            Text("The workstation reaches services only by these hostnames. Allow forwards the connection. Deny refuses it. Flag forwards it but records a tripwire. Every attempt is logged outside the agent's reach.").font(.callout).foregroundStyle(.secondary)
            ForEach($d.rules) { $r in
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        TextField("reports.internal",text:$r.host).frame(width:200)
                        Text(":");TextField("8080",text:$r.port).frame(width:70)
                        Picker("",selection:$r.action) { Text("allow").tag("allow");Text("deny").tag("deny");Text("flag").tag("flag") }.pickerStyle(.segmented).frame(width:180)
                        Picker("",selection:$r.node) { Text("no service").tag("");ForEach(d.nodes.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:150)
                        Spacer();remove { d.rules.removeAll { $0.id == r.id } }
                    }
                    if r.action != "allow" {
                        HStack {
                            TextField("tripwire name, e.g. production_access",text:$r.tripwire)
                            Picker("",selection:$r.severity) { Text("moderate").tag("moderate");Text("severe").tag("severe") }.labelsHidden().frame(width:120)
                        }
                    }
                }.padding(8).background(RoundedRectangle(cornerRadius:8).fill(DynoBrand.surface))
            }
            Button("Add rule") { d.rules.append(.init(host:"",port:"80",action:"allow",node:"",tripwire:"",severity:"moderate")) }
        case .workstation:
            field("Hostname","What the agent's machine is called. Use an ordinary name; it shouldn't announce a test.") { TextField("devbox",text:$d.hostname) }
            Text("Tasks place their own files on the workstation, so this environment can be reused by many tasks.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field<C: View>(_ title: String,_ help: String? = nil,@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment:.leading,spacing:4) { Text(title).font(.callout.bold());if let help { Text(help).font(.caption).foregroundStyle(.secondary) };content() }.padding(.bottom,6)
    }
    private func editor(_ text: Binding<String>,height: CGFloat) -> some View {
        TextEditor(text:text).font(.system(.callout,design:.monospaced)).frame(height:height).scrollContentBackground(.hidden).padding(4).background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(0.05)))
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
                saved="Saved and validated by the harness";issue=nil;onSaved(d.id)
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
        id=keepID ? spec["id"] as? String ?? "" : ((spec["id"] as? String).map { $0 + "-copy" } ?? "")
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
