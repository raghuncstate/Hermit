import Testing
import Foundation
@testable import Hermit

@Suite("URL Scheme Tests")
struct URLSchemeTests {
    @Test func parsesVoiceCallbackURL() {
        let coordinator = VoiceInputCoordinator()
        let url = URL(string: "hermit://voice-callback?text=hello%20world")!
        coordinator.handleCallbackURL(url)
        #expect(coordinator.transcribedText == "hello world")
        #expect(coordinator.isShowingVoiceModal == true)
    }

    @Test func ignoresInvalidScheme() {
        let coordinator = VoiceInputCoordinator()
        let url = URL(string: "other://voice-callback?text=hello")!
        coordinator.handleCallbackURL(url)
        #expect(coordinator.isShowingVoiceModal == false)
    }

    @Test func ignoresInvalidHost() {
        let coordinator = VoiceInputCoordinator()
        let url = URL(string: "hermit://other-action?text=hello")!
        coordinator.handleCallbackURL(url)
        #expect(coordinator.isShowingVoiceModal == false)
    }

    @Test func handlesMissingTextParameter() {
        let coordinator = VoiceInputCoordinator()
        let url = URL(string: "hermit://voice-callback")!
        coordinator.handleCallbackURL(url)
        #expect(coordinator.isShowingVoiceModal == false)
    }

    @Test func handlesEncodedSpecialCharacters() {
        let coordinator = VoiceInputCoordinator()
        let url = URL(string: "hermit://voice-callback?text=say%20%22hello%22%20%26%20goodbye")!
        coordinator.handleCallbackURL(url)
        #expect(coordinator.transcribedText == "say \"hello\" & goodbye")
    }

    @Test func stripsVoiceSubmitPhrase() {
        let result = VoiceCommandAutoSubmit.commandByRemovingSubmitPhrase(from: "git status send the message")

        #expect(result.shouldSubmit)
        #expect(result.command == "git status")
    }

    @Test func stripsVoiceSubmitPhraseWithTrailingPunctuation() {
        let result = VoiceCommandAutoSubmit.commandByRemovingSubmitPhrase(from: "echo hello send message.")

        #expect(result.shouldSubmit)
        #expect(result.command == "echo hello")
    }

    @Test func detectsDictatedTextChunks() {
        #expect(VoiceCommandAutoSubmit.insertedTextLooksDictated("git status"))
        #expect(VoiceCommandAutoSubmit.insertedTextLooksDictated("hello"))
        #expect(!VoiceCommandAutoSubmit.insertedTextLooksDictated("g"))
    }

    @Test func schedulesIdleSubmitForDictatedCorrection() {
        #expect(VoiceCommandAutoSubmit.shouldScheduleIdleSubmit(
            backspaceCount: 0,
            insertedText: "git status",
            command: "git status",
            alreadyArmed: false
        ))

        #expect(VoiceCommandAutoSubmit.shouldScheduleIdleSubmit(
            backspaceCount: 2,
            insertedText: "tus",
            command: "git status",
            alreadyArmed: true
        ))
    }

    @Test func doesNotIdleSubmitShortManualTyping() {
        #expect(!VoiceCommandAutoSubmit.shouldScheduleIdleSubmit(
            backspaceCount: 0,
            insertedText: "g",
            command: "g",
            alreadyArmed: false
        ))

        #expect(!VoiceCommandAutoSubmit.shouldScheduleIdleSubmit(
            backspaceCount: 1,
            insertedText: "",
            command: "",
            alreadyArmed: true
        ))
    }
}
