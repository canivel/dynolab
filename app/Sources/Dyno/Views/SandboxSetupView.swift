import AppKit
import SwiftUI

/// First run: what this Mac still needs before agents can run in the sandbox. It lists each piece, why it's
/// needed and what setup will do, and installs nothing until the person agrees. Then it sets up and runs the
/// isolation checks, so the first test can start right away.
struct SandboxSetupView: View {
    var lab: ResearchLab
    var onClose: (_ ready: Bool) -> Void
    @AppStorage("sandboxHarnessOverride") private var harnessDir = ""

    enum Phase { case looking, review, settingUp, checking, ready, failed }
    @State private var phase = Phase.looking
    @State private var report: [String: Any] = [:]
    @State private var engine: [String: Any] = [:]
    @State private var readiness: [String: Any] = [:]
    @State private var issue: String?

    private var items: [[String: Any]] { report["items"] as? [[String: Any]] ?? [] }
    private var blocked: [[String: Any]] { items.filter { $0["ok"] as? Bool != true && ($0["fix"] as? [String: Any])?["auto"] as? Bool == false } }
    private var installs: Bool { items.contains { $0["ok"] as? Bool == false && (($0["fix"] as? [String: Any])?["label"] as? String)?.hasPrefix("Install") == true } }
    private var setupSteps: [[String: Any]] { (engine["setup"] as? [String: Any])?["steps"] as? [[String: Any]] ?? [] }
    private var checks: [[String: Any]] {
        let done = readiness["checks"] as? [[String: Any]] ?? []
        return done.isEmpty ? readiness["progress"] as? [[String: Any]] ?? [] : done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(phase == .ready ? "The sandbox is ready" : "Set up the agent sandbox").font(.title2.bold())
                Text("Dyno runs every agent inside an isolated container on this Mac, so whatever it does can't reach your files or the internet. "
                     + (phase == .ready ? "Every isolation check passed." : "Here's what this Mac still needs. Nothing is installed until you agree."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch phase {
                    case .looking: HStack { DynoSpinner(); Text("Looking at this Mac…").foregroundStyle(.secondary) }
                    case .review, .failed where setupSteps.isEmpty && checks.isEmpty: requirements
                    default: progress
                    }
                    if let issue { Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 260)
            footer
        }
        .padding(24).frame(width: 600, height: 560)
        .task { await look() }
    }

    // MARK: What's needed

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in requirement(item) }
        }
    }

    private func requirement(_ item: [String: Any]) -> some View {
        let ok = item["ok"] as? Bool
        let fix = item["fix"] as? [String: Any]
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == nil ? "questionmark.circle" : "circle")
                .foregroundStyle(ok == true ? DynoBrand.accent : ok == nil ? Color.secondary : Color.orange).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item["name"] as? String ?? "").font(.headline)
                    Text(item["detail"] as? String ?? "").font(.callout).foregroundStyle(.secondary)
                }
                Text(item["why"] as? String ?? "").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fix { fixLine(fix) }
            }
        }
    }

    @ViewBuilder private func fixLine(_ fix: [String: Any]) -> some View {
        let label = fix["label"] as? String ?? ""
        if fix["auto"] as? Bool == false, let manual = fix["manual"] as? String {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.callout.weight(.medium))
                if manual.hasPrefix("http") {
                    Link(manual, destination: URL(string: manual)!).font(.callout)
                } else {
                    Text(manual).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(DynoBrand.surface))
                    HStack {
                        Button("Copy command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(manual, forType: .string) }
                        Button("Open Terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                    }.controlSize(.small)
                }
            }.padding(.top, 2)
        } else {
            let minutes = fix["minutes"] as? Int ?? 0
            let needs = (fix["needs"] as? [String] ?? []).contains("internet") ? " · downloads from the internet" : ""
            Text("\(fix["if_missing"] as? Bool == true ? "If it's missing, setup will: " : "Setup will: ")\(label)\(minutes > 0 ? " · about \(minutes) min" : "")\(needs)")
                .font(.callout).foregroundStyle(DynoBrand.violet).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Setting up

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase == .settingUp || !setupSteps.isEmpty { Text("Setup").font(.headline) }
            ForEach(Array(setupSteps.enumerated()), id: \.offset) { _, s in row(s["name"] as? String ?? "", s["passed"] as? Bool, s["detail"] as? String) }
            if phase == .settingUp { HStack { DynoSpinner(); Text("Working. Installs and the first image build take a few minutes.").font(.callout).foregroundStyle(.secondary) } }
            if phase == .checking || !checks.isEmpty {
                Text("Isolation checks").font(.headline).padding(.top, 8)
                ForEach(Array(checks.enumerated()), id: \.offset) { _, c in row(c["name"] as? String ?? "", c["passed"] as? Bool, c["detail"] as? String) }
                if phase == .checking { HStack { DynoSpinner(); Text("A throwaway container is started and removed.").font(.callout).foregroundStyle(.secondary) } }
            }
        }
    }

    private func row(_ name: String, _ passed: Bool?, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: passed == true ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(passed == true ? DynoBrand.accent : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout)
                if let detail, !detail.isEmpty, passed != true || detail.count < 80 {
                    Text(detail).font(.caption).foregroundStyle(passed == true ? Color.secondary : Color.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Buttons

    private var footer: some View {
        HStack {
            if phase == .review || phase == .failed {
                let minutes = report["minutes"] as? Int ?? 0
                if minutes > 0 { Text("About \(minutes) min\(report["downloads"] as? Bool == true ? ", needs internet" : "")").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch phase {
            case .looking, .settingUp, .checking:
                Button("Continue in the background") { onClose(false) }
            case .review:
                Button("Not now") { onClose(false) }
                if !blocked.isEmpty { Button("Check again") { Task { await look() } } }
                Button(installs ? "Install and set up" : "Set up") { Task { await setUp() } }
                    .buttonStyle(.dynoPrimary).disabled(!blocked.isEmpty).keyboardShortcut(.defaultAction)
            case .failed:
                Button("Not now") { onClose(false) }
                Button("Start over") { Task { await look() } }.buttonStyle(.dynoPrimary)
            case .ready:
                Button("Done") { onClose(true) }.buttonStyle(.dynoPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Requests

    private var query: String { harnessDir.isEmpty ? "" : "?harness_dir=\(harnessDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }

    private func look() async {
        phase = .looking; issue = nil; engine = [:]; readiness = [:]
        await lab.start()
        do {
            report = try await lab.request("/sandbox/engine/doctor\(query)", timeout: 160)
            if report["ok"] as? Bool == true { await check() } else { phase = .review }
        } catch {
            issue = "Couldn't look at this Mac: \(error.localizedDescription)"; phase = .failed
        }
    }

    private func setUp() async {
        phase = .settingUp; issue = nil
        do {
            // The list they just agreed to is what may be installed; setup skips whatever is already in place.
            engine = try await lab.request("/sandbox/engine/setup", body: ["harness_dir": harnessDir, "install_runtime": true], timeout: 15)
            while true {
                try await Task.sleep(for: .seconds(1))
                engine = try await lab.request("/sandbox/engine\(query)", timeout: 30)
                if engine["setup_running"] as? Bool != true { break }
            }
            let setup = engine["setup"] as? [String: Any]
            guard setup?["ok"] as? Bool == true else {
                issue = setup?["error"] as? String ?? "Setup didn't finish. The step in red says why; fix it, then start over."
                phase = .failed; return
            }
            await check()
        } catch { issue = error.localizedDescription; phase = .failed }
    }

    private func check() async {
        phase = .checking
        do {
            readiness = try await lab.request("/sandbox/readiness", body: ["harness_dir": harnessDir], timeout: 10)
            // The service stops checks that run past five minutes, so this ends.
            while readiness["running"] as? Bool != false || readiness["ok"] as? Bool == nil {
                try await Task.sleep(for: .seconds(1))
                readiness = try await lab.request("/sandbox/readiness", timeout: 10)
            }
            if readiness["ok"] as? Bool == true { phase = .ready }
            else { issue = readiness["error"] as? String ?? "A check failed. Its detail in red says why."; phase = .failed }
        } catch { issue = error.localizedDescription; phase = .failed }
    }
}
