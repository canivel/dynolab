import Foundation
import DynoKit
import Observation
import SwiftUI

/// Owns the sampler and publishes snapshots to the UI.
///
/// Sampling costs tens of milliseconds and touches IOKit, so it runs on a
/// background queue; only the finished snapshot crosses back to the main actor.
@Observable
@MainActor
final class MonitorModel {
    /// One instance for the whole app. The SwiftUI scene and the AppKit window
    /// controller both need it, and the delegate is constructed before any view
    /// exists, so passing it down from a view does not work.
    static let shared = MonitorModel()

    private(set) var system = SystemInfo()
    private(set) var snapshot = Snapshot()
    private(set) var history = History()
    private(set) var isAvailable = false
    private(set) var startupError: String?

    // -- local model serving -------------------------------------------------
    private(set) var localModels: [LocalModel] = []
    private(set) var ggufModels: [LocalGGUF] = []
    private(set) var serverState: ServerController.State = .stopped
    private(set) var runtime: Runtime.Kind?
    var selectedModel: LocalModel?
    var thinkingMode = UserDefaults.standard.string(forKey: "serverThinkingMode") ?? "default" {
        didSet { UserDefaults.standard.set(thinkingMode, forKey: "serverThinkingMode") }
    }

    // -- router ---------------------------------------------------------------
    private(set) var router = RouterClient.Snapshot()
    var shareRouterOnNetwork = false
    var useRouter = false {
        didSet { UserDefaults.standard.set(useRouter, forKey: Defaults.useRouter) }
    }
    var routerPort: UInt16 = 8970 {
        didSet {
            UserDefaults.standard.set(Int(routerPort), forKey: Defaults.routerPort)
            routerClient.port = routerPort
        }
    }
    /// Ports worth offering: the default, plus whatever was configured.
    var knownRouterPorts: [UInt16] {
        Array(Set([8970, routerPort])).sorted()
    }
    @ObservationIgnored private let routerClient = RouterClient()
    @ObservationIgnored private let routerController = RouterController()
    private(set) var routerState: RouterController.State = .stopped
    @ObservationIgnored private var lastRouterPoll: Date = .distantPast

    // -- catalog -------------------------------------------------------------
    private(set) var catalog: [CatalogModel] = []
    private(set) var catalogError: String?
    private(set) var isSearching = false
    private(set) var downloads: [String: DownloadManager.Progress] = [:]
    var searchText: String = ""

    // -- chat -----------------------------------------------------------------
    let researchLab = ResearchLab()
    let conversations = ConversationStore()
    var generationOptions = GenerationOptions.default {
        didSet { persistGenerationOptions() }
    }
    var showThinking = true {
        didSet { UserDefaults.standard.set(showThinking, forKey: Defaults.showThinking) }
    }
    var launchOptions = LaunchOptions.default {
        didSet {
            guard let data = try? JSONEncoder().encode(launchOptions) else { return }
            UserDefaults.standard.set(data, forKey: Defaults.launchOptions)
        }
    }
    /// Set to ask the window to show chat; the window clears it once handled.
    var wantsChat = false
    /// Set to ask the window to switch tabs; the window clears it once handled.
    /// Chat needs to send you to Run when nothing is loaded.
    var requestedTab: MainWindow.Tab?
    var catalogFormat: ModelCatalog.ModelFormat = .mlx {
        didSet { if catalogFormat != oldValue { runSearch(query: searchText) } }
    }
    @ObservationIgnored private var catalogGeneration = UUID()
    var catalogSort: ModelCatalog.Sort = .popular {
        didSet { runSearch(query: searchText) }
    }

    /// Repository ids already on disk, so the catalog can say so.
    var downloadedRepositories: Set<String> {
        Set(localModels.map(\.name))
    }

    var modelFolders: [String] {
        didSet {
            UserDefaults.standard.set(modelFolders, forKey: Defaults.modelFolders)
            rescanModels()
        }
    }

