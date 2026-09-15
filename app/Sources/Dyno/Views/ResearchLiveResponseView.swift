import SwiftUI

struct ResearchLiveResponseView: View {
    var journal: ResearchJournal
    var onClose: () -> Void = {}
    @State private var followLive = true
    var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(journal.running ? "Live response" : "Response finished", systemImage: "waveform").font(.title2.bold())
                    Spacer()
                    if journal.running { Button("Cancel request", role: .destructive) { journal.task?.cancel() } }
                    Button("Close") { onClose() }
                }
                Text(journal.running ? journal.liveStatus : "Review the saved timeline entry for completion status or errors.").foregroundStyle(.secondary)
                Toggle("Follow incoming text", isOn: $followLive).toggleStyle(.switch)
                liveText("Model-emitted thinking", text: journal.liveThinking, placeholder: "Waiting for thinking. Some models omit it or have thinking disabled.")
                Text("Model-emitted thinking is not a verified account of computation.").font(.caption).foregroundStyle(.secondary)
                liveText("Answer", text: journal.liveAnswer, placeholder: "Waiting for the answer. It may begin after thinking finishes.")
            }.padding(24).frame(minWidth: 680, idealWidth: 800, minHeight: 580)
    }
    private func liveText(_ title: String, text: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(text.isEmpty ? placeholder : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("tail")
                    }.padding(12)
                }.frame(minHeight: 150, maxHeight: .infinity)
                    .onChange(of: text) { _, _ in if followLive { reader.scrollTo("tail", anchor: .bottom) } }
            }.background(DynoBrand.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
