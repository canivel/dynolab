import Foundation

/// Starts and stops `dyno route`.
///
/// Separate from `ServerController` because a router is not a model: it holds
/// no weights, starts instantly, and there is only ever one.
public final class RouterController: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case launching
        case stopping
        case running(port: UInt16)
        case failed(String)
    }

    private let lock = NSLock()
    private var process: Process?
    private var _state: State = .stopped
    private var output: [String] = []

    public var onStateChange: (@Sendable (State) -> Void)?

    public init() {}

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var log: String {
        lock.lock(); defer { lock.unlock() }
        return output.joined(separator: "\n")
    }

    private func setState(_ new: State) {
        lock.lock(); _state = new; let callback = onStateChange; lock.unlock()
        callback?(new)
    }

    public func start(port: UInt16 = 8970, shareOnNetwork: Bool = false) {
        lock.lock()
        let alreadyRunning = process?.isRunning == true
        lock.unlock()
        guard !alreadyRunning else { return }
        guard let invocation = Runtime.invocation(
            for: ["route", "--host", shareOnNetwork ? "0.0.0.0" : "127.0.0.1",
                  "--port", String(port), "--log-level", "WARNING"]
        ) else {
            setState(.failed("No Python runtime found. Reinstall Dyno."))
            return
        }

        setState(.launching)
        lock.lock(); output = []; lock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: invocation.executable)
        task.arguments = invocation.arguments
        task.environment = invocation.environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.lock.lock()
            self?.output.append(contentsOf: text.split(separator: "\n").map(String.init))
            if let count = self?.output.count, count > 40 {
                self?.output.removeFirst(count - 40)
            }
            self?.lock.unlock()
        }

        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.lock.lock()
            guard self.process === finished else { self.lock.unlock(); return }
            let stopped = self._state == .stopping || self._state == .stopped
            self.process = nil
            if stopped {
                self._state = .stopped
            } else if case .failed = self._state {
                // Preserve a readiness failure while its process exits.
            } else {
                self._state = .failed("The router exited with status \(finished.terminationStatus).")
            }
            let state = self._state
            self.lock.unlock()
            self.onStateChange?(state)
        }

        lock.lock()
        process = task
        do {
            try task.run()
            lock.unlock()
        } catch {
            process = nil
            lock.unlock()
            setState(.failed("Could not start the router: \(error.localizedDescription)"))
            return
        }

        // It binds a port immediately; poll rather than assume.
        Task.detached { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                if !task.isRunning { return }
                if ListeningPorts.forProcess(task.processIdentifier).contains(port),
                   await Self.isHealthy(port: port) {
                    self.markReady(task: task, port: port)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let timedOut = self.lock.withLock {
                guard self.process === task, self._state == .launching else { return false }
                self._state = .failed("The router did not become ready.")
                return true
            }
            if timedOut {
                self.onStateChange?(.failed("The router did not become ready."))
                if task.isRunning { task.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private func markReady(task: Process, port: UInt16) {
        lock.lock()
        guard process === task, _state == .launching, task.isRunning else {
            lock.unlock(); return
        }
        _state = .running(port: port)
        lock.unlock()
        onStateChange?(.running(port: port))
    }

    public func stop() {
        lock.lock()
        let task = process
        let running = task?.isRunning == true
        _state = running ? .stopping : .stopped
        let state = _state
        lock.unlock()
        onStateChange?(state)
        guard let task, running else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    private static func isHealthy(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
