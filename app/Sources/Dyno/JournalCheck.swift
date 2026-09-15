import AppKit
import DynoKit

/// Local integration check. Uses a caller-supplied loopback endpoint and an isolated notebook directory.
@MainActor enum JournalCheck {
    static func run(_ args: [String]) -> Int32 {
        guard let index = args.firstIndex(of: "--journal-check"), args.count > index + 3,
              let port = UInt16(args[index + 2]) else {
            print("Usage: --journal-check <output-directory> <port> <model-id>"); return 2
        }
        let store = ResearchNotebook(directory: URL(fileURLWithPath: args[index + 1]))
        let journal = ResearchJournal(store: store)
        journal.create(title: "Notebook integration check (test data)", question: "Do saved revisions and follow-ups preserve context?", hypothesis: "Two completions remain separate.")
        journal.input.model = args[index + 3]; journal.input.port = port; journal.input.maxTokens = 128
        if args.contains("--thinking-off") { journal.input.thinking = "off" }
        journal.input.prompt = "Reply with a short greeting."; journal.run()
        let deadline = Date().addingTimeInterval(120)
        while journal.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard !journal.running, let result = journal.entries.last(where: { $0.kind == "result" }), result.hasFinalAnswer && !result.hitTokenLimit else { print(journal.error ?? "Missing initial result"); journal.task?.cancel(); return 1 }
        journal.revise(result, followup: true); journal.input.prompt = "What did I ask you to do in my first message?"; journal.run()
        while journal.running && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard !journal.running, let study = journal.selected else { journal.task?.cancel(); return 1 }
        _ = journal.save(ResearchEntry(kind: "note", title: "Workflow observation", body: "Integration test only; these outputs are not a research finding.", parent: result.id))
        do {
            let reopened = try store.entries(study)
            let results = reopened.filter { $0.kind == "result" }
            guard results.count == 2, results.contains(where: { $0.id == result.id }), results.contains(where: { $0.iteration?.context.count == 2 }) else { print("Context or persistence check failed"); return 1 }
            print("PASS: two saved completions, preserved parent answer, follow-up context, note, reopen. \(store.folder(study).path)"); return 0
        } catch { print(error); return 1 }
    }
}
