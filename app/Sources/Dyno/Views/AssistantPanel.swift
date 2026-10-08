import SwiftUI

/// Dyno's assistant, beside every tab. Describe what you want to find out, by text or voice; the assistant (a
/// model running on this Mac) plans it, looks at what Dyno has, fills in the screens for you to check, and asks
/// before it runs or saves anything. Conversations are saved on this Mac by the lab service.
struct AssistantPanel: View {
    var model: MonitorModel
    var onMinimize: () -> Void
    var onPlainChat: () -> Void

    @AppStorage("assistantModel") private var modelID = ""
    @AppStorage("roomDraft") private var storedDraft = ""
    @State private var text = ""
    @State private var spoken = ""   // what the text held when voice started
    @State private var voice = VoiceInput()
    @State private var showPlan = true
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var note = ""
    @FocusState private var focused: Bool

    private var session: AssistantSession { model.assistant }

    private var servers: [(port: Int, model: String, name: String)] {
        model.snapshot.models.compactMap { s in
            guard let p = s.port, !s.identifier.isEmpty else { return nil }
            return (Int(p), s.identifier, s.name)
        }
    }
    private var chosen: (port: Int, model: String, name: String)? { servers.first { $0.model == modelID } ?? servers.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !session.plan.isEmpty { planView; Divider() }
            if chosen == nil {
                noModel
            } else {
                transcript
                Divider()
                composer
            }
        }
        .background(DynoBrand.background)
        .onAppear { session.attach(model.researchLab) }
        .onChange(of: voice.transcript) { _, t in if voice.listening || !t.isEmpty { text = spoken + t } }
        // Reopening a conversation picks the model it used, if that model is running.
        .onChange(of: session.conversationModel) { _, m in if let m, servers.contains(where: { $0.model == m }) { modelID = m } }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename conversation").font(.headline)
                TextField("Title", text: $newTitle).textFieldStyle(.roundedBorder).frame(width: 320)
                HStack { Spacer(); Button("Cancel") { renaming = false }
                    Button("Rename") { Task { await session.rename(newTitle); renaming = false } }.buttonStyle(.dynoPrimary) }
            }.padding(20).dynoTheme()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(DynoBrand.accent)
                Menu {
                    Button("New conversation") { Task { await session.newConversation() } }
                    if !session.conversations.isEmpty {
                        Divider()
                        ForEach(session.conversations.prefix(20).indices, id: \.self) { i in
                            let c = session.conversations[i]
                            Button((c["id"] as? String == session.conversationID ? "✓ " : "") + (c["title"] as? String ?? "Conversation")) {
                                if let id = c["id"] as? String { Task { await session.open(id) } }
                            }
                        }
                    }
                    Divider()
                    Button("Rename…") { newTitle = session.title; renaming = true }.disabled(session.conversationID == nil)
                    Button("Delete this conversation", role: .destructive) {
                        if let id = session.conversationID { Task { await session.delete(id) } }
                    }.disabled(session.conversationID == nil || session.busy)
                    Divider()
                    Button("Plain chat with a model (full window)") { onPlainChat() }
                } label: {
                    Text(session.title.isEmpty ? "Assistant" : session.title).font(.callout.weight(.semibold)).lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                contextMeter
                Menu {
                    Picker("Context budget", selection: Binding(get: { session.budget }, set: { b in Task { await session.setSettings(budget: b) } })) {
                        ForEach([8192, 16384, 32768, 65536, 131072], id: \.self) { Text("\($0 / 1024)K tokens").tag($0) }
                    }
                    Toggle("Think before answering (slower)", isOn: Binding(get: { session.thinking }, set: { t in Task { await session.setSettings(thinking: t) } }))
                } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(session.conversationID == nil)
                    .help("How much of the model's context this conversation may use, and whether it thinks first")
                Button(action: onMinimize) { Image(systemName: "sidebar.right") }.buttonStyle(.plain)
                    .help("Minimize the assistant (⌘J)")
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                if servers.isEmpty {
                    Text("No local model running").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(get: { chosen?.model ?? "" }, set: { modelID = $0 })) {
                        ForEach(servers, id: \.model) { s in Text("\(s.name) · :\(String(s.port))").tag(s.model) }
                    }.labelsHidden().controlSize(.small).frame(maxWidth: 240)
                }
                Text("on this Mac").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }.help("The assistant only uses a model running on this Mac, and keeps conversations here.")
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// How much of the model's context window the conversation uses, and whether older turns were summarized.
    private var contextMeter: some View {
        let use = session.contextUse ?? [:]
        let used = use["estimated_tokens"] as? Int ?? 0
        let budget = use["budget"] as? Int ?? session.budget
        let fraction = budget > 0 ? Double(used) / Double(budget) : 0
        let summarized = (use["summarized_upto"] as? Int ?? 0) > 0
        return HStack(spacing: 4) {
            ProgressView(value: min(1, fraction)).progressViewStyle(.linear).frame(width: 34).tint(fraction > 0.8 ? .orange : DynoBrand.accent)
            Text("\(used / 1000)k/\(budget / 1024)k").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }.help("About \(used.formatted()) of \(budget.formatted()) tokens of the model's context."
               + (summarized ? " Older turns were summarized by the model to make room; the full conversation is still saved." : "")
               + " Its thinking is never sent back, and older tool results are shortened.")
    }

    private var planView: some View {
        let done = session.plan.filter { $0["status"] as? String == "done" }.count
        return DisclosureGroup(isExpanded: $showPlan) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(session.plan.indices, id: \.self) { i in
                    let s = session.plan[i], status = s["status"] as? String ?? "todo"
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: status == "done" ? "checkmark.circle.fill" : status == "doing" ? "circle.dotted.circle" : "circle")
                            .foregroundStyle(status == "done" ? .green : status == "doing" ? DynoBrand.accent : .secondary).font(.caption)
                        Text(s["title"] as? String ?? "").font(.caption).strikethrough(status == "done", color: .secondary)
                            .foregroundStyle(status == "done" ? .secondary : .primary)
                    }
                }
            }.padding(.top, 4)
        } label: {
            Text("Plan · \(done) of \(session.plan.count) done").font(.caption.weight(.semibold))
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var noModel: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cpu").font(.largeTitle).foregroundStyle(.secondary)
            Text("Start a model to talk to the assistant").font(.headline)
            Text("The assistant runs on a model on this Mac. Nothing you say leaves it.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Models") { model.requestedTab = .run }.buttonStyle(.dynoPrimary)
            Spacer()
        }.padding(20).frame(maxWidth: .infinity)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.events.isEmpty && !session.busy { welcome }
                    if session.hasEarlier {
                        Button("Load earlier messages") { Task { await session.loadEarlier() } }.buttonStyle(.link).font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(session.events.indices, id: \.self) { i in row(session.events[i]) }
                    if session.busy { liveRow }
                    if let e = session.error { Text(e).font(.caption).foregroundStyle(.orange) }
                    Color.clear.frame(height: 1).id("end")
                }.padding(12)
            }
            .onChange(of: session.events.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: (session.live?["content"] as? String)?.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What do you want to find out?").font(.title3.bold())
            Text("Describe it in your own words, typed or spoken. I'll plan it, set it up in Dyno for you to check, and ask before running anything.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(["Does my model keep a rule it was told only once, many turns ago?",
                     "Compare my two models on refusing unsafe requests.",
                     "Build an eval from a list of questions and answers.",
                     "Explain what the Evals board shows so far."], id: \.self) { s in
                Button { text = s; focused = true } label: {
                    Text(s).font(.callout).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(DynoBrand.surface))
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 8)
    }

    @ViewBuilder private func row(_ e: [String: Any]) -> some View {
        switch e["kind"] as? String ?? "" {
        case "user":
            HStack { Spacer(minLength: 40)
                Text(e["text"] as? String ?? "").font(.callout).padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.accent.opacity(0.16))).copyable(e["text"] as? String ?? "")
            }
        case "assistant": assistantRow(e)
        case "ui": uiCard(e)
        case "proposal": proposalCard(e)
        case "summary":
            DisclosureGroup {
                Text(e["text"] as? String ?? "").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } label: {
                Label("Earlier turns summarized to save room. The full conversation is saved.", systemImage: "rectangle.compress.vertical")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case "error":
            Label(e["text"] as? String ?? "", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        default: EmptyView()  // tool results, decisions and plan updates show inside the rows above
        }
    }

    private func results() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for e in session.events where e["kind"] as? String == "tool_result" { if let c = e["call"] as? String { out[c] = e } }
        return out
    }

    @ViewBuilder private func assistantRow(_ e: [String: Any]) -> some View {
        let text = (e["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = (e["reasoning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = e["tool_calls"] as? [[String: Any]] ?? []
        let done = results()
        VStack(alignment: .leading, spacing: 6) {
            if !reasoning.isEmpty {
                DisclosureGroup {
                    LongText(text: reasoning).font(.caption.monospaced()).foregroundStyle(.secondary)
                } label: { Label("Thinking", systemImage: "brain").font(.caption2).foregroundStyle(.purple) }
            }
            if !text.isEmpty { MarkdownPreview(text: text, selectable: false).font(.callout).copyable(text) }
            ForEach(calls.indices, id: \.self) { i in
                let c = calls[i], name = c["name"] as? String ?? ""
                if !["show_test_setup", "start_test", "start_eval_batch", "save_inspect_eval", "run_inspect_eval", "save_prompt"].contains(name) {
                    let r = done[c["id"] as? String ?? ""]
                    let failed = (r?["content"] as? String ?? "").hasPrefix("error")
                    HStack(spacing: 5) {
                        Image(systemName: r == nil ? "circle.dotted" : failed ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(failed ? .orange : .secondary)
                        Text(Self.label(name, c["arguments"] as? String)).foregroundStyle(.secondary)
                    }.font(.caption2)
                    .help(failed ? (r?["content"] as? String ?? "") : "")
                }
            }
        }
    }

    static func label(_ name: String, _ arguments: String?) -> String {
        let args = (arguments?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        switch name {
        case "app_state": return "Looked at your screen"
        case "list_environments": return "Looked at the environments"
        case "environment_detail": return "Opened the environment \(args["id"] as? String ?? "")"
        case "list_tests": return "Looked at past tests"
        case "test_result": return "Read a test's result"
        case "evals_overview": return "Read the Evals board"
        case "list_prompts": return "Looked at agent prompts"
        case "inspect_catalog": return "Looked at Inspect evals and benchmarks"
        case "check_test": return "Checked the test setup"
        case "open_screen": return "Opened \(screenTitle(args["screen"] as? String ?? ""))"
        case "update_plan": return "Updated the plan"
        default: return name
        }
    }

    static func screenTitle(_ s: String) -> String {
        ["agents_setup": "Agents → Setup", "agents_room": "Agents → Room & Observer", "past_tests": "Agents → Past tests",
         "evals": "Evals", "evals_results": "Evals → Results", "inspect_library": "Evals → Benchmark library", "models": "Models",
         "lab": "Lab", "execution": "Execution"][s] ?? s
    }

    private var liveRow: some View {
        let reasoning = session.live?["reasoning"] as? String ?? ""
        let content = session.live?["content"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                DynoSpinner(size: 12)
                Text(content.isEmpty ? (reasoning.isEmpty ? "Working…" : "Thinking…") : "Writing…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { Task { await session.stop() } }.buttonStyle(.link).font(.caption)
            }
            if content.isEmpty && !reasoning.isEmpty {
                Text(reasoning.split(separator: "\n").suffix(3).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            }
            if !content.isEmpty { LongText(text: content).font(.callout) }
        }
    }

    // MARK: Cards

    @ViewBuilder private func uiCard(_ e: [String: Any]) -> some View {
        let action = e["action"] as? String ?? "", args = e["args"] as? [String: Any] ?? [:], id = e["id"] as? String ?? ""
        if action == "show_test_setup" {
            let spec = args["spec"] as? [String: Any] ?? [:]
            card(icon: "square.and.pencil", tint: DynoBrand.accent) {
                Text("Put a test in Agents → Setup").font(.caption.weight(.semibold))
                Text(spec["title"] as? String ?? spec["goal"] as? String ?? "").font(.callout).lineLimit(3)
                if let n = args["note"] as? String, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Show it") { show(spec) }.controlSize(.small)
                    if session.undo[id] != nil {
                        Button("Undo") { restore(id) }.controlSize(.small).help("Put back the setup you had before")
                    }
                }
            }
        } else if action == "open_screen" {
            Label("Opened \(Self.screenTitle(args["screen"] as? String ?? ""))", systemImage: "arrow.up.forward.app").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func proposalCard(_ e: [String: Any]) -> some View {
        let id = e["id"] as? String ?? "", name = e["name"] as? String ?? "", args = e["args"] as? [String: Any] ?? [:]
        let decision = session.events.last { $0["kind"] as? String == "decision" && $0["proposal"] as? String == id }
        let waiting = session.pending?["id"] as? String == id
        card(icon: "hand.raised", tint: waiting ? .orange : .secondary) {
            Text(waiting ? "Waiting for you" : "Proposal").font(.caption.weight(.semibold)).foregroundStyle(waiting ? .orange : .secondary)
            Text(e["summary"] as? String ?? name).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            details(name, args)
            if waiting {
                TextField("Optional: what to change", text: $note).textFieldStyle(.roundedBorder).font(.caption)
                HStack {
                    Button("Approve") { let n = note; note = ""; Task { await session.decide(approve: true, note: n) } }.buttonStyle(.dynoPrimary)
                    Button("Decline") { let n = note; note = ""; Task { await session.decide(approve: false, note: n) } }
                    if let spec = args["spec"] as? [String: Any] { Button("Show in Dyno") { show(spec) } }
                }.controlSize(.small)
            } else if let d = decision {
                let approved = d["approve"] as? Bool ?? false, ok = d["ok"] as? Bool ?? true
                Label(!approved ? (d["by"] as? String == "message" ? "Not approved: you replied instead" : "You declined")
                      : ok ? "Approved and done" : "Approved, but it failed",
                      systemImage: !approved ? "xmark.circle" : ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(!approved ? Color.secondary : ok ? Color.green : Color.orange)
                if approved, ok { followUp(name, d) }
            }
        }
    }

    @ViewBuilder private func details(_ name: String, _ args: [String: Any]) -> some View {
        if let spec = args["spec"] as? [String: Any] {
            VStack(alignment: .leading, spacing: 2) {
                if let env = spec["environment"] as? String { Text("Environment: \(env)").font(.caption) }
                if let goal = spec["goal"] as? String { Text("Goal: \(goal)").font(.caption).lineLimit(4) }
                ForEach(Array(((spec["rules"] as? [[String: Any]]) ?? []).enumerated()), id: \.offset) { i, r in
                    Text("\(i + 1). \(r["text"] as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                if let models = args["models"] as? [[String: Any]] {
                    Text("Models: " + models.map { ($0["model"] as? String ?? "").split(separator: "/").last.map(String.init) ?? "" }.joined(separator: ", ")
                         + " · \(args["repeats"] as? Int ?? 0) runs each").font(.caption)
                }
            }
        } else if let d = args["definition"] as? [String: Any] {
            Text("\((d["dataset"] as? [Any])?.count ?? 0) samples · scorer: \((d["scorer"] as? [String: Any])?["kind"] as? String ?? (d["library"] != nil ? "library" : "?"))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func followUp(_ name: String, _ d: [String: Any]) -> some View {
        switch name {
        case "start_test": Button("Watch it in Agents → Room & Observer") { open("agents_room", id: nil) }.buttonStyle(.link).font(.caption)
        case "start_eval_batch", "run_inspect_eval": Button("See it in Evals") { open(name == "start_eval_batch" ? "evals" : "evals", id: nil) }.buttonStyle(.link).font(.caption)
        default: EmptyView()
        }
    }

    private func card<Content: View>(icon: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) { content() }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.35)))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = voice.error { Text(e).font(.caption2).foregroundStyle(.orange) }
            if session.pending != nil {
                Text("A proposal is waiting. Writing instead counts as not approving it.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(voice.listening ? "Listening…" : "Describe what you want to find out…").foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 6).allowsHitTesting(false)
                    }
                    TextEditor(text: $text).focused($focused).scrollContentBackground(.hidden).font(.callout)
                        .frame(minHeight: 36, maxHeight: 120).fixedSize(horizontal: false, vertical: true)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            send(); return .handled
                        }
                }
                .padding(4).background(RoundedRectangle(cornerRadius: 10).fill(DynoBrand.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? DynoBrand.accent.opacity(0.6) : Color.clear))
                Button {
                    if !voice.listening { spoken = text.isEmpty || text.hasSuffix(" ") ? text : text + " " }
                    voice.toggle()
                } label: {
                    Image(systemName: voice.listening ? "mic.fill" : "mic").font(.system(size: 15))
                        .foregroundStyle(voice.listening ? .red : .secondary).frame(width: 30, height: 30)
                        .background(Circle().fill(voice.listening ? Color.red.opacity(0.15) : DynoBrand.surface))
                }.buttonStyle(.plain).help(voice.listening ? "Stop listening" : "Speak (on-device speech recognition, nothing leaves this Mac)")
                if session.busy {
                    Button { Task { await session.stop() } } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Stop the assistant")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                            .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : DynoBrand.accent)
                    }.buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).help("Send (Return; Shift-Return for a new line)")
                }
            }
        }.padding(10)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !session.busy, let m = chosen else { return }
        if voice.listening { voice.cancel() }
        text = ""; spoken = ""
        Task { await session.send(t, context: context, model: ["port": m.port, "model": m.model, "name": m.name]) }
    }

    // MARK: What the person sees, and showing things in Dyno

    /// A short description of the screen, sent with each message so the assistant knows what the person is doing.
    private var context: [String: Any] {
        let d = UserDefaults.standard
        var screen = model.currentTab.rawValue
        if model.currentTab == .agents { screen += " → " + (d.string(forKey: "agentsWorkspace2") ?? "Setup") }
        if model.currentTab == .evaluate {
            screen += " → " + (d.string(forKey: "evalsStep") ?? "Choose") + " (" + ((d.string(forKey: "evalsSource") ?? "inspect") == "agents" ? "agent tests" : "Inspect evals") + ")"
        }
        var c: [String: Any] = ["screen": screen,
                                "running_models": servers.map { ["port": $0.port, "model": $0.model, "name": $0.name] }]
        if let data = storedDraft.data(using: .utf8), let draft = try? JSONDecoder().decode(RoomDraft.self, from: data) {
            var setup: [String: Any] = ["environment": draft.environment ?? "plain machine", "goal": draft.goal,
                                        "rules": draft.rules.map(\.text), "team_size": draft.teamSize ?? draft.teamLimit, "turns": draft.rounds]
            if let t = draft.title, !t.isEmpty { setup["title"] = t }
            if let s = draft.script, !s.isEmpty { setup["script_messages"] = s.count }
            if let p = draft.agents.first?.port { setup["lead_model_port"] = p }
            c["agents_setup"] = setup
        }
        if let room = d.string(forKey: "agentsRoom"), !room.isEmpty { c["selected_test"] = room }
        return c
    }

    private func show(_ spec: [String: Any]) { AssistantActions.show(spec, model: model) }
    private func restore(_ id: String) { AssistantActions.restore(id, model: model) }
    private func open(_ screen: String, id: String?) { AssistantActions.open(screen, id: id, model: model) }
}

