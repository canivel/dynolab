import AppKit
import DynoKit
import Foundation
import Observation

/// Neuron jobs in the Lab service: submit, follow, cancel, and read their results, atlas pages and artifacts.
/// Kept apart from the Analyze tool's selection so each keeps its own job open.
@Observable @MainActor
final class NeuronLab {
    @ObservationIgnored unowned let lab: ResearchLab
    var draft = NeuronDraft()
    var selected: String?
    var job: [String: Any] = [:]
    var error: String?
    var submitting = false
    /// Finished jobs never change, so their details are fetched once.
    var details: [String: [String: Any]] = [:]
    var browser: AtlasBrowser?
    init(lab: ResearchLab) { self.lab = lab }

    var jobs: [[String: Any]] { lab.jobs.filter { NeuronDraft.operations.contains($0["operation"] as? String ?? "") } }
    var running: Bool { lab.jobs.contains { ["queued", "running"].contains($0["status"] as? String ?? "") } }
    func finished(_ operation: String) -> [[String: Any]] {
        jobs.filter { $0["operation"] as? String == operation && $0["status"] as? String == "completed" }
    }
    func config(_ id: String) -> [String: Any] { details[id]?["config"] as? [String: Any] ?? [:] }
    func result(_ id: String) -> [String: Any] { details[id]?["result"] as? [String: Any] ?? [:] }

    func refresh() async {
        do {
            lab.jobs = try await lab.request("/jobs")["jobs"] as? [[String: Any]] ?? []
            lab.connected = true
            lab.busy = running
            for item in jobs {
                guard let id = item["id"] as? String, item["status"] as? String == "completed", details[id] == nil else { continue }
                details[id] = try? await lab.request("/jobs/\(id)", timeout: 10)
            }
            if let id = selected {
                var value: [String: Any]
                if let cached = details[id] { value = cached } else { value = try await lab.request("/jobs/\(id)", timeout: 10) }
                if selected == id { job = value }
            }
        } catch { lab.connected = false; self.error = error.localizedDescription }
    }

    func select(_ id: String?) {
        selected = id
        job = id.flatMap { details[$0] } ?? [:]
        Task { await refresh(); openBrowserIfAtlas() }
    }

    func submit() async {
        let config: [String: Any]
        do { config = try draft.configuration() } catch { self.error = error.localizedDescription; return }
        submitting = true
        defer { submitting = false }
        if !lab.connected { await lab.start() }
        guard lab.connected else { error = lab.error ?? "The Lab service is not running."; return }
        do {
            // A 400 carries the service's own validation message; request() surfaces it as the error text.
            let created = try await lab.request("/jobs", body: config, timeout: 15)
            error = nil
            selected = created["id"] as? String; job = created
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func cancel() async {
        guard let id = selected else { return }
        do { job = try await lab.request("/jobs/\(id)/cancel", body: [:], timeout: 10); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    /// Raw bytes of an atlas page or artifact. Unit pages arrive gzip-encoded; URLSession decodes them.
    func data(_ path: String, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(lab.port)/lab/v1\(path)")!)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NSError(domain: "DynoLab", code: 4, userInfo: [NSLocalizedDescriptionKey: object?["error"] as? String ?? "Lab request failed"])
        }
        return data
    }
    func artifact(_ id: String, _ name: String) async throws -> Data { try await data("/jobs/\(id)/artifacts/\(name)", timeout: 60) }

    /// Opens the browser for the selected job when it is a finished atlas.
    func openBrowserIfAtlas() {
        guard let id = selected, job["operation"] as? String == "atlas", job["status"] as? String == "completed" else { return }
        if browser?.jobID == id { return }
        let atlas = (job["result"] as? [String: Any])?["atlas"] as? [String: Any] ?? [:]
        let layers = ((atlas["layers"] as? [String: Any]) ?? [:]).keys.compactMap { Int($0) }.sorted()
        let next = AtlasBrowser(neurons: self, jobID: id, model: atlas["model"] as? String ?? job["model"] as? String ?? "",
                                hook: atlas["hook"] as? String ?? "", layers: layers)
        browser = next
        Task { await next.load() }
    }

    /// Opens a finished atlas, optionally with an auto-interp job's labels.
    func openAtlas(_ id: String, labels: String? = nil) {
        guard details[id] != nil else { return }
        selected = id; job = details[id] ?? [:]
        openBrowserIfAtlas()
        if let labels, let browser { Task { await browser.loadLabels(labels) } }
    }

    /// An atlas that can show units of this model, layer and hook: the open one first, then any finished one.
    func atlas(model: String, layer: Int, hook: String?) -> String? {
        if let browser, browser.matches(model: model, layer: layer, hook: hook) { return browser.jobID }
        return finished("atlas").compactMap { $0["id"] as? String }.first { id in
            let atlas = result(id)["atlas"] as? [String: Any] ?? [:]
            let layers = (atlas["layers"] as? [String: Any] ?? [:]).keys.compactMap { Int($0) }
            let atlasHook = atlas["hook"] as? String
            return atlas["model"] as? String == model && layers.contains(layer) && (hook == nil || atlasHook == nil || atlasHook == hook)
        }
    }

    /// Opens a unit in an atlas: the given one, or one of the same model, layer and hook. Returns false when none fits.
    @discardableResult
    func reveal(atlas: String? = nil, model: String, layer: Int, hook: String?, kind: String = "neuron", index: Int) -> Bool {
        guard let id = atlas ?? self.atlas(model: model, layer: layer, hook: hook), details[id] != nil else { return false }
        if browser?.jobID == id, let browser {
            selected = id; job = details[id] ?? job
            Task { await browser.reveal(layer: layer, kind: kind, index: index) }
        } else {
            selected = id; job = details[id] ?? [:]
            openBrowserIfAtlas()
            browser?.pendingReveal = (layer, kind, index)
        }
        return true
    }

    func export(_ value: Any, name: String) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { error = "Nothing to export."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url) } catch { self.error = error.localizedDescription }
        }
    }
    func export<T: Encodable>(encodable value: T, name: String) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { error = "Nothing to export."; return }
        export(object, name: name)
    }
}

