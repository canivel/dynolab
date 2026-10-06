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
    @State private var confirmSave = false
    @State private var addTo = ""
    @State private var justAdded: UUID?

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", segments = "Networks", services = "Services", gateway = "Gateway rules", workstation = "Workstation"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text(existingID != nil ? "Edit \(existingID!)" : template?["copy_id"] != nil ? "Copy of \(template?["copy_of"] as? String ?? "")" : "New environment").font(.title2.bold())
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
                Button(existingID == nil && saved == nil ? "Save environment" : "Save changes") { confirmSave = true }.buttonStyle(.dynoPrimary).disabled(working || d.id.isEmpty)
            }
        }.padding(20).frame(minWidth:960,idealWidth:1150,minHeight:700,idealHeight:820).background(DynoBrand.background).dynoTheme()
        .alert(existingID == nil ? "Create “\(d.title.isEmpty ? d.id : d.title)”?" : "Save changes to “\(d.title.isEmpty ? d.id : d.title)”?",isPresented:$confirmSave) {
            Button(existingID == nil ? "Create" : "Save changes") { save() }
            Button("Keep editing",role:.cancel) {}
        } message: {
            Text(existingID == nil ? "It's checked by the harness, then appears with your environments." : "Every test that uses this environment from now on runs with the new version. Past results are kept as they ran.")
        }
        .onAppear {
            if let template { d=EnvDraft(detail:template,keepID:existingID != nil) } else { d=EnvDraft.starter() }
            if existingID == nil,let id=template?["copy_id"] as? String { d.id=id;d.title=template?["copy_title"] as? String ?? d.title }
            addTo=d.segments.first?.name ?? ""
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
            field("Environment id","Lowercase letters, digits and -. Used to refer to it from tasks.") { TextField("my-lab",text:Binding(get:{ d.id },set:{ d.id=EnvDraft.cleanName($0) })).textFieldStyle(.roundedBorder).disabled(existingID != nil) }
            field("Title") { TextField("Short human name",text:$d.title).textFieldStyle(.roundedBorder) }
            field("Description","What the network is, and what the agents may and may not reach. Shown when people hover over its card.") {
                TextEditor(text:$d.description).font(.body).frame(minHeight:110).scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius:6).stroke(Color.secondary.opacity(0.25)))
            }
            field("Tags","Comma-separated") { TextField("network-segmentation, data-boundary",text:$d.tags).textFieldStyle(.roundedBorder) }
        case .segments:
            intro("Networks are separate internal networks; services on different networks can't reach each other. The agents' workstation never joins one. For each network, choose how the agents can reach the services on it. Dyno writes the gateway rules for you, and you can fine-tune them in step 4.")
            ForEach(Array($d.segments.enumerated()),id:\.element.id) { i,$seg in
                card("Network \(i+1)",onRemove:{
                    let name=seg.name,gone=Set(d.nodes.filter { $0.segment == name }.map(\.name))
                    d.nodes.removeAll { $0.segment == name };d.rules.removeAll { gone.contains($0.node) };d.segments.removeAll { $0.id == seg.id }
                }) {
                    field("Name",EnvDraft.nameRule) { TextField("office",text:renameSegment(seg.id)).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
                    let level=d.access(of:seg.name)
                    field("Access from the agents' workstation") {
                        HStack(spacing:8) {
                            ForEach(EnvDraft.accessLevels,id:\.id) { a in
                                Button { d.setAccess(a.id,of:seg.name) } label: {
                                    VStack(alignment:.leading,spacing:2) {
                                        Text(a.title).font(.callout.weight(.semibold))
                                        Text(a.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                    }.padding(8).frame(width:150,height:58,alignment:.topLeading)
                                    .background(RoundedRectangle(cornerRadius:8).fill(level == a.id ? accessColor(a.id).opacity(0.18) : Color.primary.opacity(0.04)))
                                    .overlay(RoundedRectangle(cornerRadius:8).stroke(level == a.id ? accessColor(a.id) : Color.secondary.opacity(0.3)))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                        if level == "custom" { Text("Custom: its services have different rules. Pick one level to make them all the same.").font(.caption).foregroundStyle(.orange) }
                    }
                    let used=d.nodes.filter { $0.segment == seg.name && !$0.name.isEmpty }.map(\.name)
                    Text(used.isEmpty ? "No services on this network yet. Add them in step 3." : "Services: \(used.joined(separator:", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { d.segments.append(.init(name:d.uniqueName("network",in:d.segments.map(\.name)))) } label: { Label("Add a network",systemImage:"plus") }
        case .services:
            intro("Click a service to add it, ready to use. It goes on the network you pick here and gets that network's access. Change anything afterwards below.")
            if d.segments.isEmpty {
                Text("Add a network in step 2 first.").foregroundStyle(.orange)
            } else {
                HStack {
                    Text("Add to network").font(.callout.bold())
                    Picker("",selection:$addTo) { ForEach(d.segments.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:200)
                    Text(EnvDraft.accessLevels.first { $0.id == d.access(of:addTo) }.map { "\($0.title): \($0.detail)" } ?? "").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:5),spacing:8) {
                    ForEach(EnvDraft.serviceTemplates) { t in
                        Button { let n=d.addService(t,to:addTo.isEmpty ? (d.segments.first?.name ?? "") : addTo);justAdded=n.id } label: {
                            VStack(alignment:.leading,spacing:4) {
                                Image(systemName:t.icon).font(.title3).foregroundStyle(DynoBrand.accent)
                                Text(t.title).font(.callout.weight(.semibold)).lineLimit(1)
                                Text(t.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal:false,vertical:true)
                                Spacer(minLength:0)
                            }.padding(10).frame(maxWidth:.infinity,minHeight:104,alignment:.topLeading)
                            .background(RoundedRectangle(cornerRadius:9).fill(Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius:9).stroke(Color.secondary.opacity(0.3)))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(t.detail)
                    }
                }
            }
            if d.nodes.isEmpty { Text("No services yet.").font(.callout).foregroundStyle(.secondary).padding(.top,6) }
            ForEach(Array($d.nodes.enumerated()).reversed(),id:\.element.id) { i,$n in
                card(n.name.isEmpty ? "Service \(i+1)" : n.name,onRemove:{ let name=n.name;d.rules.removeAll { $0.node == name };d.nodes.removeAll { $0.id == n.id } }) {
                    if justAdded == n.id { Label("Added. It works as is; change anything you like.",systemImage:"checkmark.circle").font(.caption).foregroundStyle(DynoBrand.accent) }
                    Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:12,verticalSpacing:6) {
                        GridRow { label("Name");label("Network");label("Type");label("Port") }
                        GridRow {
                            TextField("reports",text:renameService(n.id)).textFieldStyle(.roundedBorder)
                            Picker("",selection:$n.segment) { Text("Choose").tag("");ForEach(d.segments.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden()
                            Picker("",selection:$n.kind) { ForEach(EnvDraft.kindNames,id:\.0) { Text($0.1).tag($0.0) } }.labelsHidden()
                            TextField("8080",text:$n.port).textFieldStyle(.roundedBorder).frame(width:80)
                        }
                    }
                    Text(typeHelp(n.kind)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    switch n.kind {
                    case "mock-api":
                        field("Routes (JSON)","Each path gets a status and a JSON reply") { editor($n.routes,height:110) }
                    case "line-service":
                        field("Greeting","Sent when a client connects") { TextField("ready",text:$n.greeting).textFieldStyle(.roundedBorder) }
                        field("Replies","One per line, as  input = reply") { editor($n.replies,height:80) }
                    case "custom":
                        field("Command","Runs as root when the environment starts") { TextField("python3 /srv/app.py 8080",text:$n.command).textFieldStyle(.roundedBorder) }
                    case "sql-db":
                        field("Password","Agents need it to query. Leave empty for no password.") { TextField("db-admin-2024",text:$n.password).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
                    case "vault":
                        field("Token","Agents need it to read secrets") { TextField("s.root-token",text:$n.token).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
                        field("Secrets","One per line, as  name = value") { editor($n.secrets,height:80) }
                    case "object-store":
                        Toggle("Agents may upload and delete objects",isOn:$n.writable)
                    case "mail-outbox":
                        field("Domain") { TextField("corp.example",text:$n.domain).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
                    default: EmptyView()
                    }
                    if n.kind != "mock-api" && n.kind != "line-service" && n.kind != "vault" && n.kind != "mail-outbox" {
                        let what=n.kind == "sql-db" ? "Table" : n.kind == "object-store" ? "Object" : "File"
                        ForEach(Array($n.files.enumerated()),id:\.element.id) { j,$f in
                            VStack(alignment:.leading,spacing:4) {
                                HStack {
                                    Text("\(what) \(j+1)").font(.caption.bold())
                                    TextField(n.kind == "sql-db" ? "customers" : n.kind == "object-store" ? "exports/report.csv" : n.kind == "http-files" ? "/srv/www/report.csv" : "/srv/app.py",text:$f.path).textFieldStyle(.roundedBorder)
                                    remove { n.files.removeAll { $0.id == f.id } }
                                }
                                if n.kind == "sql-db" { Text("CSV: the first line names the columns").font(.caption2).foregroundStyle(.secondary) }
                                editor($f.content,height:80)
                            }
                        }
                        Button { n.files.append(.init(path:n.kind == "http-files" ? "/srv/www/" : n.kind == "custom" ? "/srv/" : "",content:"")) } label: { Label("Add \(what.lowercased())",systemImage:"doc.badge.plus") }.controlSize(.small)
                    }
                }
            }
        case .gateway:
            intro("The agents' workstation reaches services only through these rules, by hostname. Every connection attempt is logged outside the agents' reach.")
            HStack(spacing:14) {
                legend("allow","forwards the connection",DynoBrand.accent)
                legend("flag","forwards it and records a tripwire",.orange)
                legend("deny","refuses it and records a tripwire",.red)
            }
            HStack(spacing:8) {
                quickRule("Open a service","lock.open",DynoBrand.accent,"allow")
                quickRule("Watch a service","eye",.orange,"flag")
                quickRule("Lock a service","lock",.red,"deny")
                Button { d.blockInternet() } label: { quickLabel("Block the internet","globe",.red,"Refuse and record \(EnvDraft.internetHosts.joined(separator:", "))") }.buttonStyle(.plain)
                Button { d.rules.append(.init(host:"",port:"443",action:"deny",node:"",tripwire:"blocked_host",severity:"moderate")) } label: { quickLabel("Block a website","nosign",.red,"Refuse one hostname you type") }.buttonStyle(.plain)
            }
            if d.rules.isEmpty { Text("No rules yet: the workstation reaches nothing.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array($d.rules.enumerated()),id:\.element.id) { i,$r in
                card("Rule \(i+1)",onRemove:{ d.rules.removeAll { $0.id == r.id } }) {
                    Grid(alignment:.leadingFirstTextBaseline,horizontalSpacing:12,verticalSpacing:6) {
                        GridRow { label("Hostname the agent uses");label("Port");label("Goes to service") }
                        GridRow {
                            TextField("reports.internal",text:Binding(get:{ r.host },set:{ r.host=EnvDraft.cleanHost($0) })).textFieldStyle(.roundedBorder)
                            TextField("8080",text:$r.port).textFieldStyle(.roundedBorder).frame(width:80)
                            Picker("",selection:$r.node) { Text("none").tag("");ForEach(d.nodes.map(\.name).filter { !$0.isEmpty },id:\.self) { Text($0).tag($0) } }.labelsHidden()
                        }
                    }
                    Picker("Action",selection:$r.action) { Text("Allow").tag("allow");Text("Flag").tag("flag");Text("Deny").tag("deny") }.pickerStyle(.segmented).frame(maxWidth:320)
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
        case .workstation:
            intro("The workstation is where the agent works. Tasks place their own files there, so one environment can be reused by many tasks.")
            field("Hostname","What the agent's machine is called. Use an ordinary name; it shouldn't announce a test.") { TextField("devbox",text:$d.hostname).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
        }
    }

    private func accessColor(_ level: String) -> Color {
        level == "open" ? DynoBrand.accent : level == "watched" ? .orange : level == "locked" ? .red : .secondary
    }
    /// Network and service names are cleaned as typed, and renames carry through to what refers to them.
    private func renameSegment(_ id: UUID) -> Binding<String> {
        Binding(get: { d.segments.first { $0.id == id }?.name ?? "" }, set: { raw in
            guard let i=d.segments.firstIndex(where:{ $0.id == id }) else { return }
            let old=d.segments[i].name,new=EnvDraft.cleanName(raw)
            for j in d.nodes.indices where d.nodes[j].segment == old { d.nodes[j].segment=new }
            if addTo == old { addTo=new }
            d.segments[i].name=new
        })
    }
    private func renameService(_ id: UUID) -> Binding<String> {
        Binding(get: { d.nodes.first { $0.id == id }?.name ?? "" }, set: { raw in
            guard let i=d.nodes.firstIndex(where:{ $0.id == id }) else { return }
            let old=d.nodes[i].name,new=EnvDraft.cleanName(raw)
            for j in d.rules.indices where d.rules[j].node == old { d.rules[j].node=new }
            d.nodes[i].name=new
        })
    }
    private func quickLabel(_ title: String,_ icon: String,_ color: Color,_ detail: String) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Label(title,systemImage:icon).font(.callout.weight(.semibold)).foregroundStyle(color)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal:false,vertical:true)
        }.padding(9).frame(width:170,height:62,alignment:.topLeading)
        .background(RoundedRectangle(cornerRadius:9).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius:9).stroke(color.opacity(0.45)))
        .contentShape(Rectangle())
    }
    /// One click, then pick the service: its rules become allow, flag or deny.
    private func quickRule(_ title: String,_ icon: String,_ color: Color,_ action: String) -> some View {
        Menu {
            ForEach(d.nodes.map(\.name).filter { !$0.isEmpty },id:\.self) { name in Button(name) { d.setRule(for:name,action:action) } }
            if d.nodes.isEmpty { Text("Add services in step 3 first") }
        } label: {
            quickLabel(title,icon,color,action == "allow" ? "Agents can connect" : action == "flag" ? "Allowed, every connection recorded" : "Refused and recorded")
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func typeHelp(_ kind: String) -> String {
        switch kind {
        case "object-store": return "S3-style storage over HTTP. Agents use: curl http://<host>:<port>/ to list, curl http://<host>:<port>/<key> to download."
        case "sql-db": return "A real SQL database (SQLite), queried over HTTP: curl -H 'Authorization: Bearer <password>' 'http://<host>:<port>/query?sql=SELECT…'. /tables lists the tables."
        case "vault": return "Secrets behind a token: curl -H 'X-Vault-Token: <token>' http://<host>:<port>/v1/secret/<name>."
        case "mail-outbox": return "Agents send email with POST /send {to, subject, body}. Every message is kept on the service, none delivered."
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
struct EnvDraft: Equatable {
    /// `access` is the level chosen for the network; services added to it get that access.
    struct Segment: Identifiable, Equatable { var id=UUID();var name: String;var access="open" }
    struct File: Identifiable, Equatable { var id=UUID();var path,content: String;var source="";var owner="root",mode="0644" }
    struct Node: Identifiable, Equatable {
        var id=UUID();var name,segment,kind,port: String
        var routes="{\n  \"/health\": {\"status\": 200, \"json\": {\"ok\": true}}\n}",greeting="ready",replies="",command=""
        var files: [File]=[]
        // Kept from the template as written, so a copy behaves like the original.
        var setup="",runAs="",image=""
        var dirs: [[String:String]]=[]
        // Blob storage keeps its objects and a SQL database its tables in `files` (path = key or table name).
        var writable=false,password="",token="",secrets="",domain=""
        var filesAreData: Bool { kind == "object-store" || kind == "sql-db" }
    }
    struct Rule: Identifiable, Equatable { var id=UUID();var host,port,action,node,tripwire,severity: String }

    var id="",title="",description="",tags="",hostname="devbox"
    var imagesJSON=""
    var segments: [Segment]=[],nodes: [Node]=[],rules: [Rule]=[]

    /// A new environment starts with one network and nothing on it; services are added with one click.
    static func starter() -> EnvDraft {
        var d=EnvDraft()
        d.segments=[.init(name:"office")]
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
            if let objects=svc?["objects"] as? [String:Any] { node.files=objects.sorted { $0.key < $1.key }.map { .init(path:$0.key,content:"\($0.value)") } }
            if let tables=svc?["tables"] as? [String:Any] { node.files=tables.sorted { $0.key < $1.key }.map { .init(path:$0.key,content:"\($0.value)") } }
            node.writable=svc?["writable"] as? Bool ?? false;node.password=svc?["password"] as? String ?? "";node.token=svc?["token"] as? String ?? ""
            node.domain=svc?["domain"] as? String ?? ""
            node.secrets=((svc?["secrets"] as? [String:Any]) ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator:"\n")
            if !node.filesAreData { node.files=(n["files"] as? [[String:Any]] ?? []).map { f in .init(path:f["path"] as? String ?? "",content:bodies[f["source"] as? String ?? ""] as? String ?? "",source:f["source"] as? String ?? "",owner:f["owner"] as? String ?? "root",mode:"\(f["mode"] ?? "0644")") } }
            node.setup=n["setup"] as? String ?? "";node.runAs=n["run_as"] as? String ?? "";node.image=n["image"] as? String ?? ""
            node.dirs=(n["dirs"] as? [[String:Any]] ?? []).map { d in ["path":d["path"] as? String ?? "","owner":d["owner"] as? String ?? "root","mode":"\(d["mode"] ?? "0755")"] }
            return node
        }
        if let images=spec["images"],let data=try? JSONSerialization.data(withJSONObject:images,options:[.sortedKeys]) { imagesJSON=String(decoding:data,as:UTF8.self) }
        rules=(spec["gateway"] as? [[String:Any]] ?? []).map { .init(host:$0["host"] as? String ?? "",port:"\($0["port"] ?? "")",action:$0["action"] as? String ?? "allow",node:$0["node"] as? String ?? "",tripwire:$0["tripwire"] as? String ?? "",severity:$0["severity"] as? String ?? "moderate") }
        for k in segments.indices {
            let level=access(of:segments[k].name)
            segments[k].access=level == "custom" ? "open" : level
        }
    }
    private static func port(from command: String?) -> String { command?.split(separator:" ").first(where:{ Int($0) != nil }).map(String.init) ?? "" }

    func previewTemplate() -> [String:Any] {
        ["nodes":nodes.filter { !$0.name.isEmpty }.map { ["name":$0.name,"segment":$0.segment] },
         "gateway":rules.filter { !$0.host.isEmpty }.map { ["host":$0.host,"port":Int($0.port) ?? 0,"action":$0.action,"node":$0.node,"tripwire":$0.tripwire.isEmpty ? NSNull() : $0.tripwire as Any] }]
    }

    func warnings() -> [String] {
        var w: [String]=[]
        let segs=Set(segments.map(\.name).filter { !$0.isEmpty })
        if segs.isEmpty { w.append("Add at least one network.") }
        for n in nodes where !n.name.isEmpty && !segs.contains(n.segment) { w.append("Service \(n.name) has no network.") }
        for n in nodes where !rules.contains(where:{ $0.node == n.name }) && !n.name.isEmpty { w.append("No gateway rule reaches \(n.name): its network is hidden from the agents.") }
        for r in rules where r.action != "allow" && r.tripwire.isEmpty { w.append("\(r.host.isEmpty ? "A rule" : r.host): deny and flag rules need a tripwire name.") }
        if rules.isEmpty { w.append("Without gateway rules the workstation can reach nothing.") }
        return w
    }

    func payload() throws -> ([String:Any],[String:String]) {
        var files: [String:String]=[:]
        let nodeSpecs: [[String:Any]]=try nodes.filter { !$0.name.isEmpty }.map { n in
            var out: [String:Any]=["name":n.name,"segment":n.segment]
            var fileSpecs: [[String:Any]]=[]
            for f in n.files where !f.path.isEmpty && !n.filesAreData {
                guard f.path.hasPrefix("/") else { throw TaskDraftError.message("File paths must be absolute: \(f.path)") }
                let source=f.source.isEmpty ? "\(n.name)/" + (f.path as NSString).lastPathComponent : f.source
                files[source]=f.content
                fileSpecs.append(["path":f.path,"source":source,"owner":f.owner,"mode":f.mode])
            }
            if !fileSpecs.isEmpty { out["files"]=fileSpecs }
            let known=Set(n.dirs.compactMap { $0["path"] })
            let needed=Set(fileSpecs.map { (($0["path"] as? String ?? "") as NSString).deletingLastPathComponent }).subtracting(known).sorted()
            let dirs=n.dirs+needed.map { ["path":$0,"owner":"root","mode":"0755"] }
            if !dirs.isEmpty { out["dirs"]=dirs }
            if !n.setup.isEmpty { out["setup"]=n.setup }
            if !n.runAs.isEmpty { out["run_as"]=n.runAs }
            if !n.image.isEmpty { out["image"]=n.image }
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
            case "object-store":
                let objects=Dictionary(n.files.filter { !$0.path.isEmpty }.map { f in (f.path.trimmingCharacters(in:CharacterSet(charactersIn:"/ ")),f.content) },uniquingKeysWith:{ $1 })
                out["service"]=["preset":"object-store","port":port,"writable":n.writable,"objects":objects]
            case "sql-db":
                let tables=Dictionary(n.files.filter { !$0.path.isEmpty }.map { ($0.path,$0.content) },uniquingKeysWith:{ $1 })
                if tables.isEmpty { throw TaskDraftError.message("Database \(n.name) needs at least one table") }
                var svc: [String:Any]=["preset":"sql-db","port":port,"tables":tables]
                if !n.password.isEmpty { svc["password"]=n.password }
                out["service"]=svc
            case "vault":
                var secrets: [String:String]=[:]
                for line in n.secrets.split(whereSeparator:\.isNewline) { let kv=line.split(separator:"=",maxSplits:1);if kv.count == 2 { secrets[kv[0].trimmingCharacters(in:.whitespaces)]=kv[1].trimmingCharacters(in:.whitespaces) } }
                if n.token.isEmpty { throw TaskDraftError.message("Vault \(n.name) needs a token") }
                out["service"]=["preset":"vault","port":port,"token":n.token,"secrets":secrets]
            case "mail-outbox": out["service"]=["preset":"mail-outbox","port":port,"domain":n.domain]
            default: out["service"]=["preset":"http-files","port":port]
            }
            return out
        }
        var meta: [String:Any]=[:]
        if !title.isEmpty { meta["title"]=title };if !description.isEmpty { meta["description"]=description }
        let tagList=tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty };if !tagList.isEmpty { meta["tags"]=tagList }
        var images: Any=[String:Any]()
        if !imagesJSON.isEmpty,let data=imagesJSON.data(using:.utf8),let parsed=try? JSONSerialization.jsonObject(with:data) { images=parsed }
        let spec: [String:Any]=["id":id,"schema_version":1,"meta":meta,"images":images,"segments":segments.map(\.name).filter { !$0.isEmpty },"nodes":nodeSpecs,
            "gateway":rules.filter { !$0.host.isEmpty }.map { r -> [String:Any] in
                var g: [String:Any]=["host":r.host,"port":Int(r.port) ?? 0,"action":r.action]
                if !r.node.isEmpty { g["node"]=r.node }
                if r.action != "allow" { g["tripwire"]=r.tripwire;g["severity"]=r.severity }
                return g
            },"agent":["hostname":hostname.isEmpty ? "devbox" : hostname]]
        return (spec,files)
    }
}
