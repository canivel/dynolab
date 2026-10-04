import AppKit
import DynoKit
import SwiftUI

/// `Dyno.app/Contents/MacOS/Dyno --snapshot <directory>`
///
/// Renders the app's own views to PNG. This hosts them in a real, offscreen
/// `NSWindow` and asks the view hierarchy to draw itself, rather than using
/// `ImageRenderer`: SwiftUI's renderer cannot draw AppKit-backed controls —
/// segmented pickers and buttons come out blank or as placeholder blocks — and
/// the whole point here is to see what the controls actually look like.
///
/// Nothing is captured from the screen, so no Screen Recording permission is
/// involved.
@MainActor
enum ViewSnapshot {
    static func run(arguments: [String]) -> Int32 {
        let paths = arguments.filter { !$0.hasPrefix("--") }
        let directory = paths.first ?? FileManager.default.currentDirectoryPath
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        // Drawing needs a real app context even though nothing is shown.
        NSApplication.shared.setActivationPolicy(.accessory)

        let model = MonitorModel()
        // Snapshots can target a Lab service other than the one a running app owns.
        if let value = ProcessInfo.processInfo.environment["DYNO_LAB_PORT"], let port = UInt16(value) { model.researchLab.port = port }
        waitForData(model)
        model.selectRunningModelForSnapshot()
        let publication = arguments.contains("--public")
        if let rawPort = ProcessInfo.processInfo.environment["DYNO_POOL_CAPTURE_PORT"], let port = UInt16(rawPort) {
            var finished = false
            var captureFailure: String?
            Task {
                do {
                    let caps = try await model.researchLab.servingRequest(port: port, path: "capabilities")
                    guard let resident = caps["model"] as? String else { throw NSError(domain: "Snapshot", code: 1) }
                    await model.researchLab.captureServing(port: port, model: resident, parameters: [
                        "prompt": "The capital of France is", "layers": [4, 24], "max_input_tokens": 256
                    ])
                    if model.researchLab.servingResult["status"] as? String != "completed" {
                        captureFailure = ResearchLab.pretty(model.researchLab.servingResult)
                    }
                } catch { captureFailure = error.localizedDescription }
                finished = true
            }
            let deadline = Date().addingTimeInterval(80)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            guard finished, captureFailure == nil else {
                print(captureFailure ?? "Pool capture timed out")
                return 1
            }
            try? ResearchLab.pretty(model.researchLab.servingResult).write(
                toFile: directory + "/pool-capture.json", atomically: true, encoding: .utf8)
        } else if let fixture = ProcessInfo.processInfo.environment["DYNO_LAB_RESULT_FIXTURE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: fixture)),
           let job = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            model.researchLab.servingResult = job
            model.researchLab.job = job
            model.researchLab.journal.selected = nil
        } else if arguments.contains("--lab-only") {
            if let value = ProcessInfo.processInfo.environment["DYNO_LAB_PORT"], let port = UInt16(value) { model.researchLab.port = port }
            Task {
                await model.researchLab.start(); await model.researchLab.refresh()
                model.researchLab.selected = model.researchLab.jobs.first(where: { $0["status"] as? String == "completed" && (ProcessInfo.processInfo.environment["DYNO_LAB_OPERATION"] == nil || $0["operation"] as? String == ProcessInfo.processInfo.environment["DYNO_LAB_OPERATION"]) })?["id"] as? String
                await model.researchLab.refresh()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        }

        // Built lazily: constructing every view up front would run each one's
        // initialiser before the first capture.
        var targets: [(String, () -> AnyView, CGSize)] = [
            ("chat", { AnyView(MainWindow(model: model, chat: true)) },
             CGSize(width: 980, height: 620)),
            ("window-run", { AnyView(MainWindow(model: model, initialTab: .run)) },
             CGSize(width: 980, height: 620)),
            ("window-router", { AnyView(MainWindow(model: model, initialTab: .router)) },
             CGSize(width: 980, height: 760)),
            ("window-network", {
                model.shareRouterOnNetwork = true
                return AnyView(MainWindow(model: model, initialTab: .router))
            }, CGSize(width: 980, height: 620)),
            ("window-agents", { AnyView(MainWindow(model: model, initialTab: .agents)) },
             CGSize(width: 1300, height: 900)),
            ("window-lab", { AnyView(MainWindow(model: model, initialTab: .lab)) },
             CGSize(width: 1200, height: 850)),
            ("window-execution", { AnyView(MainWindow(model: model, initialTab: .execution)) },
             CGSize(width: 1100, height: 760)),
            ("window-inspect", {
                model.researchLab.tokenAnalysis = true
                return AnyView(MainWindow(model: model, initialTab: .lab))
            },
             CGSize(width: 1100, height: 1050)),
            ("window-observe", { AnyView(MainWindow(model: model, initialTab: .observe)) },
             CGSize(width: 980, height: 960)),
            ("window-discover", { AnyView(MainWindow(model: model, initialTab: .discover)) },
             CGSize(width: 980, height: 620)),
            ("menu-panel", { AnyView(DashboardPanel(model: model)) },
             CGSize(width: 320, height: 240)),
        ]

        if arguments.contains("--discover-only") {
            model.catalogFormat = .gguf
            model.searchCatalog("Qwen3-0.6B")
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            targets = [
                ("discover-gguf", { AnyView(DiscoverView(model: model)) }, CGSize(width: 1100, height: 740)),
                ("downloaded-gguf", { AnyView(DiscoverView(model: model, library: true)) }, CGSize(width: 1100, height: 500))
            ]
        }
        if arguments.contains("--gguf-only") {
            targets = [("window-gguf", { AnyView(MainWindow(model: model, initialTab: .run, modelFormat: "GGUF")) }, CGSize(width: 1100, height: 820))]
        }
        if arguments.contains("--pools-only") {
            if let path = ProcessInfo.processInfo.environment["DYNO_POOL_LOG_FIXTURE"],
               let log = try? String(contentsOfFile: path, encoding: .utf8) {
                let session = PoolSession()
                session.nearby.refresh()
                for line in log.components(separatedBy: "\n") { session.telemetry.consume(line) }
                session.telemetry.phase = "Recorded session"
                session.telemetry.ready = false; session.telemetry.active = false
                session.telemetry.measuredAt = nil
                targets = [("pool-recorded", { AnyView(PoolDashboard(session: session, model: model, recorded: true, presentation: true)) }, CGSize(width: 1100, height: 1050))]
            } else {
                targets = [("window-pools", { AnyView(MainWindow(model: model, initialTab: .pools)) }, CGSize(width: 1100, height: 820))]
            }
        }
        if arguments.contains("--notebooks-only") {
            var checked = false
            Task { await model.researchLab.runtime.refresh(model.snapshot.models); checked = true }
            let deadline = Date().addingTimeInterval(5)
            while !checked && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

            targets = [("research-notebooks", { AnyView(MainWindow(model: model, initialTab: .lab)) }, CGSize(width: 1300, height: 1100))]
        }
        if arguments.contains("--runtime-only") {
            targets = [("runtime-overview", { AnyView(RuntimeOverview(model: model, pool: PoolSession()).panel) }, CGSize(width: 460, height: 640))]
        }
        if arguments.contains("--monitor-only"), let sourceID = ProcessInfo.processInfo.environment["DYNO_STUDY_ID"] {
            targets = [("monitor-evaluation", { AnyView(MonitorEvaluationView(model: model, sourceID: sourceID, initialEvaluationID: ProcessInfo.processInfo.environment["DYNO_MONITOR_ID"])) }, CGSize(width: 1300, height: 1100))]
        }
        if arguments.contains("--reports-only") {
            targets = [("research-report", { AnyView(ResearchReportsView(model: model, initialReportID: ProcessInfo.processInfo.environment["DYNO_REPORT_ID"])) }, CGSize(width: 1300, height: 1050))]
        }
        if arguments.contains("--agents-only") {
            let episode = ProcessInfo.processInfo.environment["DYNO_EPISODE_KEY"]
            targets = [("window-agents", { AnyView(MainWindow(model: model, initialTab: .agents)) }, CGSize(width: 1400, height: 900))]
            if let episode { targets = [("agents-episode", { AnyView(AgentsView(model: model, initialEpisode: episode, initialTripwiresOnly: ProcessInfo.processInfo.environment["DYNO_ONLY_TRIPWIRES"] == "1").frame(maxWidth: .infinity, maxHeight: .infinity).background(DynoBrand.background).dynoTheme()) }, CGSize(width: 1400, height: 900))] }
        }
        if arguments.contains("--task-editor-only"), let path = ProcessInfo.processInfo.environment["DYNO_TASK_TEMPLATE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let section = ProcessInfo.processInfo.environment["DYNO_EDITOR_SECTION"]
            targets = [("task-editor", { AnyView(TaskEditorView(lab: model.researchLab, harnessDir: "", existingID: nil, template: detail, initialSection: section, onSaved: {})) }, CGSize(width: 1400, height: 900))]
        }
        if arguments.contains("--env-payload-only") {
            // Prints exactly what the editor saves for its starter environment, for end-to-end checks.
            var draft = EnvDraft.starter(); draft.id = "starter-check"
            if let (spec, files) = try? draft.payload(), let data = try? JSONSerialization.data(withJSONObject: ["spec": spec, "files": files], options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return 0
        }
        if arguments.contains("--env-editor-only") {
            targets = [("environment-editor", { AnyView(EnvironmentEditorView(lab: model.researchLab, harnessDir: "", existingID: nil, template: nil, onSaved: { _ in }, initialSection: ProcessInfo.processInfo.environment["DYNO_EDITOR_SECTION"])) }, CGSize(width: Double(ProcessInfo.processInfo.environment["DYNO_SNAP_W"] ?? "1200") ?? 1200, height: Double(ProcessInfo.processInfo.environment["DYNO_SNAP_H"] ?? "800") ?? 800))]
        }
        if arguments.contains("--environments-only"), let dir = ProcessInfo.processInfo.environment["DYNO_HARNESS_DIR"] {
            targets = [("agents-environments", { AnyView(EnvironmentsView(model: model, harnessDir: dir, tasks: [["id": "t4_quarterly_report", "environment": ["template": "segmented-office"]]], onRunStarted: { _ in }, onError: { print("error:", $0) }, initialSelection: ProcessInfo.processInfo.environment["DYNO_ENV_SELECT"]).frame(maxWidth: .infinity, maxHeight: .infinity).background(DynoBrand.background).dynoTheme()) }, CGSize(width: 1400, height: 900))]
        }
        if arguments.contains("--thread-only"), let key = ProcessInfo.processInfo.environment["DYNO_EPISODE_KEY"] {
            targets = [("agents-thread", { AnyView(ConversationThread(lab: model.researchLab, key: key, onError: { print("error:", $0) }, onBack: {}).frame(maxWidth: .infinity, maxHeight: .infinity).background(DynoBrand.background).dynoTheme()) }, CGSize(width: 1400, height: 900))]
        }
        if arguments.contains("--evaluators-only") {
            targets = [("evaluate-evaluators", { AnyView(ScrollView { EvaluatorsPane(model: model, onError: { print("error:", $0) }).padding(20) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DynoBrand.background).dynoTheme()) }, CGSize(width: 1100, height: 1000))]
        }
        if arguments.contains("--conversations-only") {
            targets = [("agents-conversations", { AnyView(ConversationsView(lab: model.researchLab, onError: { print("error:", $0) }).frame(maxWidth: .infinity, maxHeight: .infinity).background(DynoBrand.background).dynoTheme()) }, CGSize(width: 1400, height: 900))]
        }
        if arguments.contains("--evaluate-only") {
            targets = [("window-evaluate", { AnyView(MainWindow(model: model, initialTab: .evaluate)) }, CGSize(width: 1400, height: 900))]
        }
        if arguments.contains("--agent-only") {
            targets = [("simulated-agent", { AnyView(AgentTasksView(model: model, initialID: ProcessInfo.processInfo.environment["DYNO_AGENT_ID"])) }, CGSize(width: 1300, height: 1050))]
        }
        if arguments.contains("--study-summary-only"),
           let path = ProcessInfo.processInfo.environment["DYNO_SUMMARY_FILE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            targets = [("study-results", { AnyView(StudyResultsOverview(summary: summary, review: {}).padding(24).frame(width: 900).background(DynoBrand.background).dynoTheme()) }, CGSize(width: 900, height: 780))]
        }
        if arguments.contains("--new-study-only") {
            targets = [("new-study-form", { AnyView(NewResearchStudyForm(title: .constant(""), question: .constant(""), hypothesis: .constant(""), cancel: {}, create: {})) }, CGSize(width: 700, height: 700))]
        }
        if arguments.contains("--controlled-only") {
            targets = [("controlled-study", { AnyView(ControlledStudiesView(model: model, initialStudyID: ProcessInfo.processInfo.environment["DYNO_STUDY_ID"], initialEditorStep: Int(ProcessInfo.processInfo.environment["DYNO_STUDY_STEP"] ?? "0") ?? 0)) }, CGSize(width: 1300, height: 1000))]
        }
        if arguments.contains("--community-only") {
            let journal = model.researchLab.journal
            targets = [("study-import", { AnyView(StudyImportView(journal: journal)) }, CGSize(width: 660, height: 530))]
            if let study = journal.studies.first(where: { $0.id == journal.selected }) {
                targets.append(("study-sharing", { AnyView(StudySharingView(journal: journal, study: study)) }, CGSize(width: 740, height: 650)))
            }
        }
        if arguments.contains("--artifacts-only") {
            guard let path = ProcessInfo.processInfo.environment["DYNO_ARTIFACT_FIXTURE"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let artifact = try? LabArtifact.read(data) else { return 1 }
            targets = [("lab-artifacts", { AnyView(LabArtifactView(initialArtifact: artifact)) }, CGSize(width: 1100, height: artifact.kind == "generation" ? 1400 : 850))]
        }
        if publication {
            // Omit conversations, traces, connection addresses and filesystem views.
            let allowed = ["window-run", "window-observe", "window-discover", "menu-panel"]
            targets = targets.filter { allowed.contains($0.0) }
        }

        if arguments.contains("--token-only") {
            targets = targets.filter { $0.0 == "window-inspect" }
        }
        if arguments.contains("--execution-only") {
            targets = targets.filter { $0.0 == "window-execution" }
        }

        if arguments.contains("--lab-only") {
            targets = targets.filter { $0.0 == "window-lab" }
        }

        // Both appearances: a colour that reads in one and vanishes in the
        // other is the most common way this UI can be wrong.
        let appearances: [(String, NSAppearance.Name)] = [
            ("dark", .darkAqua), ("light", .aqua),
        ]

        // The popover is presented at whatever height the content asks for;
        // measure it unconstrained to be sure it fits on a screen.
        let probe = NSHostingView(rootView: AnyView(DashboardPanel(model: model)))
        probe.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let natural = probe.fittingSize
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 0
        print(String(format: "  panel natural height: %.0f pt (screen allows %.0f pt)%@",
                     natural.height, visibleHeight,
                     natural.height > visibleHeight ? "  ** TOO TALL **" : ""))

        if publication {
            for (suffix, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                let status = StatusItemController(model: model)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard status.writeSnapshot(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("menu-bar-\(suffix).png")) else { return 1 }
            }
        }
        var wrote = 0
        for (name, makeView, size) in targets {
            for (suffix, appearance) in appearances {
                model.selectRunningModelForSnapshot()
                let path = (directory as NSString)
                    .appendingPathComponent("\(name)-\(suffix).png")
                if capture(view: AnyView(makeView().dynoTheme()), size: size, appearance: appearance, to: path) {
                    wrote += 1
                } else {
                    print("  FAILED \(name)-\(suffix)")
                }
            }
            print("  wrote \(name) (dark + light)")
        }
        print("  models: \(model.localModels.count)  catalog: \(model.catalog.count)  "
              + "gpu: \(String(format: "%.0f%%", model.snapshot.gpu.busyPercent))")
        return wrote == targets.count * appearances.count ? 0 : 1
    }

    /// Let samples land and the catalog load, so the images show real numbers.
    private static func waitForData(_ model: MonitorModel) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if !model.catalog.isEmpty,
               !model.localModels.isEmpty,
               model.router.isReachable,
               model.snapshot.models.contains(where: { $0.stats != nil }),
               model.snapshot.interval > 0 { break }
        }
        // A little longer so async sizes and a second sample arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    }

    static func capture(
        view: AnyView, size: CGSize, appearance: NSAppearance.Name, to path: String
    ) -> Bool {
        // The AppKit appearance and the SwiftUI colour scheme have to be set
        // together. Setting only the former leaves SwiftUI drawing light text
        // onto a window AppKit painted light, which comes out blank.
        let isDark = appearance == .darkAqua
        let rooted = view
            .environment(\.colorScheme, isDark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: AnyView(rooted))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Set it application-wide: a per-window appearance does not reach
        // views AppKit hosts separately, such as a ScrollView's clip view,
        // which then renders light text on a light background.
        NSApp.appearance = NSAppearance(named: appearance)
        window.appearance = NSAppearance(named: appearance)
        hosting.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        // Positioned offscreen: ordered in so AppKit lays out and draws it, but
        // never visible to the user.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)

        hosting.layoutSubtreeIfNeeded()
        print("    [\((path as NSString).lastPathComponent)] natural size: "
              + "\(Int(hosting.fittingSize.width))x\(Int(hosting.fittingSize.height))")
        // Give SwiftUI a couple of runloop turns to settle its layout. Views that
        // load from a local service can ask for longer with DYNO_SNAPSHOT_SETTLE.
        let settle = Double(ProcessInfo.processInfo.environment["DYNO_SNAPSHOT_SETTLE"] ?? "") ?? 0.6
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.close()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
