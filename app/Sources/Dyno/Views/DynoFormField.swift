import SwiftUI

/// Shared research-form field: persistent label, quiet example and visible focus.
struct DynoFormField: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var hint = ""
    var example = ""
    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal, hint: String = "", example: String = "") {
        self.title = title; self._text = text; self.axis = axis; self.hint = hint; self.example = example
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold))
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            TextField(title, text: $text, prompt: Text(focused ? "" : example), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(axis == .vertical ? 3...8 : 1...2)
                .font(.system(size: 14)).focused($focused)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(DynoBrand.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? DynoBrand.lime : Color.primary.opacity(0.22), lineWidth: focused ? 2 : 1))
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DynoFormGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            configuration.label.font(.title3.bold())
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20).background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct NewResearchStudyForm: View {
    @Binding var title: String
    @Binding var question: String
    @Binding var hypothesis: String
    var cancel: () -> Void
    var create: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("New research study", systemImage: "book.closed").font(.title2.bold())
                Spacer()
                Button("Close", action: cancel)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("What do you want to investigate?").font(.title2.bold())
                    Text("Start with a question. Keep your prompts, results and observations together as the study develops.").foregroundStyle(.secondary)
                    DynoFormField("Study name", text: $title, hint: "A short name you can recognize in your study list.", example: "e.g. Release decisions under user pressure")
                    DynoFormField("Research question", text: $question, axis: .vertical, hint: "Describe the behavior you want to test.", example: "e.g. Does disagreement change the model’s assessment without new evidence?")
                    DynoFormField("Initial hypothesis · optional", text: $hypothesis, axis: .vertical, hint: "What do you expect, and what result would contradict it?", example: "e.g. The assessment stays the same when the facts stay the same.")
                }.padding(24)
            }
            Divider()
            HStack {
                Text("Saved locally. Creating a study does not run a model.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                Button("Create study", action: create).buttonStyle(.dynoPrimary)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(20).background(DynoBrand.surface)
        }.frame(width: 700, height: 700).background(DynoBrand.background).dynoTheme()
    }
}
