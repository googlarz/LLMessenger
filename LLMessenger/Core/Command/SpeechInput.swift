// LLMessenger/Core/Command/SpeechInput.swift
//
// On-device dictation for the command bar. The real implementation uses
// SFSpeechRecognizer + AVAudioEngine with `requiresOnDeviceRecognition = true`,
// so transcription never leaves the machine.
//
// Everything microphone/recognition-related is behind the `SpeechRecognizing`
// protocol so tests inject a fake and NO audio engine is ever started in CI.

import Foundation

/// What the command bar needs from a dictation source. The real impl talks to
/// Speech/AVFoundation; tests provide a stub that drives `transcript` directly.
@MainActor
protocol SpeechRecognizing: ObservableObject {
    var transcript: String { get }
    var isListening: Bool { get }
    /// True when speech recognition is usable on this machine at all.
    var isAvailable: Bool { get }

    func requestAuthorization() async -> Bool
    func start() throws
    func stop()
}

#if canImport(Speech)
import Speech
import AVFoundation

@MainActor
final class SpeechInput: SpeechRecognizing {
    @Published var transcript: String = ""
    @Published var isListening = false

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw LLMError.providerError("Speech recognition is unavailable.")
        }
        stop()
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Private: keep transcription on-device so audio never leaves the machine.
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.transcript = result.bestTranscription.formattedString
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stop()
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }
}
#endif
