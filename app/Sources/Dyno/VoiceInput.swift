import AVFoundation
import Observation
import Speech

/// Push-to-talk for the assistant: what you say becomes text as you speak, with on-device recognition only.
/// If this Mac can't recognise the current language on device, it says so; there is no cloud fallback.
@Observable @MainActor final class VoiceInput {
    var listening = false
    var transcript = ""
    var error: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var session = UUID()

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
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = "The microphone didn't start: \(error.localizedDescription)"; return
        }
        self.request = request
        transcript = ""
        listening = true
        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                guard self.session == id else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.finish() }
            }
        }
    }

    func stop() {
        guard listening else { return }
        request?.endAudio()  // the last words are still recognised; finish() follows
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
    }

    private func finish() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        task = nil; request = nil; listening = false
    }

    func cancel() {
        session = UUID()
        task?.cancel()
        finish()
        transcript = ""
    }
}
