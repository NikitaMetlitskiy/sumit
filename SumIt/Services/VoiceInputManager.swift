import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class VoiceInputManager: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var permissionDenied = false

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    init() {
        recognizer = makeRecognizer()
    }

    /// Rebuilds the recognizer when the user switches app language.
    private func makeRecognizer() -> SFSpeechRecognizer? {
        let lang = LocalizationManager.shared.current.rawValue
        // Map app language code to BCP-47 with region for better recognition.
        let bcp47: [String: String] = [
            "en": "en-US", "uk": "uk-UA", "ru": "ru-RU",
            "es": "es-ES", "de": "de-DE", "pl": "pl-PL"
        ]
        let id = bcp47[lang] ?? lang
        return SFSpeechRecognizer(locale: Locale(identifier: id))
    }

    func startRecording() {
        // Rebuild recognizer in case language changed since init.
        recognizer = makeRecognizer()
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.permissionDenied = true
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted { self.beginRecognition() }
                        else { self.permissionDenied = true }
                    }
                }
            }
        }
    }

    private func beginRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true

        recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result { self.transcript = result.bestTranscription.formattedString }
            if error != nil || (result?.isFinal ?? false) { self.stopRecording() }
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
    }
}
