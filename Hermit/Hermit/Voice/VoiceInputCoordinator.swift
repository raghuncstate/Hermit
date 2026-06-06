import Foundation
import UIKit

@Observable
final class VoiceInputCoordinator {
    var isShowingVoiceModal = false
    var transcribedText = ""

    func handleVoiceButton(settings _: AppSettings) {
        transcribedText = ""
        isShowingVoiceModal = true
    }

    func handleCallbackURL(_ url: URL) {
        guard url.scheme == "hermit",
              url.host == "voice-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value else {
            return
        }
        transcribedText = text
        isShowingVoiceModal = true
    }
}

enum VoiceCommandAutoSubmit {
    static let idleDelayNanoseconds: UInt64 = 2_500_000_000

    private static let submitPhrases = [
        "send the message",
        "send message",
    ]

    static func commandByRemovingSubmitPhrase(from text: String) -> (command: String, shouldSubmit: Bool) {
        for phrase in submitPhrases {
            if let range = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) {
                let command = text[..<range.lowerBound] + text[range.upperBound...]
                return (cleanCommand(String(command)), true)
            }
        }

        return (cleanCommand(text), false)
    }

    static func cleanCommand(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?")))
    }

    static func insertedTextLooksDictated(_ insertedText: String) -> Bool {
        let cleaned = cleanCommand(insertedText)
        guard !cleaned.isEmpty else { return false }

        return cleaned.count >= 4 || cleaned.contains { $0.isWhitespace }
    }

    static func shouldScheduleIdleSubmit(
        backspaceCount: Int,
        insertedText: String,
        command: String,
        alreadyArmed: Bool
    ) -> Bool {
        let cleanedCommand = cleanCommand(command)
        guard !cleanedCommand.isEmpty else { return false }

        if insertedTextLooksDictated(insertedText) {
            return true
        }

        return alreadyArmed && backspaceCount > 0
    }
}