/// One open atlas: its layer index, vocabulary and the unit page being read.
@Observable @MainActor
final class AtlasBrowser {
    @ObservationIgnored unowned let neurons: NeuronLab
    let jobID: String
    let model: String
    let hook: String
    let layers: [Int]
    var layer: Int
    var index: AtlasIndex?
    var vocab = AtlasVocab(tokens: [:])
    var loading = false
    var error: String?
    var selectedUnit: Int?
    var page: UnitPage?
    var pageLoading = false
    var pageError: String?
    /// The auto-interp job whose labels are shown, and its rows.
    var labelsJob = ""
    var labels: AutointerpReport?
    @ObservationIgnored var pendingReveal: (layer: Int, kind: String, index: Int)?
    @ObservationIgnored private var pages: [String: UnitPage] = [:]

    init(neurons: NeuronLab, jobID: String, model: String, hook: String, layers: [Int]) {
        self.neurons = neurons; self.jobID = jobID; self.model = model; self.hook = hook; self.layers = layers
        layer = layers.first ?? 0
    }

    func matches(model: String, layer: Int, hook: String?) -> Bool {
        self.model == model && layers.contains(layer) && (hook == nil || hook == self.hook || self.hook.isEmpty)
    }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        if let pending = pendingReveal, layers.contains(pending.layer) { layer = pending.layer }
        let wanted = layer
        do {
            async let indexData = neurons.data("/jobs/\(jobID)/atlas/\(wanted)/index", timeout: 60)
            async let vocabData = neurons.data("/jobs/\(jobID)/atlas/\(wanted)/vocab", timeout: 60)
            let (i, v) = try await (indexData, vocabData)
            let decoded = try await Task.detached { (try AtlasIndex.read(i), try AtlasVocab.read(v)) }.value
            guard layer == wanted else { return }
            index = decoded.0; vocab = decoded.1
            if let pending = pendingReveal {
                pendingReveal = nil
                await reveal(layer: pending.layer, kind: pending.kind, index: pending.index)
            } else if selectedUnit == nil || index?.units.contains(where: { $0.unit == selectedUnit }) != true {
                await open(index?.units.first?.unit)
            } else { await open(selectedUnit) }
        } catch { self.error = "The atlas could not be read: \(error.localizedDescription)" }
    }

    func setLayer(_ value: Int) async {
        guard value != layer || index == nil else { return }
        layer = value; index = nil; page = nil
        await load()
    }

    func open(_ unit: Int?) async {
        selectedUnit = unit
        guard let unit else { page = nil; return }
        let key = "\(layer)/\(unit)"
        if let cached = pages[key] { page = cached; pageError = nil; return }
        pageLoading = true; pageError = nil
        defer { pageLoading = false }
        do {
            let data = try await neurons.data("/jobs/\(jobID)/atlas/\(layer)/\(unit)")
            let value = try await Task.detached { try UnitPage.read(data) }.value
            if pages.count > 64 { pages.removeAll() }
            pages[key] = value
            if selectedUnit == unit { page = value }
        } catch { if selectedUnit == unit { pageError = "This unit's page could not be read: \(error.localizedDescription)" } }
    }

    func reveal(layer: Int, kind: String, index: Int) async {
        if layer != self.layer { await setLayer(layer) }
        guard let unit = self.index?.unit(kind: kind, index: index) else {
            error = "\(kind.capitalized) \(index) is not in this atlas. The capture may have sampled other units."; return
        }
        await open(unit.unit)
    }

    func loadLabels(_ id: String) async {
        labelsJob = id; labels = nil
        guard !id.isEmpty else { return }
        do {
            let data = try await neurons.artifact(id, "autointerp.json")
            let report = try await Task.detached { try AutointerpReport.read(data) }.value
            if labelsJob == id { labels = report }
        } catch { if labelsJob == id { pageError = "Labels could not be read: \(error.localizedDescription)" } }
    }

    /// Finished auto-interp jobs run on this atlas.
    var labelJobs: [[String: Any]] {
        neurons.finished("autointerp").filter { neurons.config($0["id"] as? String ?? "")["atlas"] as? String == jobID }
    }
}
