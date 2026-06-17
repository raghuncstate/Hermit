import Testing
import Foundation
@testable import Hermit

@Suite("Model Codable Tests")
struct ModelTests {
    @Test func hostRoundTrip() throws {
        let host = Host(
            displayName: "Test Mac",
            hostname: "192.168.1.1",
            port: 22,
            username: "dev",
            privateKeyRef: "key-ref-123",
            jumpHost: SSHJumpHost(
                hostname: "raghudt",
                username: "raghupathyk",
                privateKeyRef: "jump-key-ref"
            ),
            tmuxCommand: " /Users/dev/bin/tmux "
        )
        let data = try JSONEncoder.hermit.encode(host)
        let decoded = try JSONDecoder.hermit.decode(Host.self, from: data)
        #expect(decoded.displayName == host.displayName)
        #expect(decoded.hostname == host.hostname)
        #expect(decoded.port == host.port)
        #expect(decoded.username == host.username)
        #expect(decoded.privateKeyRef == host.privateKeyRef)
        #expect(decoded.jumpHost == host.jumpHost)
        #expect(decoded.tmuxCommand == "/Users/dev/bin/tmux")
    }

    @Test func hostRoundTripsTmuxSocketName() throws {
        let host = Host(
            displayName: "Hermit Mac",
            hostname: "127.0.0.1",
            port: 22220,
            username: "raghu",
            defaultTmuxSessionName: "hermit-mobile",
            tmuxSocketName: " hermit-mobile "
        )

        let data = try JSONEncoder.hermit.encode(host)
        let decoded = try JSONDecoder.hermit.decode(Host.self, from: data)

        #expect(decoded.defaultTmuxSessionName == "hermit-mobile")
        #expect(decoded.tmuxSocketName == "hermit-mobile")
    }

    @Test func sessionRoundTrip() throws {
        let session = Session(
            displayName: "claude-session",
            hostID: UUID(),
            tmuxSessionName: "claude"
        )
        let data = try JSONEncoder.hermit.encode(session)
        let decoded = try JSONDecoder.hermit.decode(Session.self, from: data)
        #expect(decoded.displayName == session.displayName)
        #expect(decoded.tmuxSessionName == session.tmuxSessionName)
    }

    @Test func sessionWithNilTmux() throws {
        let session = Session(displayName: "raw-shell", hostID: UUID())
        let data = try JSONEncoder.hermit.encode(session)
        let decoded = try JSONDecoder.hermit.decode(Session.self, from: data)
        #expect(decoded.tmuxSessionName == nil)
    }

    @Test func terminalPagerMacrosSendPageKeysWithoutForcingBottomFollow() {
        let pageUp = TmuxMacro.defaults.first { $0.label == "PgUp" }
        let pageDown = TmuxMacro.defaults.first { $0.label == "PgDn" }

        #expect(pageUp?.key == "PageUp")
        #expect(pageUp?.preservesViewport == true)
        #expect(pageDown?.key == "PageDown")
        #expect(pageDown?.preservesViewport == true)
    }

    @Test func defaultMacrosPreferCtrlUAndDoNotIncludeRemovedControls() {
        let labels = Set(TmuxMacro.defaults.map(\.label))

        #expect(labels.contains("Ctrl-U"))
        #expect(!labels.contains("Ctrl-C"))
        #expect(!labels.contains("q"))
        #expect(!labels.contains("/clear"))
        #expect(TmuxMacro.defaults.first { $0.label == "Ctrl-U" }?.key == "C-u")
    }

    @Test func claudePanesPreferTerminalPager() {
        let titledClaudePane = TmuxPane(
            id: "%1",
            index: 0,
            title: "✳ Claude Code",
            isActive: true,
            width: 80,
            height: 24,
            currentCommand: "2.1.170"
        )
        let namedClaudePane = TmuxPane(
            id: "%2",
            index: 0,
            title: "project",
            isActive: true,
            width: 80,
            height: 24,
            currentCommand: "node"
        )

        #expect(titledClaudePane.prefersTerminalPager(windowName: "irsfine"))
        #expect(namedClaudePane.prefersTerminalPager(windowName: "google-drtm-claude"))
    }

    @Test func codexPanesKeepAppSidePanePaging() {
        let codexPane = TmuxPane(
            id: "%3",
            index: 0,
            title: "tmp",
            isActive: true,
            width: 80,
            height: 24,
            currentCommand: "node"
        )

        #expect(!codexPane.prefersTerminalPager(windowName: "hermit iphone"))
        #expect(!codexPane.prefersTerminalPager(windowName: "google-drtm-codex"))
    }
}