    var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: Defaults.interval)
            restartTimer()
        }
    }

    var menuBarContent: MenuBarContent {
        didSet {
            UserDefaults.standard.set(menuBarContent.rawValue, forKey: Defaults.menuBarContent)
        }
    }

    @ObservationIgnored private var sampler: Sampler?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(
        label: "com.canivel.dyno.sampler", qos: .utility
    )
    @ObservationIgnored private var isSampling = false
    /// Called after every sample. The status item's title is AppKit, not
    /// SwiftUI, so it needs a nudge rather than observation.
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var lastModelRefresh: Date = .distantPast
    /// Model discovery does loopback HTTP, so it runs far less often than the
    /// counter reads.
    @ObservationIgnored private let modelRefreshInterval: TimeInterval = 3.0
    @ObservationIgnored private let server = ServerController()
    @ObservationIgnored private let downloader = DownloadManager()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init() {
        Defaults.register()
        let defaults = UserDefaults.standard
        interval = max(0.25, defaults.double(forKey: Defaults.interval))
        menuBarContent = MenuBarContent(
            rawValue: defaults.string(forKey: Defaults.menuBarContent) ?? ""
        ) ?? .gpuAndPower

        modelFolders = defaults.stringArray(forKey: Defaults.modelFolders) ?? []
        showThinking = defaults.object(forKey: Defaults.showThinking) as? Bool ?? true
        useRouter = defaults.bool(forKey: Defaults.useRouter)
        let storedPort = defaults.integer(forKey: Defaults.routerPort)
        routerPort = storedPort > 0 ? UInt16(storedPort) : 8970
        if let data = defaults.data(forKey: Defaults.generationOptions),
           let decoded = try? JSONDecoder().decode(GenerationOptions.self, from: data) {
            generationOptions = decoded
        }
        if let data = defaults.data(forKey: Defaults.launchOptions),
           let decoded = try? JSONDecoder().decode(LaunchOptions.self, from: data) {
            launchOptions = decoded
        }

        let override = defaults.double(forKey: Defaults.peakBandwidth)
        let sampler = Sampler(peakBandwidthOverride: override > 0 ? override : nil)
        self.sampler = sampler
        system = sampler.system
        isAvailable = sampler.isAvailable
        if !sampler.isAvailable {
            startupError = "Could not read the system telemetry counters. "
                + "GPU Monitor needs an Apple Silicon Mac."
        }
        runtime = Runtime.current
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverState = state }
        }
        downloader.onChange = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                let completed = progress.values.contains { item in
                    item.isFinished && item.error == nil && self.downloads[item.repository]?.isFinished != true
                }
                self.downloads = progress
                if completed { self.rescanModels() }
            }
        }
        routerController.onStateChange = { [weak self] state in
            Task { @MainActor in self?.routerState = state }
        }
        rescanModels()
        loadCatalog()
        start()
    }

    /// Snapshot rendering can display an existing server without taking ownership
    /// of it or starting/stopping a model in the user's running app.
    func selectRunningModelForSnapshot() {
        guard CommandLine.arguments.contains("--snapshot"),
              let served = snapshot.models.first(where: { $0.stats != nil }),
              let port = served.port else { return }
        selectedModel = localModels.first { $0.name == served.name || $0.path == served.identifier }
        serverState = .running(model: served.name, port: port)
    }

    // MARK: - Catalog

    func loadCatalog() {
        runSearch(query: searchText)
    }

    /// Debounced: typing should not fire a request per keystroke.
    func searchCatalog(_ query: String) {
        searchText = query
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            runSearch(query: query)
        }
    }

    private func runSearch(query: String) {
        isSearching = true
        catalogError = nil
        let generation = UUID(); catalogGeneration = generation
        let format = catalogFormat
        catalog = []
        Task { @MainActor in
            do {
                let results = try await ModelCatalog.search(query, sort: self.catalogSort, format: format)
                guard self.catalogGeneration == generation else { return }
                self.catalog = results
                self.isSearching = false
                if format == .mlx { await self.fillSizes(for: results, generation: generation) }
            } catch {
                guard self.catalogGeneration == generation else { return }
                self.catalog = []
                self.catalogError = error.localizedDescription
                self.isSearching = false
            }
        }
    }

    /// Sizes need a request each, so they arrive after the list rather than
    /// holding it up. Bounded concurrency keeps this polite to the hub.
    private func fillSizes(for models: [CatalogModel], generation: UUID) async {
        let ids = models.prefix(30).map(\.id)
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?).self) { group in
            var running = 0
            var iterator = ids.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                running += 1
                group.addTask { (id, await ModelCatalog.size(of: id)) }
            }
            for _ in 0..<min(6, ids.count) { addNext() }
            while let (id, size) = await group.next() {
                running -= 1
                if let size { sizes[id] = size }
                addNext()
            }
        }
        // Sorting by date surfaces a lot of half-finished uploads: a repo
        // claiming to be a 36B model with 20 MB of files has no weights in it
        // yet. Once a size is known, drop anything too small to be a model.
        guard catalogGeneration == generation else { return }
        let minimumUsableBytes: Int64 = 100 * 1024 * 1024
        catalog = catalog.compactMap { model in
            var model = model
            if let size = sizes[model.id] {
                guard size >= minimumUsableBytes else { return nil }
                model.sizeBytes = size
            }
            return model
        }
    }

    // MARK: - Router

    func startRouter() {
        routerController.start(port: routerPort, shareOnNetwork: shareRouterOnNetwork)
    }
    func stopRouter() { routerController.stop() }
    var routerLog: String { routerController.log }

    /// Change the router's policy while it is serving.
    func updateRouter(_ changes: [String: Any]) {
        let client = routerClient
        Task { @MainActor [weak self] in
            _ = await client.update(changes)
            self?.router = await client.fetch()
        }
    }

    func setRouterRules(_ rules: [RouterConfig.Rule]) {
        updateRouter(["rules": rules.map(\.payloadForUpdate)])
    }

    func download(_ model: CatalogModel) { downloader.download(model.id) }
    func cancelDownload(_ model: CatalogModel) { downloader.cancel(model.id) }
    func downloadGGUF(repository: String, filename: String) { downloader.download(repository, filename: filename) }
    func pauseDownload(_ identifier: String) { downloader.pause(identifier) }
    func continueDownload(_ identifier: String) { downloader.resume(identifier) }
    func cancelGGUF(_ identifier: String) { downloader.cancel(identifier) }
    func dismissDownload(_ repository: String) { downloader.clear(repository) }

    // MARK: - Serving models

    func rescanModels() {
        let folders = modelFolders
        Task.detached(priority: .utility) {
            let found = ModelLibrary.scan(extraPaths: folders)
            let gguf = GGUFModels.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.localModels = found
                self.ggufModels = gguf
                if self.selectedModel == nil || !found.contains(where: { $0.id == self.selectedModel?.id }) {
                    self.selectedModel = found.first
                }
            }
        }
    }

    func addModelFolder(_ path: String) {
        guard !modelFolders.contains(path) else { return }
        modelFolders.append(path)
    }

    var serverActionError: String?
    var launchPort: Int = UserDefaults.standard.integer(forKey: Defaults.serverPort) == 0
        ? 8971 : UserDefaults.standard.integer(forKey: Defaults.serverPort)

    func openModels(for endpoint: LLMModel?) {
        if let endpoint {
            selectedModel = localModels.first { $0.path == endpoint.identifier || $0.name == endpoint.identifier }
            if let port = endpoint.port { launchPort = Int(port) }
        }
        requestedTab = .run
    }

    func canStopEndpoint(_ endpoint: LLMModel) -> Bool {
        guard let command = snapshot.processes.first(where: { $0.pid == endpoint.pid })?.command else { return false }
        return ServerController.isDynoServe(command)
    }

    func stopEndpoint(_ endpoint: LLMModel) {
        serverActionError = nil
        if server.ownedPID == endpoint.pid { server.stop(); return }
        guard let command = snapshot.processes.first(where: { $0.pid == endpoint.pid })?.command,
              let port = endpoint.port else { return }
        do {
            try ServerController.stopDetected(pid: endpoint.pid, port: port, expectedCommand: command)
            openModels(for: endpoint)
        } catch { serverActionError = error.localizedDescription }
    }

    func startSelectedModel() {
        guard let model = selectedModel else { return }
        serverActionError = nil
        guard let port = UInt16(exactly: launchPort), port > 0 else {
            serverActionError = "Choose a port between 1 and 65535."; return
        }
        guard !snapshot.models.contains(where: { $0.port == port }) else {
            serverActionError = "Port \(port) is already serving. Stop that endpoint first or choose another port."; return
        }
        server.start(
            model: model, port: port == 0 ? 8971 : port,
            extraArguments: launchOptions.arguments + (thinkingMode == "default" ? [] : ["--chat-template-args", thinkingMode == "on" ? "{\"enable_thinking\":true}" : "{\"enable_thinking\":false}"])
        )
    }

    func stopServer() {
        server.stop()
    }

    /// Called when the app quits so a model server is never left orphaned.
    func shutdown() {
        conversations.saveNow()
        researchLab.stop()
        routerController.stop()
        server.stop()
        stop()
    }

    var serverLog: String { server.log }

    func start() {
        guard isAvailable else { return }
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common keeps sampling alive while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let sampler, !isSampling else { return }
        isSampling = true
        queue.async { [weak self] in
            let snapshot = sampler.sample()
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snapshot
                self.history.push(snapshot)
                self.isSampling = false
                self.onUpdate?()
            }
        }

        // The router is a separate process; poll it gently and independently.
        if Date().timeIntervalSince(lastRouterPoll) >= 2.0 {
            lastRouterPoll = Date()
            let client = routerClient
            Task { @MainActor [weak self] in
                let snapshot = await client.fetch()
                self?.router = snapshot
            }
        }

        if Date().timeIntervalSince(lastModelRefresh) >= modelRefreshInterval {
            lastModelRefresh = Date()
            let processes = snapshot.processes
            Task.detached(priority: .utility) {
                await sampler.refreshModels(processes: processes)
            }
        }
    }

    private func persistGenerationOptions() {
        guard let data = try? JSONEncoder().encode(generationOptions) else { return }
        UserDefaults.standard.set(data, forKey: Defaults.generationOptions)
    }

    func resetHistory() {
        history.reset()
    }
}
