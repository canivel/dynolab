import Foundation
import DynoKit
import Observation

struct PoolLAN: Identifiable {
    var id: String { address }
    let address: String
    let interface: String
    let network: String
}

struct NearbyPoolWorker: Identifiable {
    var id: String { "\(localAddress)/\(address):\(port)" }
    let name: String
    let gpu: String
    let address: String
    let localAddress: String
    let port: Int
}

struct SavedPoolWorker: Identifiable {
    let id: String
    let name: String
    let gpu: String
    let peer: String
    let localAddress: String
    let previousIDs: [String]
    let connection: Data
}

@Observable @MainActor
final class PoolNearbySession {
    var networks: [PoolLAN] = []
    var selectedNetwork = ""
    var nearby: [NearbyPoolWorker] = []
    var saved: [SavedPoolWorker] = []
    var selectedWorker = ""
    var busy = false
    var status = "Refresh networks to find workers on your local network."
    var verificationCode: String?
    var pendingConnection: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var receivedResult = false

    func refresh() { launch(["inventory"]) }
    func scan() {
        guard !selectedNetwork.isEmpty else { status = "Choose a local network first."; return }
        nearby = []; selectedWorker = ""
        launch(["scan", "--local-address", selectedNetwork])
    }
    func pairSelected() {
        guard let worker = nearby.first(where: { $0.id == selectedWorker }), worker.localAddress == selectedNetwork else { return }
        launch(["pair", "--local-address", worker.localAddress, "--peer", worker.address,
                "--pair-port", String(worker.port), "--name", worker.name, "--gpu", worker.gpu])
    }
    func answer(_ accepted: Bool) {
        guard let code = verificationCode, let input else { return }
        verificationCode = nil
        do {
            var data = try JSONSerialization.data(withJSONObject: ["confirm": accepted, "code": code])
            data.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: data)
            status = accepted ? "Waiting for worker confirmation and connection setup…" : "Rejecting pairing…"
        } catch { status = error.localizedDescription; cancel() }
    }
    func cancel() {
        verificationCode = nil
        if let process, process.isRunning { process.terminate() }
        status = "Cancelling…"
    }
    private func launch(_ args: [String]) {
        guard !busy else { return }
        guard let command = Runtime.invocation(for: ["pool", "nearby"] + args) else {
            status = "Bundled runtime is unavailable."; return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command.executable)
        task.arguments = command.arguments; task.environment = command.environment
        let output = Pipe(); let errors = Pipe(); let stdin = Pipe()
        task.standardOutput = output; task.standardError = errors; task.standardInput = stdin
        let runToken = UUID(); token = runToken
        process = task; input = stdin; buffer = Data(); receivedResult = false; busy = true
        status = args.first == "pair" ? "Connecting; compare the full code on both devices." : "Checking local workers…"
        do { try task.run() }
        catch { status = error.localizedDescription; busy = false; process = nil; input = nil; return }
        // Separate streams: diagnostics can never be interpreted as protocol events.
        DispatchQueue.global(qos: .utility).async {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            if !data.isEmpty {
                let text = String(decoding: data.suffix(3000), as: UTF8.self)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == runToken, !self.receivedResult else { return }
                    self.status = text
                }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == runToken else { return }
                    self.consume(data)
                }
            }
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == runToken else { return }
                if !self.receivedResult { self.status = "Worker setup did not complete (exit \(task.terminationStatus)). Check the bundled pool dependencies." }
                self.busy = false; self.process = nil; self.input = nil; self.verificationCode = nil
            }
        }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 262144 else { status = "Worker response exceeded the size limit."; cancel(); return }
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = event["event"] as? String else { continue }
            switch kind {
            case "inventory":
                networks = (event["interfaces"] as? [[String: Any]] ?? []).compactMap {
                    guard let address = $0["address"] as? String, let name = $0["interface"] as? String,
                          let network = $0["network"] as? String else { return nil }
                    return PoolLAN(address: address, interface: name, network: network)
                }
                if !networks.contains(where: { $0.address == selectedNetwork }) { selectedNetwork = networks.first?.address ?? "" }
                readSaved(event); receivedResult = true
                status = networks.isEmpty ? "No eligible private LAN interface is available." : "Choose a network and search for nearby workers."
            case "nearby":
                nearby = (event["workers"] as? [[String: Any]] ?? []).compactMap {
                    guard let address = $0["address"] as? String, let local = $0["local_address"] as? String,
                          let port = $0["port"] as? Int else { return nil }
                    return NearbyPoolWorker(name: $0["name"] as? String ?? "Worker", gpu: $0["gpu"] as? String ?? "GPU",
                                            address: address, localAddress: local, port: port)
                }
                selectedWorker = nearby.first?.id ?? ""; receivedResult = true
                status = nearby.isEmpty ? "No workers found. Open a pairing window on the worker and check the selected network." : "Select a worker to verify and pair."
            case "verification_required":
                guard let code = event["code"] as? String,
                      code.range(of: "^[0-9A-F]{4}( [0-9A-F]{4}){7}$", options: .regularExpression) != nil else { cancel(); return }
                verificationCode = code
                status = "Compare every group of the code on both devices."
            case "paired":
                if let connection = event["connection"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: connection) {
                    pendingConnection = String(decoding: data, as: UTF8.self)
                }
                readSaved(event); receivedResult = true
                status = "Paired. Dedicated identity and verified host key saved."
            case "error", "cancelled":
                receivedResult = true; status = event["message"] as? String ?? "Pairing did not complete."
            default: break
            }
        }
    }
    private func readSaved(_ event: [String: Any]) {
        saved = (event["workers"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["pairing_id"] as? String, let peer = $0["peer"] as? String,
                  let local = $0["local_address"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: $0) else { return nil }
            return SavedPoolWorker(id: id, name: $0["name"] as? String ?? "Saved worker", gpu: $0["gpu"] as? String ?? "",
                                   peer: peer, localAddress: local, previousIDs: $0["previous_pairing_ids"] as? [String] ?? [], connection: data)
        }
    }
}
