import AppKit
import DynoKit
import Observation

@Observable @MainActor
final class PoolSession {
    var config = ""
    var log = ""
    var running = false
    var starting = false
    var acknowledged = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var configuration: URL?
    private let saved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/pool-preview.json")

    init() {
        let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/runtimes/llama-5bda51b/llama-server").path
        let binary = FileManager.default.isExecutableFile(atPath: runtime) ? runtime : "/path/to/llama-server"
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
        guard process == nil else { return }
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
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.log += text
                    if self.log.count > 80000 { self.log = String(self.log.suffix(80000)) }
                }
            }
            task.terminationHandler = { [weak self] p in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    self?.log += "\nProcess exited: \(p.terminationStatus)\n"
                    self?.process = nil; self?.running = false; self?.starting = false; self?.cleanup()
                }
            }
            log = ""; process = task; running = true; starting = action == "start"
            try task.run()
        } catch { log = error.localizedDescription; process = nil; running = false; starting = false; cleanup() }
    }
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        log += "\nStopping coordinator and its SSH tunnel. Active requests will be interrupted.\n"
    }
    private func cleanup() {
        if let configuration { try? FileManager.default.removeItem(at: configuration) }
        configuration = nil
    }
}
