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

    @Test func reconcileTmuxShortcutsUpdatesLiveMetadataAndRemovesMissingWindows() throws {
        let store = DataStore()
        let host = Host(displayName: "This Mac via raghudt", hostname: "127.0.0.1", port: 22220, username: "raghu")
        let savedSession = TmuxSession(id: "$old", name: "0", attachedCount: 1)
        let savedWindow = TmuxWindow(id: "@2", sessionId: "$old", index: 0, name: "old-name", isActive: true, layout: "")
        let missingWindow = TmuxWindow(id: "@99", sessionId: "$old", index: 9, name: "gone", isActive: false, layout: "")
        let liveSession = TmuxSession(id: "$1", name: "0", attachedCount: 1)
        let liveWindow = TmuxWindow(id: "@2", sessionId: "$1", index: 3, name: "codex", isActive: true, layout: "")
        let oldDate = Date(timeIntervalSince1970: 1)

        store.hosts = [host]
        store.tmuxShortcuts = [
            TmuxShortcut(
                kind: .window,
                host: host,
                session: savedSession,
                window: savedWindow,
                isFavorite: true,
                visitCount: 4,
                lastVisitedAt: oldDate
            ),
            TmuxShortcut(
                kind: .window,
                host: host,
                session: savedSession,
                window: missingWindow,
                isFavorite: true,
                visitCount: 3,
                lastVisitedAt: oldDate
            )
        ]

        store.reconcileTmuxShortcuts(
            for: host,
            sessions: [liveSession],
            windowsBySession: [liveSession.id: [liveWindow]],
            panesByWindow: [:]
        )

        #expect(store.tmuxShortcuts.count == 1)
        #expect(store.tmuxShortcuts[0].isFavorite)
        #expect(store.tmuxShortcuts[0].visitCount == 4)
        #expect(store.tmuxShortcuts[0].sessionID == "$1")
        #expect(store.tmuxShortcuts[0].windowIndex == 3)
        #expect(store.tmuxShortcuts[0].windowName == "codex")
    }

    @Test func recordVisitPrunesObsoleteMacHermitMobileShortcut() throws {
        let store = DataStore()
        let macHost = Host(
            id: UUID(uuidString: "EED9DA12-53C1-489C-B761-3013BDD43355")!,
            displayName: "This Mac via raghudt",
            hostname: "127.0.0.1",
            port: 22220,
            username: "raghu"
        )
        let obsoleteSession = TmuxSession(id: "$old", name: "hermit-mobile", attachedCount: 0)
        let obsoleteWindow = TmuxWindow(id: "@old", sessionId: "$old", index: 0, name: "bash", isActive: true, layout: "")
        let liveSession = TmuxSession(id: "$1", name: "0", attachedCount: 1)
        let liveWindow = TmuxWindow(id: "@2", sessionId: "$1", index: 0, name: "node", isActive: true, layout: "")

        store.hosts = [macHost]
        store.tmuxShortcuts = [
            TmuxShortcut(
                kind: .window,
                host: macHost,
                session: obsoleteSession,
                window: obsoleteWindow,
                isFavorite: true,
                visitCount: 8
            )
        ]

        store.recordVisit(TmuxShortcut(kind: .window, host: macHost, session: liveSession, window: liveWindow))

        #expect(store.tmuxShortcuts.count == 1)
        #expect(store.tmuxShortcuts[0].sessionName == "0")
        #expect(store.tmuxShortcuts[0].windowName == "node")
    }
}
