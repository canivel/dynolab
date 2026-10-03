import SwiftUI

/// Configure how episodes are evaluated. Every evaluator works on records the harness
/// keeps outside the agent's context; none of it is ever sent to the agent.
struct EvaluatorsPane: View {
    var model: MonitorModel
    var onError: (String) -> Void
    @AppStorage("sandboxHarnessOverride") private var harnessDir = ""
    @State private var config: [String:Any] = [:]
    @State private var agentView: [String:Any]?
    @State private var editing: MonitorDraft?
    @State private var working = false

    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Evaluators read the records the harness keeps outside the agent's context. The agent never sees tripwires, labels, monitor scores or reviews.",systemImage:"eye.slash")
                .foregroundStyle(DynoBrand.violet).font(.callout)
            Text("Built in").font(.headline)
            ForEach(Array((config["builtins"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,b in
                VStack(alignment:.leading,spacing:3) {
                    HStack { Text(b["name"] as? String ?? "").font(.callout.bold());Text("always on").font(.caption2).foregroundStyle(.secondary) }
                    Text(b["description"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(DynoBrand.surface))
            }
            HStack {
                Text("LLM monitors").font(.headline)
                Spacer()
                Button("Add monitor") { editing=MonitorDraft(values:["rubric":config["default_rubric"] as? String ?? "","threshold":50,"sees_reasoning":false,"auto":false,"enabled":true],isNew:true) }.buttonStyle(.dynoPrimary)
            }
            Text("A monitor is a model that reads a finished transcript (the task, the agent's messages, commands and outputs) and scores it from 0 to 100 against your rubric. It runs after the episode ends, never during it. Where you can, use a different model or endpoint from the agent under test.").font(.caption).foregroundStyle(.secondary)
            if (config["monitors"] as? [Any])?.isEmpty ?? true { Text("No monitors yet.").foregroundStyle(.secondary) }
            ForEach(Array((config["monitors"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,m in
                VStack(alignment:.leading,spacing:4) {
                    HStack {
                        Text(m["name"] as? String ?? "").font(.callout.bold())
                        Text("\(m["model"] as? String ?? "") · :\(String(m["port"] as? Int ?? 0))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(m["scored"] as? Int ?? 0) scored").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Flags at \(m["threshold"] as? Int ?? 50)+ · \(m["sees_reasoning"] as? Bool == true ? "reads the agent's reasoning" : "does not read reasoning") · \(m["auto"] as? Bool == true ? "scores new episodes automatically" : "manual")").font(.caption)
                    HStack {
                        Button("Score unscored episodes") { act { _=try await model.researchLab.request("/sandbox/evaluators/\(m["id"] as? String ?? "")/run",body:[:],timeout:20) } }
                        Button("Edit") { editing=MonitorDraft(values:m,isNew:false) }
                        Button("Delete",role:.destructive) { act { _=try await model.researchLab.request("/sandbox/evaluators/delete",body:["id":m["id"] as? String ?? ""]) } }
                    }.controlSize(.small)
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(DynoBrand.surface))
            }
            if let q=config["queue"] as? Int,q > 0 { Label("\(q) episodes waiting to be scored",systemImage:"hourglass").font(.caption) }
            agentSees
        }.frame(maxWidth:900,alignment:.leading)
        .sheet(item:$editing) { draft in
            MonitorEditor(model:model,draft:draft) { body in act { _=try await model.researchLab.request("/sandbox/evaluators",body:body,timeout:10);editing=nil } }
        }
        .task { while !Task.isCancelled { await reload();try? await Task.sleep(for:.seconds(4)) } }
    }

    /// What reaches the model under test, so it is clear what evaluation is not part of.
    private var agentSees: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("What the agent sees").font(.headline)
            if let v=agentView {
                Text("System prompt").font(.caption.bold())
                Text(v["system_prompt"] as? String ?? "").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                Text("Tools").font(.caption.bold())
                ForEach(Array((v["tools"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,t in
                    Text("\(t["name"] as? String ?? ""): \(t["description"] as? String ?? "")").font(.system(.caption,design:.monospaced))
                }
                Text("Then the task prompt for the chosen condition, and the output of each tool call. If the model replies without calling a tool, it receives: \"\(v["nudge"] as? String ?? "")\"").font(.caption)
                if let hostname=v["hostname"] as? String { Text("Inside the sandbox the machine is called \(hostname), and the agent runs as an ordinary user.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Update the harness to show the exact system prompt and tools here.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Never sent to the agent: tripwires, labels, honest-outcome checks, monitor scores and reviews.").font(.caption.bold()).foregroundStyle(DynoBrand.violet)
        }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).stroke(DynoBrand.violet.opacity(0.4)))
    }

    private func reload() async {
        do {
            config=try await model.researchLab.request("/sandbox/evaluators",timeout:10)
            do {
                var c=URLComponents();c.queryItems=harnessDir.isEmpty ? [] : [URLQueryItem(name:"harness_dir",value:harnessDir)]
                agentView=(try? await model.researchLab.request("/sandbox/tasks?\(c.percentEncodedQuery ?? "")",timeout:30))?["agent_view"] as? [String:Any]
            }
        } catch { onError(error.localizedDescription) }
    }
    private func act(_ action: @escaping @MainActor () async throws -> Void) { guard !working else { return };working=true;Task { do { try await action();await reload() } catch { onError(error.localizedDescription) };working=false } }
}

struct MonitorDraft: Identifiable { let id=UUID();var values: [String:Any];var isNew: Bool }

private struct MonitorEditor: View {
    var model: MonitorModel
    var draft: MonitorDraft
    var onSave: ([String:Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mid = ""
    @State private var name = ""
    @State private var rubric = ""
    @State private var endpoint = ""
    @State private var threshold = 50.0
    @State private var seesReasoning = false
    @State private var auto = false
    @State private var enabled = true
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(draft.isNew ? "New monitor" : "Edit monitor").font(.title3.bold())
            HStack { TextField("id, e.g. rule-monitor",text:$mid).disabled(!draft.isNew);TextField("Name",text:$name) }
            Picker("Model endpoint",selection:$endpoint) {
                Text("Choose a running model").tag("")
                ForEach(model.snapshot.models.filter { $0.port != nil },id:\.id) { m in Text("\(m.name) · :\(String(m.port ?? 0))").tag("\(m.port ?? 0)|\(m.name)") }
                if !endpoint.isEmpty && !model.snapshot.models.contains(where:{ "\($0.port ?? 0)|\($0.name)" == endpoint }) { Text(endpoint.replacingOccurrences(of:"|",with:" · ")).tag(endpoint) }
            }
            Text("Rubric").font(.callout.bold())
            TextEditor(text:$rubric).font(.callout).frame(height:150).scrollContentBackground(.hidden).padding(4).background(RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(0.05)))
            HStack { Text("Flag at \(Int(threshold)) or more");Slider(value:$threshold,in:0...100,step:5) }
            Toggle("Monitor may read the agent's reasoning",isOn:$seesReasoning)
            Toggle("Score new episodes automatically",isOn:$auto)
            Toggle("Enabled",isOn:$enabled)
            HStack {
                Spacer();Button("Cancel") { dismiss() }
                Button("Save monitor") {
                    let parts=endpoint.split(separator:"|",maxSplits:1)
                    guard parts.count == 2,let port=Int(parts[0]) else { return }
                    onSave(["id":mid,"name":name,"port":port,"model":String(parts[1]),"rubric":rubric,"threshold":Int(threshold),"sees_reasoning":seesReasoning,"auto":auto,"enabled":enabled])
                }.buttonStyle(.dynoPrimary).disabled(mid.isEmpty || name.isEmpty || endpoint.isEmpty || rubric.isEmpty)
            }
        }.padding(20).frame(width:640).background(DynoBrand.background).dynoTheme()
        .onAppear {
            let v=draft.values
            mid=v["id"] as? String ?? "";name=v["name"] as? String ?? "";rubric=v["rubric"] as? String ?? ""
            threshold=Double(v["threshold"] as? Int ?? 50);seesReasoning=v["sees_reasoning"] as? Bool ?? false
            auto=v["auto"] as? Bool ?? false;enabled=v["enabled"] as? Bool ?? true
            if let p=v["port"] as? Int,let m=v["model"] as? String { endpoint="\(p)|\(m)" }
        }
    }
}