/// The assistant minimized: a thin rail that stays on screen, with its state and anything waiting for you.
struct AssistantRail: View {
    var model: MonitorModel
    var onOpen: () -> Void
    private var session: AssistantSession { model.assistant }

    var body: some View {
        VStack(spacing: 14) {
            Button(action: onOpen) {
                Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(DynoBrand.accent).frame(width: 32, height: 32)
                    .background(Circle().fill(DynoBrand.accent.opacity(0.14)))
            }.buttonStyle(.plain).help("Open the assistant (⌘J)")
            if session.busy { DynoSpinner(size: 12).help("The assistant is working") }
            if session.pending != nil {
                Button(action: onOpen) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }.buttonStyle(.plain).help("A proposal is waiting for you")
            }
            Spacer()
        }
        .padding(.vertical, 12).frame(width: 46)
        .background(DynoBrand.surface)
        .onAppear { session.attach(model.researchLab) }
    }
}

/// What the assistant shows in Dyno: it opens screens and fills Agents → Setup. Held by the window, so it works
/// while the panel is minimized too.
@MainActor enum AssistantActions {
    static func apply(_ e: [String: Any], model: MonitorModel) {
        let args = e["args"] as? [String: Any] ?? [:]
        switch e["action"] as? String {
        case "show_test_setup":
            if let spec = args["spec"] as? [String: Any] {
                model.assistant.undo[e["id"] as? String ?? ""] = UserDefaults.standard.string(forKey: "roomDraft") ?? ""
                show(spec, model: model)
            }
        case "open_screen": open(args["screen"] as? String ?? "", id: args["id"] as? String, model: model)
        default: break
        }
    }

