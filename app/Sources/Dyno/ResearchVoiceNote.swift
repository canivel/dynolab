import AppKit
import AVFoundation
import Speech
import Observation

@Observable @MainActor final class ResearchVoiceNote {
    var recording = false
    var requestingMicrophone = false
    @ObservationIgnored private var microphoneRequest = UUID()
    @ObservationIgnored private var transcriptionRequest = UUID()
    var transcribing = false
    var transcript = ""
    var error: String?
    var audio: URL?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    func record() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            error = "Recording requires the bundled Dyno app with microphone permission metadata. You can import an audio file instead."; return
        }
        guard !requestingMicrophone, !recording else { return }
        requestingMicrophone = true
        let requestID = UUID(); microphoneRequest = requestID
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            Task { @MainActor in
                guard self.microphoneRequest == requestID else { return }
                self.requestingMicrophone = false
                guard allowed else { self.error = "Microphone permission was denied. Enable it for Dyno in System Settings, or type a note."; return }
                do {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dyno-note-\(UUID()).m4a")
                    let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
                    guard recorder.record() else { throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone recording did not start."]) }
                    self.recorder = recorder; self.audio = url; self.recording = true; self.transcript = ""; self.error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func stop() { microphoneRequest = UUID(); requestingMicrophone = false; recorder?.stop(); recorder = nil; recording = false }
    func importAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { audio = url; transcript = ""; error = nil }
    }
    func transcribe() {
        guard let audio, !recording, !transcribing else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            error = "Open the bundled Dyno app to enable local speech recognition. Audio can still be saved as evidence."; return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition else {
            error = "On-device transcription is unavailable for this Mac’s current language. No cloud fallback is used. Save the audio and type your note."; return
        }
        self.recognizer = recognizer
        transcribing = true
        let requestID = UUID(); transcriptionRequest = requestID
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard self.transcriptionRequest == requestID else { return }
                guard status == .authorized else { self.transcribing = false; self.error = "Speech recognition permission was denied."; return }
                let request = SFSpeechURLRecognitionRequest(url: audio)
                request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
                self.transcribing = true; self.error = nil
                self.recognition = recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        guard self.transcriptionRequest == requestID else { return }
                        if let result { self.transcript = result.bestTranscription.formattedString }
                        if error != nil || result?.isFinal == true {
                            self.transcribing = false; self.recognition = nil
                            if let error { self.error = "Local transcription failed: \(error.localizedDescription). Audio is still available to save." }
                        }
                    }
                }
            }
        }
    }
    func cancelTranscription() { transcriptionRequest = UUID(); recognition?.cancel(); recognition = nil; transcribing = false }
}
