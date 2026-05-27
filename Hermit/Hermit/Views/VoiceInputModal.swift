import AVFoundation
import Speech
import SwiftUI

struct VoiceInputModal: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @StateObject private var transcriber = SpeechTranscriber()
    @State private var autoSendTask: Task<Void, Never>?
    @State private var hasSent = false
    let onSend: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Label(transcriber.statusText, systemImage: transcriber.isRecording ? "waveform" : "mic")
                        .font(.caption)
                        .foregroundStyle(transcriber.isRecording ? .green : .secondary)
                    Spacer()
                    Button {
                        transcriber.isRecording ? transcriber.stop() : transcriber.start()
                    } label: {
                        Image(systemName: transcriber.isRecording ? "stop.fill" : "mic.fill")
                            .frame(width: 36, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(transcriber.isRecording ? "Stop Recording" : "Start Recording")
                }
                .padding(.horizontal)
                .padding(.top)

                TextEditor(text: $text)
                    .font(.body)
                    .focused($isFocused)
                    .padding(.horizontal)
            }
            .navigationTitle("Voice Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        submit(text)
                    }
                    .disabled(text.isEmpty)
                }
            }
            .onAppear {
                isFocused = true
                transcriber.start()
                if !text.isEmpty {
                    scheduleIdleSubmit()
                }
            }
            .onDisappear {
                autoSendTask?.cancel()
                transcriber.stop()
            }
            .onReceive(transcriber.$transcript) { transcript in
                guard !transcript.isEmpty else { return }
                handleTranscript(transcript)
            }
        }
    }

    private func handleTranscript(_ transcript: String) {
        guard !hasSent else { return }

        let result = VoiceCommandAutoSubmit.commandByRemovingSubmitPhrase(from: transcript)
        text = result.command

        if result.shouldSubmit {
            submit(result.command)
        } else {
            scheduleIdleSubmit()
        }
    }

    private func scheduleIdleSubmit() {
        autoSendTask?.cancel()
        autoSendTask = Task {
            try? await Task.sleep(nanoseconds: VoiceCommandAutoSubmit.idleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                submit(text)
            }
        }
    }

    private func submit(_ value: String) {
        let command = VoiceCommandAutoSubmit.cleanCommand(value)
        guard !hasSent, !command.isEmpty else { return }

        hasSent = true
        autoSendTask?.cancel()
        transcriber.stop()
        onSend(command)
        dismiss()
    }
}

@MainActor
private final class SpeechTranscriber: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var statusText = "Ready"
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start() {
        guard !isRecording else { return }

        Task {
            let speechAllowed = await requestSpeechAuthorization()
            let microphoneAllowed = await requestMicrophoneAuthorization()
            guard speechAllowed, microphoneAllowed else {
                statusText = speechAllowed ? "Microphone access denied" : "Speech access denied"
                return
            }

            do {
                try startRecording()
            } catch {
                statusText = error.localizedDescription
                stop()
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        if statusText == "Listening" {
            statusText = "Stopped"
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRecording() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusText = "Speech recognition unavailable"
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        statusText = "Listening"

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.statusText = result.isFinal ? "Finished" : "Listening"
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }
}
