import Testing
import Foundation
@testable import Hermit

@Suite("DataStore Backup Tests")
struct DataStoreTests {
    @Test func backupRoundTrip() throws {
        let host = Host(displayName: "Test", hostname: "10.0.0.1", username: "user")
        let session = Session(displayName: "Session1", hostID: host.id, tmuxSessionName: "dev")

        let backup = BackupData(
            version: 1,
            exportedAt: Date(),
            hosts: [host],
            sessions: [session]
        )

        let data = try JSONEncoder.hermit.encode(backup)
        let decoded = try JSONDecoder.hermit.decode(BackupData.self, from: data)

        #expect(decoded.version == 1)
        #expect(decoded.hosts.count == 1)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.hosts[0].displayName == "Test")
        #expect(decoded.sessions[0].tmuxSessionName == "dev")
    }

    @Test func backupExcludesPrivateKeys() throws {
        let host = Host(
            displayName: "Test",
            hostname: "10.0.0.1",
            username: "user",
            privateKeyRef: "keychain-ref-abc"
        )
        let backup = BackupData(version: 1, exportedAt: Date(), hosts: [host], sessions: [])
        let data = try JSONEncoder.hermit.encode(backup)
        let json = String(data: data, encoding: .utf8)!

        // privateKeyRef is stored but the actual key material stays in Keychain
        #expect(json.contains("keychain-ref-abc"))
        #expect(!json.contains("BEGIN RSA PRIVATE KEY"))
    }

    @Test func backupRoundTripsTmuxShortcuts() throws {
        let host = Host(displayName: "Dev", hostname: "raghudt", username: "raghu")
        let tmuxSession = TmuxSession(id: "$1", name: "claude", attachedCount: 1)
        let tmuxWindow = TmuxWindow(id: "@2", sessionId: "$1", index: 1, name: "codex", isActive: true, layout: "")
        let pane = TmuxPane(id: "%3", index: 0, title: "", isActive: true, width: 120, height: 40, currentCommand: "zsh")
        let shortcut = TmuxShortcut(
            kind: .pane,
            host: host,
            session: tmuxSession,
            window: tmuxWindow,
            pane: pane,
            isFavorite: true,
            visitCount: 7
        )

        let backup = BackupData(
            version: 1,
            exportedAt: Date(),
            hosts: [host],
            sessions: [],
            tmuxShortcuts: [shortcut]
        )

        let data = try JSONEncoder.hermit.encode(backup)
        let decoded = try JSONDecoder.hermit.decode(BackupData.self, from: data)

        #expect(decoded.tmuxShortcuts.count == 1)
        #expect(decoded.tmuxShortcuts[0].isFavorite)
        #expect(decoded.tmuxShortcuts[0].visitCount == 7)
        #expect(decoded.tmuxShortcuts[0].displayTitle == "zsh")
    }

    @Test func backupReadsOlderFilesWithoutShortcuts() throws {
        let json = """
        {
          "exportedAt" : "2026-05-25T00:00:00Z",
          "hosts" : [],
          "sessions" : [],
          "version" : 1
        }
        """

        let decoded = try JSONDecoder.hermit.decode(BackupData.self, from: Data(json.utf8))

        #expect(decoded.tmuxShortcuts.isEmpty)
    }
}
