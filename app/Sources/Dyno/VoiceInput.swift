import AVFoundation
import Observation
import Speech

/// Push-to-talk for the assistant: what you say becomes text as you speak, with on-device recognition only.
/// If this Mac can't recognise the current language on device, it says so; there is no cloud fallback.
///
/// It keeps listening until you press the mic again. The recognizer ends an utterance when you pause and starts
/// the next one from scratch, so finished utterances are kept (`committed`) and each new one is added after them.
@Observable @MainActor final class VoiceInput {
    var listening = false
    /// Everything said since the mic was pressed: finished utterances, then the one in progress.
    var transcript = ""
    var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let feed = Feed()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var committed = ""
    @ObservationIgnored private var current = ""
    @ObservationIgnored private var userStopped = false

    /// The recognition request the microphone feeds. The audio tap runs on the audio thread, and the request is
    /// swapped for a new one after every utterance, so it sits behind a lock.
    final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
        func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
        func end() { lock.lock(); request?.endAudio(); lock.unlock() }
    }

    var available: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
            && (SFSpeechRecognizer(locale: Locale.current)?.supportsOnDeviceRecognition ?? false)
    }

    func toggle() { listening ? stop() : start() }

    func start() {
        guard !listening else { return }
        error = nil
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            error = "Voice needs the bundled Dyno app (microphone permission)."; return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition else {
            error = "On-device speech recognition isn't available for this Mac's language. Dyno doesn't send audio anywhere, so type instead."; return
        }
        let id = UUID(); session = id
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                Task { @MainActor in
                    guard self.session == id else { return }
                    guard status == .authorized, allowed else {
                        self.error = "Allow Microphone and Speech Recognition for Dyno in System Settings → Privacy & Security."; return
                    }
                    self.begin(recognizer, id)
                }
            }
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer, _ id: UUID) {
        self.recognizer = recognizer
        committed = ""; current = ""; transcript = ""; userStopped = false
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in feed.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "The microphone didn't start: \(error.localizedDescription)"; return
        }
        listening = true
        utterance(id)
    }

    /// One recognition request: it runs until the recognizer ends the utterance (a pause), then the next begins.
    private func utterance(_ id: UUID) {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        feed.set(request)
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard self.session == id else { return }
                if let text { self.heard(text) }
                guard final || error != nil else { return }
                self.commit()
                if self.userStopped || !self.engine.isRunning { self.finish(); return }
                self.utterance(id)  // still listening: the next thing said is a new utterance
            }
        }
    }

    /// A partial result. If it doesn't continue the utterance in progress, the recognizer started a new one:
    /// keep what was said and add the new text after it.
    private func heard(_ text: String) {
        (committed, current) = Self.merge(committed: committed, current: current, heard: text)
        transcript = Self.join(committed, current)
    }

    private func commit() {
        committed = Self.join(committed, current); current = ""
        transcript = committed
    }

    static func merge(committed: String, current: String, heard: String) -> (String, String) {
        let new = heard.trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty, !new.isEmpty else { return (committed, new.isEmpty ? current : new) }
        // A continuation repeats the start of what was heard so far (the recognizer revises words as it goes).
        let head = { (s: String) in s.lowercased().split(separator: " ").prefix(2).joined(separator: " ") }
        let continues = head(new) == head(current) || new.lowercased().hasPrefix(head(current))
        // A new utterance starts short; a revision of the current one (a changed first word) keeps its length.
        let restarted = !continues && new.count < current.count
        return restarted ? (join(committed, current), new) : (committed, new)
    }

    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    func stop() {
        guard listening else { return }
        userStopped = true
        feed.end()  // the last words are still recognised; finish() follows the final result
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
    }

    private func finish() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        feed.set(nil); task = nil; listening = false
    }

    func cancel() {
        session = UUID()
        task?.cancel()
        finish()
        committed = ""; current = ""; transcript = ""
    }
}
