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
        #expect(decoded.tmuxShortcuts[0].displayTitle == "codex")
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

    @Test func hostDefaultsToExistingTmuxSessionName() throws {
        let json = """
        {
          "createdAt" : "2026-05-25T00:00:00Z",
          "displayName" : "raghudt",
          "hostname" : "10.110.49.244",
          "id" : "00000000-0000-0000-0000-000000000001",
          "port" : 22,
          "privateKeyRef" : "test-key",
          "username" : "raghupathyk"
        }
        """

        let decoded = try JSONDecoder.hermit.decode(Host.self, from: Data(json.utf8))

        #expect(decoded.defaultTmuxSessionName == "0")
    }

    @Test func tmuxShortcutMergeKeepsFavoriteAndLatestMetadata() throws {
        let host = Host(displayName: "This Mac", hostname: "192.168.86.195", username: "raghu")
        let tmuxSession = TmuxSession(id: "$1", name: "claude", attachedCount: 1)
        let oldWindow = TmuxWindow(id: "@2", sessionId: "$1", index: 1, name: "codex", isActive: true, layout: "")
        let newWindow = TmuxWindow(id: "@2", sessionId: "$1", index: 1, name: "codex-renamed", isActive: true, layout: "")
        let oldDate = Date(timeIntervalSince1970: 1)
        let newDate = Date(timeIntervalSince1970: 2)

        var shortcut = TmuxShortcut(
            kind: .window,
            host: host,
            session: tmuxSession,
            window: oldWindow,
            isFavorite: true,
            visitCount: 3,
            lastVisitedAt: oldDate
        )
        var newerShortcut = TmuxShortcut(
            kind: .window,
            host: host,
            session: tmuxSession,
            window: newWindow,
            isFavorite: false,
            visitCount: 1,
            lastVisitedAt: newDate
        )
        newerShortcut.hostDisplayName = "This Mac via raghudt"

        shortcut.mergeMetadata(from: newerShortcut)

        #expect(shortcut.isFavorite)
        #expect(shortcut.visitCount == 3)
        #expect(shortcut.lastVisitedAt == newDate)
        #expect(shortcut.hostDisplayName == "This Mac via raghudt")
        #expect(shortcut.windowName == "codex-renamed")
    }
}
