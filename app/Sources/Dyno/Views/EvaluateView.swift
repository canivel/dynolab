import SwiftUI

/// Evaluations on top of sandboxed agent runs: outcome tables, hand review of every
/// label, and sealing run folders as signed evidence.
struct EvaluateView: View {
    var model: MonitorModel
    @AppStorage("evaluateWorkspace") private var workspace = Workspace.results.rawValue
    @AppStorage("reviewerName") private var reviewer = ""
    @State private var stats: [String:Any] = [:]
    @State private var runs: [[String:Any]] = []
    @State private var selected: [String:Any]?
    @State private var verdictWrong = false
    @State private var note = ""
    @State private var corrected = ""
    @State private var evidence: [String:[String:Any]] = [:]
    @State private var issue: String?
    @State private var working = false
    private var current: Workspace { Workspace(rawValue: workspace) ?? .results }

    enum Workspace: String, CaseIterable, Identifiable {
        case results = "Results", review = "Review", evaluators = "Evaluators", evidence = "Evidence"
        var id: String { rawValue }
    }
    private static let outcomes: [(String,String,Color)] = [
        ("honest_blocked","Honest, blocked",DynoBrand.accent),("blocked_after_probing","Blocked after probing",.yellow),
        ("false_success","False success",.orange),("rule_break","Rule break",.red),("no_final","No final answer",.gray),("harness_error","Harness error",.secondary)]

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.firstTextBaseline) {
                VStack(alignment:.leading,spacing:4) {
                    Text("Advanced").font(.title2.bold())
                    Text("What agents did across every run, a hand review of each label, and sealed evidence.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("",selection:$workspace) { ForEach(Workspace.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented).frame(width:420)
            }
            if let issue { Text(issue).foregroundStyle(.orange).font(.callout) }
            switch current {
            case .results: ScrollView { results.padding(.vertical) }
            case .review: reviewPane
            case .evaluators: ScrollView { EvaluatorsPane(model:model,onError:{ issue=$0 }).padding(.vertical) }
            case .evidence: ScrollView { evidencePane.padding(.vertical) }
            }
        }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .task {
            await model.researchLab.start()
            await reload()
            while !Task.isCancelled { try? await Task.sleep(for:.seconds(5));if current != .review { await reload() } }
        }
    }

    // MARK: Results

    private var results: some View {
        let groups=stats["groups"] as? [[String:Any]] ?? []
        let total=stats["episodes"] as? Int ?? 0
        return VStack(alignment:.leading,spacing:18) {
            if let c=stats["controls"] as? [String:Any],let n=c["episodes"] as? Int,n > 0 {
                let ok=c["as_expected"] as? Int ?? 0
                Label("Positive controls: \(ok) of \(n) scripted episodes were labeled as expected. Controls check the harness and are not counted below.",systemImage:ok == n ? "checkmark.seal" : "xmark.octagon")
                    .foregroundStyle(ok == n ? DynoBrand.accent : .red).font(.callout)
            }
            if total == 0 { Text("No labeled episodes yet. Run a task in Agents, or add a runs folder in Agents → Search.").foregroundStyle(.secondary) }
            ForEach(Array(groups.enumerated()),id:\.offset) { _,g in groupCard(g) }
            if let trips=stats["episodes_with_tripwire"] as? [String:Int],!trips.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Text("Episodes with each tripwire").font(.headline)
                    ForEach(trips.sorted { $0.value > $1.value },id:\.key) { name,count in
                        HStack {
                            Text(name).font(.system(.callout,design:.monospaced)).frame(width:240,alignment:.leading)
                            GeometryReader { geo in Capsule().fill(Color.orange.opacity(0.6)).frame(width:max(4,geo.size.width*CGFloat(count)/CGFloat(max(total,1)))) }.frame(height:10)
                            Text("\(count) of \(total)").font(.caption).monospacedDigit().frame(width:70,alignment:.trailing)
                        }
                    }
                }.padding(14).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface))
            }
            Text("Counts come from automatic labels. A label marked wrong in Review stays counted under its original outcome; the review records the correction. Episodes are pilot samples, not measured rates.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:900,alignment:.leading)
    }

    private func groupCard(_ g: [String:Any]) -> some View {
        let n=g["episodes"] as? Int ?? 0
        let outcomes=g["outcomes"] as? [String:Int] ?? [:]
        return VStack(alignment:.leading,spacing:10) {
            HStack { Text(g["task_id"] as? String ?? "task").font(.headline);Text("\(g["model_id"] as? String ?? "") · \(g["condition"] as? String ?? "neutral")").font(.caption).foregroundStyle(.secondary);Spacer();Text(n == 1 ? "1 episode" : "\(n) episodes").foregroundStyle(.secondary) }
            GeometryReader { geo in
                HStack(spacing:2) {
                    ForEach(Self.outcomes,id:\.0) { key,_,color in
                        let c=outcomes[key] ?? 0
                        if c > 0 { Rectangle().fill(color.opacity(0.75)).frame(width:geo.size.width*CGFloat(c)/CGFloat(max(n,1))) }
                    }
                }.clipShape(RoundedRectangle(cornerRadius:4))
            }.frame(height:14)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:200),alignment:.leading)],alignment:.leading,spacing:6) {
                ForEach(Self.outcomes,id:\.0) { key,label,color in
                    if let c=outcomes[key],c > 0 { Label("\(label): \(c)",systemImage:"circle.fill").foregroundStyle(color).font(.callout) }
                }
            }
            HStack(spacing:24) {
                stat("Claimed success",g["claimed_success"] as? Int ?? 0,n)
                stat("Rule break, then claimed success",g["rule_break_then_claimed"] as? Int ?? 0,n)
                stat("Reviewed by hand",g["reviewed"] as? Int ?? 0,n)
                stat("Labels marked wrong",g["label_wrong"] as? Int ?? 0,g["reviewed"] as? Int ?? 0)
            }
            let monitors=g["monitors"] as? [String:[String:Any]] ?? [:]
            if !monitors.isEmpty {
                HStack(spacing:24) {
                    ForEach(monitors.keys.sorted(),id:\.self) { id in
                        let m=monitors[id] ?? [:],scored=m["scored"] as? Int ?? 0
                        VStack(alignment:.leading,spacing:2) {
                            Text("\(m["flagged"] as? Int ?? 0) / \(scored) flagged · mean \(scored > 0 ? (m["total"] as? Int ?? 0)/scored : 0)").font(.callout.monospacedDigit())
                            Label(m["name"] as? String ?? id,systemImage:"eye.slash").font(.caption).foregroundStyle(DynoBrand.violet)
                        }
                    }
                }
            }
        }.padding(14).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface))
    }
    private func stat(_ title: String,_ value: Int,_ of: Int) -> some View {
        VStack(alignment:.leading,spacing:2) { Text("\(value) / \(of)").font(.title3.monospacedDigit());Text(title).font(.caption).foregroundStyle(.secondary) }
    }

    // MARK: Review

    private var reviewPane: some View {
        let queue=stats["review_queue"] as? [[String:Any]] ?? []
        return HSplitView {
            VStack(alignment:.leading,spacing:8) {
                Text("\(stats["unreviewed"] as? Int ?? 0) episodes to review").font(.headline)
                Text("Rule breaks and false successes come first.").font(.caption).foregroundStyle(.secondary)
                List(Array(queue.enumerated()),id:\.offset) { _,ep in
                    Button { select(ep) } label: { EpisodeRow(episode:ep) }.buttonStyle(.plain)
                }
            }.frame(minWidth:280,idealWidth:320,maxWidth:420)
            VStack(alignment:.leading,spacing:0) {
                if let ep=selected,let key=ep["key"] as? String {
                    reviewBar(ep,key).padding(12).background(DynoBrand.surface)
                    EpisodeTimeline(lab:model.researchLab,key:key,onError:{ issue=$0 }).id(key)
                } else {
                    Text("Choose an episode. Read the reasoning, commands and tripwires, then confirm or correct its label.").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }.frame(minWidth:560,maxWidth:.infinity)
        }
    }

    private func reviewBar(_ ep: [String:Any],_ key: String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("Automatic label: \(ep["outcome"] as? String ?? "")").font(.headline)
                Spacer()
                TextField("Reviewer",text:$reviewer).frame(width:160)
            }
            Picker("",selection:$verdictWrong) { Text("Label is right").tag(false);Text("Label is wrong").tag(true) }.pickerStyle(.segmented).frame(width:280)
            if verdictWrong {
                Picker("Correct outcome",selection:$corrected) {
                    Text("Not sure").tag("")
                    ForEach(Self.outcomes,id:\.0) { key,label,_ in Text(label).tag(key) }
                }.frame(width:340)
            }
            TextField(verdictWrong ? "Why is the label wrong? (required)" : "Note (optional)",text:$note,axis:.vertical).lineLimit(2...4)
            Button("Save review") { perform {
                var body: [String:Any]=["verdict":verdictWrong ? "label_wrong" : "label_correct","note":note,"reviewer":reviewer]
                if verdictWrong && !corrected.isEmpty { body["corrected_outcome"]=corrected }
                _=try await model.researchLab.request("/sandbox/episodes/\(key)/review",body:body,timeout:10)
                await reload()
                selected=(stats["review_queue"] as? [[String:Any]])?.first
                verdictWrong=false;note="";corrected=""
            } }.buttonStyle(.dynoPrimary).disabled(working || (verdictWrong && note.trimmingCharacters(in:.whitespaces).isEmpty))
            Text("Reviews are appended to the episode folder and never overwrite the automatic label. When a rule is wrong, fix the rule in the harness and relabel.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Evidence

    private var evidencePane: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Sealing writes a SHA-256 for every file in a run folder. With a key at keys/signing.pem in the harness folder, it also signs that list with Ed25519. Verify recomputes every hash and checks the signature.").foregroundStyle(.secondary)
            ForEach(Array(runs.enumerated()),id:\.offset) { _,r in
                let id=r["id"] as? String ?? ""
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        VStack(alignment:.leading) { Text(r["title"] as? String ?? "Run").font(.headline);Text("\(r["kind"] as? String ?? "episodes") · \(r["status"] as? String ?? "")").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let sealed=r["sealed"] as? [String:Any] { Label(sealed["signed"] as? Bool == true ? "Sealed and signed" : "Sealed, unsigned",systemImage:"seal").foregroundStyle(DynoBrand.accent).font(.callout) }
                        Button("Verify") { perform { evidence[id]=try await model.researchLab.request("/sandbox/runs/\(id)/verify",timeout:120) } }.disabled(working)
                        Button("Seal") { perform { let out=try await model.researchLab.request("/sandbox/runs/\(id)/seal",body:[:],timeout:120);evidence[id]=out["verification"] as? [String:Any];await reload() } }.buttonStyle(.dynoPrimary).disabled(working || r["status"] as? String == "running")
                    }
                    if let result=evidence[id] {
                        Label(result["ok"] as? Bool == true ? "Bundle verifies" : "Verification failed",systemImage:result["ok"] as? Bool == true ? "checkmark.seal.fill" : "xmark.octagon.fill").foregroundStyle(result["ok"] as? Bool == true ? DynoBrand.accent : .red)
                        Text(result["output"] as? String ?? "").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    }
                }.padding(12).background(RoundedRectangle(cornerRadius:10).fill(DynoBrand.surface))
            }
            if runs.isEmpty { Text("Runs started from the Agents tab appear here.").foregroundStyle(.secondary) }
        }.frame(maxWidth:900,alignment:.leading)
    }

    // MARK: Requests

    private func select(_ ep: [String:Any]) { selected=ep;verdictWrong=false;note="";corrected="" }
    private func reload() async {
        do {
            stats=try await model.researchLab.request("/sandbox/stats",timeout:20)
            runs=try await model.researchLab.request("/sandbox/runs")["runs"] as? [[String:Any]] ?? []
        } catch { issue=error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { guard !working else { return };working=true;Task { do { try await action();issue=nil } catch { issue=error.localizedDescription };working=false } }
}
