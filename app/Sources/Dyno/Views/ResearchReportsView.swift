import SwiftUI
import AppKit

struct ResearchReportsView: View {
    var model: MonitorModel
    var initialReportID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "regression"
    @State private var jobs: [[String:Any]] = []
    @State private var checkpointFields: [String:String] = [:]
    @State private var sourceJob = ""
    @State private var targetJob = ""
    @State private var studies: [[String:Any]] = []
    @State private var reports: [[String:Any]] = []
    @State private var selected: [String:Any] = [:]
    @State private var sources: [String:String] = [:]
    @State private var title = "Behavioral regression review"
    @State private var baseline = "baseline"
    @State private var comparison = "comparison"
    @State private var issue: String?
    @State private var busy = false
    private let metrics = ["target_behavior","correctness","refusal","honesty","monitor_detectability"]
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text("Research reports").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            Text("Compare labeled conditions across separate behavioral tests. Reports read saved evidence; they do not run a model.").foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                VStack(alignment:.leading) {
                    Button("New report") { selected = [:] }
                    List(Array(reports.enumerated()),id:\.offset) { _, r in
                        Button(r["title"] as? String ?? "Report") { perform { selected = try await model.researchLab.request("/reports/\(r["id"] as? String ?? "")") } }.buttonStyle(.plain)
                    }
                }.frame(minWidth:200,idealWidth:240,maxWidth:300)
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        if selected.isEmpty {
                            Picker("Report type",selection:$mode) { Text("Behavioral regression").tag("regression");Text("Artifact compatibility").tag("compatibility");Text("Checkpoint comparison").tag("checkpoints") }
                            if mode == "compatibility" {
                                Picker("Source probe job",selection:$sourceJob) { Text("Select job").tag("");ForEach(Array(jobs.enumerated()),id:\.offset) { _,job in Text("\(job["operation"] as? String ?? "") · \(job["id"] as? String ?? "")").tag(job["id"] as? String ?? "") } }
                                Picker("Target probe job",selection:$targetJob) { Text("Select job").tag("");ForEach(Array(jobs.enumerated()),id:\.offset) { _,job in Text("\(job["operation"] as? String ?? "") · \(job["id"] as? String ?? "")").tag(job["id"] as? String ?? "") } }
                                Text("Select completed grouped-probe jobs. Older jobs have unknown metadata and cannot pass strict compatibility. This check does not apply an artifact.")
                                Button("Check and save compatibility") { perform { selected = try await model.researchLab.request("/reports/compatibility",body:["source_job_id":sourceJob,"target_job_id":targetJob]);try await refresh() } }.disabled(busy || sourceJob.isEmpty || targetJob.isEmpty)
                            } else if mode == "checkpoints" { checkpointEditor } else {
                            DynoFormField("Report title",text:$title)
                            DynoFormField("Baseline condition ID",text:$baseline)
                            DynoFormField("Comparison condition ID",text:$comparison)
                            Text("Select a study for each metric you measured. Use its saved rubric to define a pass. Leave unmeasured metrics empty.")
                            ForEach(metrics,id:\.self) { metric in
                                Picker(metric.replacingOccurrences(of:"_",with:" ").capitalized,selection:Binding(get:{sources[metric] ?? ""},set:{sources[metric]=$0})) {
                                    Text("Not measured").tag("")
                                    ForEach(Array(studies.enumerated()),id:\.offset) { _, study in Text(study["title"] as? String ?? "Study").tag(study["id"] as? String ?? "") }
                                }
                            }
                            Button("Create saved report") { perform {
                                let items = metrics.compactMap { metric -> [String:String]? in guard let id=sources[metric], !id.isEmpty else { return nil }; return ["metric":metric,"study_id":id] }
                                selected = try await model.researchLab.request("/reports/regression",body:["title":title,"baseline":baseline,"comparison":comparison,"sources":items])
                                try await refresh()
                            } }.buttonStyle(.dynoPrimary).disabled(busy || sources.values.allSatisfy(\.isEmpty))
                            }
                        } else {
                            Text((selected["protocol"] as? [String:Any])?["title"] as? String ?? "Saved report").font(.title2.bold())
                            if let check=selected["compatibility"] as? [String:Any] {
                                Text("Eligibility: \(check["status"] as? String ?? "unknown")").font(.headline)
                                Text(check["explanation"] as? String ?? "")
                                ForEach(Array((check["fields"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _,field in
                                    DisclosureGroup("\(field["field"] as? String ?? ""): \(field["status"] as? String ?? "unknown")") { Text(ResearchLab.pretty(field)).font(.system(.caption,design:.monospaced)) }
                                }
                            }
                            ForEach(Array((selected["results"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _, result in
                                Text((result["metric"] as? String ?? "Metric").replacingOccurrences(of:"_",with:" ").capitalized).font(.headline)
                                Text(result["rubric"] as? String ?? "")
                                ForEach(Array((result["rows"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) { _, row in
                                    VStack(alignment:.leading,spacing:8) {
                                        Text("\(row["split"] as? String ?? "") · \(row["scored_pairs"] as? Int ?? 0)/\(row["planned_pairs"] as? Int ?? 0) pairs · \(row["independent_groups"] as? Int ?? 0) groups").font(.headline)
                                        Text("Improved: \(row["improved"] as? Int ?? 0) · Regressed: \(row["regressed"] as? Int ?? 0) · Unchanged: \(row["unchanged"] as? Int ?? 0)")
                                        if let delta=row["paired_delta"] as? Double { Text(String(format:"Group-weighted pass-rate difference: %+.3f",delta)) }
                                        if let ci=row["group_bootstrap_95"] as? [Double],ci.count==2 { Text(String(format:"95%% group bootstrap interval: %.3f to %.3f",ci[0],ci[1])) } else { Text("Uncertainty interval unavailable: fewer than two scored groups.") }
                                        DisclosureGroup("Pairs, exclusions and group measurements") { Text(ResearchLab.pretty(row)).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }
                                    }.padding().background(DynoBrand.surface,in:RoundedRectangle(cornerRadius:12))
                                }
                                Text(result["interpretation"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            if let note=selected["provenance_note"] as? String { Text(note).font(.caption) }
                            DisclosureGroup("Frozen sources and provenance") { Text(ResearchLab.pretty(selected)).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }
                            Button("Export report…") { let panel=NSSavePanel();panel.nameFieldStringValue="regression-report.json";if panel.runModal() == .OK,let url=panel.url { do { try ResearchLab.pretty(selected).write(to:url,atomically:true,encoding:.utf8) } catch { issue=error.localizedDescription } } }
                        }
                    }.padding()
                }.frame(minWidth:580,maxWidth:.infinity)
            }
        }.padding(20).frame(minWidth:920,minHeight:680).background(DynoBrand.background).dynoTheme()
        .task { perform { await model.researchLab.start();try await refresh(); if let initialReportID { selected = try await model.researchLab.request("/reports/\(initialReportID)") } } }
    }
    private var checkpointEditor: some View {
        VStack(alignment:.leading,spacing:12) {
            DynoFormField("Report title",text:$title)
            Text("Run an original study, prepare a reproduction, then run it on another checkpoint. Label both with the same rubric. Select those saved studies here. No training occurs.")
            ForEach(0..<2,id:\.self) { index in
                Text(index == 0 ? "Baseline checkpoint" : "Comparison checkpoint").font(.headline)
                Picker("Saved study",selection:field(index,"study_id",defaultValue:"")) {
                    Text("Select study").tag("")
                    ForEach(Array(studies.enumerated()),id:\.offset) { _,study in Text(study["title"] as? String ?? "Study").tag(study["id"] as? String ?? "") }
                }
                DynoFormField("Label",text:field(index,"label",defaultValue:index == 0 ? "Baseline" : "Comparison"))
                DynoFormField("Revision (or unknown)",text:field(index,"revision",defaultValue:"unknown"))
                DynoFormField("Training-data lineage (or unknown)",text:field(index,"training_data",defaultValue:"unknown"))
                DynoFormField("Adapter identity (none or unknown)",text:field(index,"adapter",defaultValue:"unknown"))
            }
            Button("Create checkpoint report") { perform {
                let items=(0..<2).map { i in ["study_id":field(i,"study_id",defaultValue:"").wrappedValue,"label":field(i,"label",defaultValue:i == 0 ? "Baseline" : "Comparison").wrappedValue,"revision":field(i,"revision",defaultValue:"unknown").wrappedValue,"training_data":field(i,"training_data",defaultValue:"unknown").wrappedValue,"adapter":field(i,"adapter",defaultValue:"unknown").wrappedValue] }
                selected=try await model.researchLab.request("/reports/checkpoints",body:["title":title,"sources":items]);try await refresh()
            } }.buttonStyle(.dynoPrimary).disabled(busy)
        }
    }
    private func field(_ i:Int,_ key:String,defaultValue:String) -> Binding<String> {
        let name="\(i).\(key)"
        return Binding(get:{checkpointFields[name] ?? defaultValue},set:{checkpointFields[name]=$0})
    }
    private func refresh() async throws {
        jobs = (try await model.researchLab.request("/jobs")["jobs"] as? [[String:Any]] ?? []).filter { $0["status"] as? String == "completed" }
        studies = try await model.researchLab.request("/studies")["studies"] as? [[String:Any]] ?? []
        reports = try await model.researchLab.request("/reports")["reports"] as? [[String:Any]] ?? []
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { busy=true;issue=nil;Task { do { try await action() } catch { issue=error.localizedDescription };busy=false } }
}
