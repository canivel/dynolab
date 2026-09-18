import SwiftUI

/// The review endpoint returns an allowlisted answer view, never the raw study.
struct BlindStudyReviewView: View {
    let lab: ResearchLab
    let studyID: String
    @Environment(\.dismiss) private var dismiss
    @State private var reviewer = ""
    @State private var priorExposure = true
    @State private var session: [String: Any] = [:]
    @State private var index = 0
    @State private var note = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmReveal = false
    private var items: [[String: Any]] { session["items"] as? [[String: Any]] ?? [] }
    private var revealed: Bool { session["revealed_at"] is NSNumber }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Review responses", systemImage: "eye.slash").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.disabled(working)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if session.isEmpty {
                Text("Review answers with condition and model labels hidden").font(.headline)
                Text("You will see the shared prompt, rubric and answer. Instructions specific to each condition, thinking, model identity and other reviewers’ labels are hidden. The wording of an answer can still reveal its context.")
                DynoFormField("Your reviewer name", text: $reviewer)
                Toggle("I have already seen these responses or their condition assignments", isOn: $priorExposure)
                Text("This records your prior exposure; it cannot undo it. Local names are not authenticated. Use a different reviewer for an independent review. The same name resumes its saved queue, including any previous reveal.").font(.caption).foregroundStyle(.secondary)
                Button("Start or resume review") {
                    request("prepare-review", ["reviewer": reviewer, "prior_exposure": priorExposure])
                }.buttonStyle(.dynoPrimary).disabled(working || reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Text("\(session["reviewed"] as? Int ?? 0) of \(items.count) responses reviewed · \(session["reviewer"] as? String ?? "")").font(.headline)
                Text(revealed ? "Context revealed. Further labels are recorded as made after reveal." : "Condition and model context hidden. Response order is shuffled and saved.")
                    .foregroundStyle(revealed ? .orange : .secondary)
                Text(session["prior_exposure"] as? Bool == true ? "Reviewer reported prior exposure." : "Reviewer reported no prior exposure.").font(.caption)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Rubric").font(.headline)
                        Text(session["rubric"] as? String ?? "").textSelection(.enabled)
                        if items.indices.contains(index) {
                            let item = items[index]
                            Text("Response \(index + 1) of \(items.count)").font(.title3.bold())
                            Text("Shared prompt").font(.headline)
                            Text(item["prompt"] as? String ?? "").textSelection(.enabled)
                            Text("Answer").font(.headline)
                            Text(item["answer"] as? String ?? "").textSelection(.enabled)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 10))
                            if let context = item["context"] as? [String: Any] {
                                Text(ResearchLab.pretty(context)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            DynoFormField("Review note (optional)", text: $note, axis: .vertical).lineLimit(2...5)
                            StudyGradeButtons(selected: (item["labels"] as? [[String: Any]])?.last?["value"] as? String,
                                              saving: working, disabled: working) { value in
                                request("review-label", ["review_id": session["id"] as? String ?? "", "item_id": item["id"] as? String ?? "", "value": value, "note": note])
                            }
                            ForEach(Array((item["labels"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, label in
                                VStack(alignment: .leading) {
                                    Text("Saved: \(label["value"] as? String ?? "") · \(label["context_hidden"] as? Bool == true ? "context hidden" : "after reveal")").font(.caption.bold())
                                    Text(label["note"] as? String ?? "").font(.caption)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Previous") { index -= 1; note = "" }.disabled(index == 0 || working)
                    Button("Next") { index += 1; note = "" }.disabled(index + 1 >= items.count || working)
                    Spacer()
                    Button("Reveal conditions and model") { confirmReveal = true }.disabled(revealed || working)
                }
                Text(session["limitation"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(minWidth: 740, idealWidth: 840, minHeight: 640, alignment: .topLeading)
        .background(DynoBrand.background).dynoTheme()
        .confirmationDialog("Reveal context permanently for this review?", isPresented: $confirmReveal) {
            Button("Reveal context") { request("reveal-review", ["review_id": session["id"] as? String ?? ""]) }
        } message: {
            Text("\(session["reviewed"] as? Int ?? 0) of \(items.count) responses have a saved label. Existing labels keep their context-hidden status; future labels will be marked after reveal.")
        }
    }

    private func request(_ action: String, _ body: [String: Any]) {
        guard !working else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                session = try await lab.request("/studies/\(studyID)/\(action)", body: body)
                if action == "review-label" { note = "" }
            } catch { self.error = error.localizedDescription }
        }
    }
}
