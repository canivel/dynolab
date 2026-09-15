import AppKit
import DynoKit
import SwiftUI

/// Replays a local, explicit protocol through the same journal and streaming request path as the UI.
@MainActor enum JournalBatch {
    struct Plan: Decodable {
        let title: String
        let question: String
        let hypothesis: String
        let protocolNote: String
        let cases: [Case]
    }
    struct Case: Decodable { let title: String; let input: ResearchIteration }
    static func run(_ args: [String]) -> Int32 {
        guard let index = args.firstIndex(of: "--journal-batch"), args.count > index + 1 else { return 2 }
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: args[index + 1])))
            let journal = ResearchJournal()
            journal.create(title: plan.title, question: plan.question, hypothesis: plan.hypothesis)
            guard let study = journal.selected, journal.error == nil else { print(journal.error ?? "Create failed"); return 1 }
            guard journal.save(ResearchEntry(kind: "note", title: "Protocol frozen before generation", body: plan.protocolNote)) else { return 1 }
            print("STUDY \(study.uuidString)"); fflush(stdout)
            let captureDirectory = args.firstIndex(of: "--capture").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            if let captureDirectory { try FileManager.default.createDirectory(atPath: captureDirectory, withIntermediateDirectories: true); NSApplication.shared.setActivationPolicy(.accessory) }
            for (caseIndex, item) in plan.cases.enumerated() {
                journal.input = item.input; journal.parent = nil; journal.runTitle = item.title
                journal.run()
                var capturedThinking = false; var capturedAnswer = false
                while journal.running {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    if let directory = captureDirectory {
                        let phase = !capturedThinking && journal.liveThinking.count > 160 ? "thinking" : !capturedAnswer && journal.liveAnswer.count > 120 ? "answer" : nil
                        if let phase {
                            _ = ViewSnapshot.capture(view: AnyView(ResearchLiveResponseView(journal: journal).dynoTheme()), size: CGSize(width: 900, height: 740), appearance: .darkAqua, to: directory + "/case-\(caseIndex)-\(phase).png")
                            if phase == "thinking" { capturedThinking = true } else { capturedAnswer = true }
                        }
                    }
                }
                guard journal.pendingWrites.isEmpty else { print("Unsaved evidence; stopped"); return 1 }
                let entry = journal.entries.last(where: { ["result", "error", "cancelled"].contains($0.kind) })
                print("CASE \(item.title): \(entry?.kind ?? "missing") / \(entry?.finishReason ?? "unknown") / answer \(entry?.answer?.count ?? 0) characters"); fflush(stdout)
                if entry?.kind != "result" { print("Stopped after failure. No automatic retry."); return 1 }
            }
            print("SAVED \(journal.store.folder(study).path)"); return 0
        } catch { print(error); return 1 }
    }
}