    static func show(_ spec: [String: Any], model: MonitorModel) {
        var d = RoomDraft(spec: spec)
        if let lead = (spec["agents"] as? [[String: Any]])?.first, let port = lead["port"] as? Int { d.agents[0].port = port }
        model.incomingDraft = d
        open("agents_setup", id: nil, model: model)
    }

    /// Put back the setup that was on screen before the assistant filled it.
    static func restore(_ id: String, model: MonitorModel) {
        guard let old = model.assistant.undo[id], let data = old.data(using: .utf8), let d = try? JSONDecoder().decode(RoomDraft.self, from: data) else { return }
        model.assistant.undo[id] = nil
        model.incomingDraft = d
        open("agents_setup", id: nil, model: model)
    }

    static func open(_ screen: String, id: String?, model: MonitorModel) {
        let d = UserDefaults.standard
        switch screen {
        case "agents_setup": d.set("Setup", forKey: "agentsWorkspace2"); model.requestedTab = .agents
        case "agents_room":
            if let id, !id.isEmpty { d.set(id, forKey: "agentsRoom") }
            d.set("Room & Observer", forKey: "agentsWorkspace2"); model.requestedTab = .agents
        case "past_tests": d.set("Past tests", forKey: "agentsWorkspace2"); model.requestedTab = .agents
        case "evals": d.set("Choose", forKey: "evalsStep"); model.requestedTab = .evaluate
        case "evals_results": d.set("Results", forKey: "evalsStep"); model.requestedTab = .evaluate
        case "inspect_library": d.set("inspect", forKey: "evalsSource"); d.set("Choose", forKey: "evalsStep"); model.requestedTab = .evaluate
        case "models": model.requestedTab = .run
        case "lab": model.requestedTab = .lab
        case "execution": model.requestedTab = .execution
        default: break
        }
    }
}
