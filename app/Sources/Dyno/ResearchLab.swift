import AppKit
import DynoKit
import Foundation
import Observation

@Observable @MainActor
final class ResearchLab {
    var tokenAnalysis = false
    var servingResult: [String: Any] = [:]
    var capturing = false
    var savedCaptures: [[String: Any]] = []
    var archiveError: String?
    init() { reloadCaptures() }
    func reloadCaptures() {
        do { savedCaptures = try ResearchArchive().load(kind: "activation") }
        catch { archiveError = error.localizedDescription }
    }
    var draftPrompt: String?
    var draftModel: String?
    var connected = false
    var busy = false
    var error: String?
    var jobs: [[String: Any]] = []
    var selected: String?
    var job: [String: Any] = [:]
    var port: UInt16 = 8980
    @ObservationIgnored private var process: Process?

    func start() async {
        if let health = try? await request("/health") {
            guard health["worker_revision"] as? Int == 2 else {
                connected = false
                error = "An older Lab service is still running. Quit the Dyno instance that started it, then reopen the updated app. Inference endpoints do not need to be reconfigured."
                return
            }
            connected = true; error = nil; return
        }
        guard process?.isRunning != true else { return }
        guard let command = Runtime.invocation(for: ["lab", "--port", String(port)]) else {
            error = "No Python runtime available. Open a bundled Dyno build."; return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command.executable)
        task.arguments = command.arguments; task.environment = command.environment
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run(); process = task
            for _ in 0..<30 {
                if (try? await request("/health")) != nil { connected = true; error = nil; return }
                try await Task.sleep(for: .milliseconds(200))
            }
            error = "Research service did not start. Check that port \(String(port)) is available and the bundled runtime is updated."
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        process?.terminate(); process = nil; connected = false
    }
    func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/lab/v1\(path)")!)
        request.timeoutInterval = 2
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "DynoLab", code: 1, userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "Research API unavailable"])
        }
        return object
    }
    func refresh() async {
        do {
            jobs = try await request("/jobs")["jobs"] as? [[String: Any]] ?? []
            connected = true
            busy = jobs.contains { ["queued", "running"].contains($0["status"] as? String ?? "") }
            // Starting the service must not surface an old failure as a new run.
            if selected == nil { job = [:] }
            let identifier = selected
            if let identifier {
                let value = try await request("/jobs/\(identifier)")
                if selected == identifier { job = value }
            }
        } catch { connected = false; self.error = error.localizedDescription }
    }
    func submit(model: String, operation: String, configuration: String) async {
        do {
            guard let data = configuration.data(using: .utf8),
                  var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "DynoLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "Parameters must be a JSON object"])
            }
            config["model"] = model; config["operation"] = operation
            let result = try await request("/jobs", body: config)
            selected = result["id"] as? String; job = result; error = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func cancel() async {
        guard let id = selected else { return }
        do { job = try await request("/jobs/\(id)/cancel", body: [:]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func servingRequest(port: UInt16, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/lab/\(path)")!)
        request.timeoutInterval = body == nil ? 3 : 75
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "DynoLab", code: 3, userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "This endpoint does not support serving activation capture. Restart it with the updated dyno serve when traffic is quiet; no server has been stopped."])
        }
        return object
    }
    func captureServing(port: UInt16, model: String, parameters: [String: Any]) async {
        capturing = true
        let created = Date().timeIntervalSince1970
        servingResult = ["operation": "inspect", "status": "running", "created": created]
        defer {
            capturing = false
            servingResult["config"] = parameters
            servingResult["model"] = model
            servingResult["port"] = Int(port)
            do {
                servingResult = try ResearchArchive().save(servingResult, kind: "activation")
                archiveError = nil; reloadCaptures()
            } catch { archiveError = "Result could not be saved: \(error.localizedDescription). Export it to keep a copy." }
        }
        do {
            var config = parameters; config["model"] = model
            let result = try await servingRequest(port: port, path: "activations", body: config)
            servingResult = ["operation": "inspect", "status": "completed", "created": created, "result": result]
        } catch {
            servingResult = ["operation": "inspect", "status": "failed", "created": created, "error": error.localizedDescription]
        }
    }
    func export(_ value: [String: Any]? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "dyno-experiment.json"
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? JSONSerialization.data(withJSONObject: value ?? job, options: [.prettyPrinted, .sortedKeys]) {
            do { try data.write(to: url) } catch { self.error = error.localizedDescription }
        }
    }
    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
