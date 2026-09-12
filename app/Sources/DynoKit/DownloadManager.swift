import Foundation
import Darwin

/// Runs `dyno pull` and follows its progress.
///
/// Downloading goes through Python because `huggingface_hub` owns the cache
/// layout, resumes part-finished transfers and handles Xet — all of which a
/// hand-rolled downloader would have to reimplement to put files where MLX
/// will later find them.
public final class DownloadManager: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var repository: String
        public var displayName: String?
        public var detail: String?
        public var isExternal = false
        public var isStale = false
        public var isPaused = false
        public var controlToken: String?
        public var status: String?
        public var downloadedBytes: Int64 = 0
        public var totalBytes: Int64?
        public var isFinished = false
        public var error: String?

        public var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }
    }

    private let lock = NSLock()
    private var active: [String: Progress] = [:]
    private var tasks: [String: Process] = [:]

    /// Fires on every progress update, on an arbitrary queue.
    public var onChange: (@Sendable ([String: Progress]) -> Void)?

    private var backgroundTimer: DispatchSourceTimer?
    private var background: [String: Progress] = [:]

    public init() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let records = BackgroundDownloads.read()
            let snapshot: [String: Progress]? = self.withLock {
                guard records != self.background else { return nil }
                self.background = records
                return self.active.merging(records) { first, _ in first }
            }
            if let snapshot { self.onChange?(snapshot) }
        }
        backgroundTimer = timer
        timer.resume()
    }

    deinit { backgroundTimer?.cancel() }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    public var current: [String: Progress] { withLock { active.merging(background) { first, _ in first } } }

    public func isDownloading(_ repository: String) -> Bool {
        withLock { active[repository]?.isFinished == false && active[repository]?.error == nil }
    }

    private func publish(_ progress: Progress) {
        let snapshot = withLock { () -> [String: Progress] in
            active[progress.repository] = progress
            return active.merging(background) { first, _ in first }
        }
        onChange?(snapshot)
    }

    public func clear(_ repository: String) {
        let snapshot = withLock { () -> [String: Progress] in
            active.removeValue(forKey: repository)
            return active.merging(background) { first, _ in first }
        }
        onChange?(snapshot)
    }

    private func externalControl(_ repository: String, action: String) -> Bool {
        guard let item = withLock({ background[repository] }) else { return false }
        guard !item.isStale, let token = item.controlToken else { return true }
        let name = String(repository.dropFirst("background:".count))
        guard name == (name as NSString).lastPathComponent, name.hasSuffix(".json") else { return true }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/downloads")
            .appendingPathComponent(String(name.dropLast(5)) + ".control")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["action": action, "token": token])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            var failed = item; failed.detail = "Could not send download command: " + error.localizedDescription
            publish(failed)
        }
        return true
    }

    public func pause(_ repository: String) {
        if externalControl(repository, action: "pause") { return }
        guard let task = withLock({ tasks[repository] }), task.isRunning, task.suspend() else { return }
        if var item = withLock({ active[repository] }) { item.isPaused = true; publish(item) }
    }

    public func resume(_ repository: String) {
        if externalControl(repository, action: "continue") { return }
        guard let task = withLock({ tasks[repository] }), task.isRunning, task.resume() else { return }
        if var item = withLock({ active[repository] }) { item.isPaused = false; publish(item) }
    }

    public func cancel(_ repository: String) {
        if externalControl(repository, action: "cancel") { return }
        let task = withLock { tasks.removeValue(forKey: repository) }
        if let task, task.isRunning {
            // Deliver TERM even if the process is suspended.
            task.terminate()
            kill(task.processIdentifier, SIGCONT)
        }
        if var item = withLock({ active[repository] }) {
            item.isPaused = false; item.isFinished = true; item.status = "cancelled"; item.error = "Cancelled. Partial files kept; download again to resume."
            publish(item)
        }
    }

    public func download(_ repo: String, filename: String? = nil) {
        let repository = filename.map { repo + "/" + $0 } ?? repo
        var args = ["pull", repo, "--json"]
        if let filename { args += ["--filename", filename] }
        guard !isDownloading(repository) else { return }
        guard let invocation = Runtime.invocation(for: args) else {
            publish(Progress(repository: repository, isFinished: true,
                             error: "No Python runtime found. Reinstall Dyno."))
            return
        }

        publish(Progress(repository: repository))

        let task = Process()
        task.executableURL = URL(fileURLWithPath: invocation.executable)
        task.arguments = invocation.arguments
        task.environment = invocation.environment

        let output = Pipe()
        task.standardOutput = output
        // The hub's own chatter goes to stderr; it is noise here.
        task.standardError = FileHandle.nullDevice

        _ = withLock { tasks[repository] = task }
        do {
            try task.run()
        } catch {
            _ = withLock { tasks.removeValue(forKey: repository) }
            publish(Progress(repository: repository, isFinished: true,
                             error: "Could not start the download: \(error.localizedDescription)"))
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let self, self.withLock({ self.tasks[repository] === task }),
                          let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    self.handle(event: event, repository: repository)
                }
            }
            task.waitUntilExit()
            guard let self, self.withLock({ self.tasks[repository] === task }) else { return }
            _ = self.withLock { self.tasks.removeValue(forKey: repository) }
            if let existing = self.withLock({ self.active[repository] }), !existing.isFinished {
                var failed = existing
                failed.isFinished = true
                failed.error = task.terminationStatus == 0 ? "Download ended without confirming a complete model." : "Download failed."
                self.publish(failed)
            }
        }
    }

    private func handle(event: [String: Any], repository: String) {
        var progress = withLock { active[repository] } ?? Progress(repository: repository)
        switch event["type"] as? String {
        case "start":
            progress.totalBytes = (event["total_bytes"] as? NSNumber)?.int64Value
            progress.downloadedBytes = (event["existing_bytes"] as? NSNumber)?.int64Value ?? 0
        case "progress":
            progress.downloadedBytes = (event["downloaded_bytes"] as? NSNumber)?.int64Value ?? 0
            if let total = (event["total_bytes"] as? NSNumber)?.int64Value {
                progress.totalBytes = total
            }
        case "done":
            progress.downloadedBytes = (event["downloaded_bytes"] as? NSNumber)?.int64Value
                ?? progress.downloadedBytes
            progress.isFinished = true
        case "error":
            progress.isFinished = true
            progress.error = event["message"] as? String ?? "Download failed."
        default:
            return
        }
        publish(progress)
    }
}
