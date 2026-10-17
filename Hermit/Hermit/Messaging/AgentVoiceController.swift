import AVFoundation
import Speech
import SwiftUI

private final class AgentAudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = 0
    func observe(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
        if sqrt(energy / Float(buffer.frameLength)) > 0.008 {
            lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock()
        }
    }
    var lastSpeech: TimeInterval { lock.lock(); defer { lock.unlock() }; return last }
}

@MainActor @Observable
final class AgentVoiceController: NSObject, AVSpeechSynthesizerDelegate {
    enum Phase: String { case off = "Voice off", permission = "Microphone permission", listening = "Listening", finishing = "Finishing", waiting = "Waiting for agent", speaking = "Speaking" }
    private(set) var phase: Phase = .off
    private(set) var transcript = ""
    private(set) var countdown: Int?
    var error: String?
    var onSend: ((String) -> Void)?
    var onDraft: ((String) -> Void)?
    private var target = ""
    private var gate = AgentVoiceGate()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timer: Task<Void, Never>?
    private var finalDeadline: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var interruption: NSObjectProtocol?
    private let synthesizer = AVSpeechSynthesizer()
    private var lastTextTime: TimeInterval = 0
    private var waitingAfterSeq = 0
    private var deliveredText = ""
    private var quietSeconds = 2.5
    private var enabled = false
    var isOn: Bool { enabled }

    override init() {
        super.init()
        synthesizer.delegate = self
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop(preserveDraft: true) }
        }
    }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }

    func start(target: String, afterSeq: Int, quietSeconds: Double = 2.5) {
        stop(preserveDraft: false)
        self.quietSeconds = quietSeconds.isFinite ? min(5, max(1.5, quietSeconds)) : 2.5
        self.target = target; waitingAfterSeq = afterSeq; enabled = true
        listen()
    }

    private func listen() {
        guard enabled else { return }
        let capture = gate.begin(target: target)
        phase = .permission; error = nil; transcript = ""; countdown = nil
        Task { [weak self] in
            let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            let microphone = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
            guard let self, self.enabled, self.gate.captureID == capture else { return }
            guard speech == .authorized, microphone else { self.fail("Microphone and speech permissions are required."); return }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                self.fail("On-device speech recognition is unavailable for this language. Cloud recognition was not enabled."); return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw AgentChatError("No microphone route is available") }
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                let meter = AgentAudioMeter()
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in meter.observe(buffer); request.append(buffer) }
                self.engine = engine; self.request = request
                self.recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.enabled, self.gate.captureID == capture,
                              self.phase == .listening || self.phase == .finishing else { return }
                        if let result {
                            let value = result.bestTranscription.formattedString
                            if value != self.transcript { self.lastTextTime = ProcessInfo.processInfo.systemUptime }
                            self.transcript = value
                            if result.isFinal {
                                guard self.phase == .finishing else { self.fail("Recognition ended early. Draft retained; nothing sent."); return }
                                self.finalize(capture: capture); return
                            }
                        }
                        if error != nil { self.fail("Speech recognition stopped. The transcript was kept as a draft.") }
                    }
                }
                engine.prepare(); try engine.start()
                self.phase = .listening; self.lastTextTime = ProcessInfo.processInfo.systemUptime
                self.timer = Task { [weak self] in
                    let started = ProcessInfo.processInfo.systemUptime
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard let self, self.gate.captureID == capture, self.phase == .listening else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - started > 55 { self.fail("Dictation limit reached. Draft retained; nothing sent."); return }
                        guard !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let silence = now - max(meter.lastSpeech, self.lastTextTime)
                        self.countdown = silence > 0.5 ? max(1, Int(ceil(self.quietSeconds - silence))) : nil
                        if silence >= self.quietSeconds { self.finishCapture(capture: capture); return }
                    }
                }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    private func finishCapture(capture: UUID) {
        guard gate.captureID == capture, phase == .listening else { return }
        phase = .finishing; countdown = nil; timer?.cancel()
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio()
        finalDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.gate.captureID == capture, self.phase == .finishing else { return }
            self.fail("No final transcript was returned. Draft retained; nothing sent.")
        }
    }

    private func finalize(capture: UUID) {
        guard let text = gate.finish(capture: capture, target: target, text: transcript, final: true) else { stop(preserveDraft: true); return }
        deliveredText = text; transcript = text; phase = .waiting
        releaseMicrophone()
        onSend?(text)
    }

    func receive(_ history: AgentHistory, receipt: String?) {
        guard enabled, phase == .waiting else { return }
        if ["unknown", "failed", "interrupted"].contains(receipt ?? "") {
            fail("Voice paused. Check the message delivery status before continuing."); return
        }
        guard receipt == "completed", history.status == "ready",
              let user = history.messages.last(where: { $0.role == "user" && $0.seq > waitingAfterSeq && $0.text == deliveredText }) else { return }
        let replies = history.messages.filter { $0.role == "assistant" && $0.seq > user.seq && $0.status != "streaming" }
        waitingAfterSeq = history.messages.last?.seq ?? user.seq
        let spoken = replies.map(\.text).joined(separator: "\n")
        let utterance = AVSpeechUtterance(string: replies.isEmpty ? "The agent finished without a text reply." : AgentSpeechText.reply(spoken))
        phase = .speaking
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { fail("Audio playback is unavailable"); return }
        synthesizer.speak(utterance)
    }

    func skipSpeech() { synthesizer.stopSpeaking(at: .immediate); restartListening() }
    private func restartListening() {
        guard enabled else { return }
        phase = .finishing
        let capture = gate.captureID
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.enabled, self.phase == .finishing, self.gate.captureID == capture else { return }
            self.listen()
        }
    }
    func stop(preserveDraft: Bool = true) {
        if preserveDraft, [.listening, .finishing, .permission].contains(phase), !transcript.isEmpty { onDraft?(transcript) }
        enabled = false; gate.cancel(); releaseMicrophone(); synthesizer.stopSpeaking(at: .immediate)
        phase = .off; countdown = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func fail(_ message: String) { stop(preserveDraft: true); error = message }
    private func releaseMicrophone() {
        timer?.cancel(); timer = nil; finalDeadline?.cancel(); finalDeadline = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio(); request = nil; recognition?.cancel(); recognition = nil
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in guard let self, self.enabled, self.phase == .speaking else { return }; self.restartListening() }
    }
}
