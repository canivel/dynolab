import AppKit
import DynoKit
import Observation

@Observable @MainActor
final class PoolSession {
    var telemetry = PoolTelemetry()
    var prompt = "The capital of France is"
    var response = ""
    var requesting = false
    var requestError = ""
    var nearby = PoolNearbySession()
    var selectionNotice = ""
    var config = ""
    var log = ""
    var running = false
    var starting = false
    var acknowledged = false
    @ObservationIgnored private var logFile: FileHandle?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var configuration: URL?
    private let saved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/pool-preview.json")

    init() {
        let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/runtimes/llama-5bda51b/llama-server").path
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("pool-runtime/llama-server").path ?? ""
        let binary = FileManager.default.isExecutableFile(atPath: bundled) ? bundled : (FileManager.default.isExecutableFile(atPath: runtime) ? runtime : "/path/to/llama-server")
        config = (try? String(contentsOf: saved, encoding: .utf8)) ?? """
        {
          "binary": "\(binary)",
          "model": "/path/to/model.gguf",
          "local_address": "",
          "peer": "",
          "user": "",
          "port": 8978,
          "rpc_port": 50052,
          "context": 2048,
          "alias": "dyno-pool"
        }
        """
    }
    var selectedPairingID: String {
        ((try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any])?["pairing_id"] as? String ?? ""
    }
    func isSelected(_ worker: SavedPoolWorker) -> Bool {
        worker.id == selectedPairingID || worker.previousIDs.contains(selectedPairingID)
    }
    var setupReady: Bool {
        guard !selectedPairingID.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any],
              let path = object["model"] as? String else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
    var recoveryHelp: String {
        let error = telemetry.error ?? ""
        if error.contains("SSH") || error.contains("tunnel") { return "Check that the worker app is running on the same network. Select your saved worker, then check the connection again. Re-pair only if its verified identity changed." }
        if error.contains("memory") { return "The worker runtime reports insufficient free accelerator memory. Close other GPU workloads; if the GPU is idle, restart the worker to refresh its CUDA state, then check devices again." }
        if error.contains("loading") { return "Loading did not finish before the configured deadline. Check the worker connection and transfer progress in diagnostics before changing the loading timeout." }
        return "Check devices again. Technical diagnostics below contain the full error."
    }
    var modelLabel: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
              let path = object["model"] as? String, path != "/path/to/model.gguf" else { return "No GGUF model selected" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    func selectModel(_ path: String) {
        guard !running else { log += "Stop the pool before changing its model.\n"; return }
        do {
            guard var object = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any] else { return }
            object["model"] = path
            config = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            save()
            telemetry = PoolTelemetry(); selectionNotice = "Model selected: \(modelLabel). Ready to check devices and start."
        } catch { log = error.localizedDescription }
    }
    func useConnection(_ data: Data) {
        guard !running else { return }
        do {
            config = try PoolConfiguration.merging(connection: data, into: config)
            save()
            telemetry = PoolTelemetry()
            selectionNotice = "Worker selected for this pool. Choose a model, then start it."
            log += selectionNotice + "\n"
        } catch { log = error.localizedDescription }
    }
    func save() {
        do {
            guard config.utf8.count <= 16384 else { throw NSError(domain: "Pool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Configuration exceeds 16 KB"]) }
            _ = try JSONSerialization.jsonObject(with: Data(config.utf8))
            try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.write(to: saved, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saved.path)
            log = "Saved locally. This is configuration, not a running pool.\n"
        } catch { log = error.localizedDescription }
    }
    func execute(_ action: String) {
        guard process == nil, !nearby.busy else { return }
        if (action == "probe" || action == "start") && !acknowledged { return }
        var args = ["pool", action]
        do {
            if action != "interfaces" {
                guard config.utf8.count <= 16384 else { return }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("dyno-pool-\(UUID().uuidString).json")
                try config.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                configuration = file
                args += ["--config", file.path]
            }
            if action == "probe" || action == "start" {
                guard acknowledged else { return }
                args.append("--experimental")
            }
            guard let cmd = Runtime.invocation(for: args) else { log = "Bundled runtime unavailable"; cleanup(); return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cmd.executable)
            task.arguments = cmd.arguments; task.environment = cmd.environment
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
            log = ""; telemetry = PoolTelemetry(); response = ""; requestError = ""
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/pool-logs")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let logURL = folder.appendingPathComponent("pool-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            logFile = try FileHandle(forWritingTo: logURL)
            process = task; running = true; starting = action == "start"
            try task.run()
            // Drain through EOF before handling exit, including split UTF-8 and JSON lines.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var buffer = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<end], as: UTF8.self)
                        buffer.removeSubrange(...end)
                        DispatchQueue.main.async { [weak self] in self?.receive(line, from: task) }
                    }
                }
                let remainder = String(decoding: buffer, as: UTF8.self)
                task.waitUntilExit()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.process === task else { return }
                    if !remainder.isEmpty { self.receive(remainder, from: task) }
                    self.log += "\nProcess exited: \(task.terminationStatus)\n"
                    self.telemetry.ready = false; self.telemetry.active = false
                    if task.terminationStatus != 0 && self.telemetry.error == nil {
                        self.telemetry.error = "Coordinator exited (\(task.terminationStatus)). Open diagnostics for details."
                        self.telemetry.phase = "Needs attention"
                    }
                    self.process = nil; self.running = false; self.starting = false; self.cleanup()
                }
            }
        } catch { log = error.localizedDescription; process = nil; running = false; starting = false; cleanup() }
    }
    private func receive(_ line: String, from task: Process) {
        guard process === task else { return }
        try? logFile?.write(contentsOf: Data((line + "\n").utf8))
        log += line + "\n"; if log.count > 80000 { log = String(log.suffix(80000)) }
        telemetry.consume(line)
    }
    func generate() {
        guard telemetry.ready, !requesting,
              let endpoint = telemetry.endpoint, let url = URL(string: endpoint + "/completions") else { return }
        requesting = true; response = ""; requestError = ""
        let run = process
        Task {
            defer { requesting = false }
            do {
                var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 120
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "max_tokens": 128, "temperature": 0])
                let (data, reply) = try await URLSession.shared.data(for: request)
                guard process === run else { return }
                guard let http = reply as? HTTPURLResponse, http.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]], let text = choices.first?["text"] as? String else {
                    throw NSError(domain: "Pool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Generation failed. Check the pool status and diagnostics."])
                }
                response = text
            } catch { if process === run { requestError = error.localizedDescription } }
        }
    }
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        log += "\nStopping coordinator and its SSH tunnel. Active requests will be interrupted.\n"
    }
    private func cleanup() {
        try? logFile?.close(); logFile = nil
        if let configuration { try? FileManager.default.removeItem(at: configuration) }
        configuration = nil
    }
}
