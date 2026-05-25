import Foundation
import SwiftUI

struct TmuxPaneSnapshot {
    var paneId: String
    var rawText: String
    var lines: [AnsiLine]

    init(paneId: String, rawText: String) {
        self.paneId = paneId
        self.rawText = rawText
        self.lines = AnsiAttributedStringParser.parseLines(rawText)
    }
}

struct TmuxMacro: Identifiable, Hashable {
    var id: String { label + key }
    var label: String
    var systemImage: String?
    var key: String
    var sendsLiteralText: Bool = false
    var appendsEnter: Bool = false

    static let defaults: [TmuxMacro] = [
        TmuxMacro(label: "Esc", systemImage: nil, key: "Escape"),
        TmuxMacro(label: "Tab", systemImage: nil, key: "Tab"),
        TmuxMacro(label: "Enter", systemImage: "return", key: "Enter"),
        TmuxMacro(label: "Up", systemImage: "arrow.up", key: "Up"),
        TmuxMacro(label: "Down", systemImage: "arrow.down", key: "Down"),
        TmuxMacro(label: "Left", systemImage: "arrow.left", key: "Left"),
        TmuxMacro(label: "Right", systemImage: "arrow.right", key: "Right"),
        TmuxMacro(label: "Ctrl-C", systemImage: nil, key: "C-c"),
        TmuxMacro(label: "Ctrl-D", systemImage: nil, key: "C-d"),
        TmuxMacro(label: "Ctrl-Z", systemImage: nil, key: "C-z"),
        TmuxMacro(label: "q", systemImage: nil, key: "q", sendsLiteralText: true),
        TmuxMacro(label: "/clear", systemImage: nil, key: "/clear", sendsLiteralText: true, appendsEnter: true),
    ]
}

@MainActor
@Observable
final class TmuxWorkspaceModel {
    private struct PendingLocalEcho {
        var text: String
        var expiresAt: Date
    }

    private static let outputCaptureIntervalNanoseconds: UInt64 = 4_000_000
    private static let inputRefreshDelayNanoseconds: UInt64 = 4_000_000
    private static let liveCaptureHistoryLimit = 240
    private static let scrollbackCaptureHistoryLimit = 3000
    private static let localEchoDuration: TimeInterval = 1.2

    let host: Host
    var status: TmuxConnectionStatus = .disconnected
    var sessions: [TmuxSession] = []
    var windowsBySession: [String: [TmuxWindow]] = [:]
    var panesByWindow: [String: [TmuxPane]] = [:]
    var snapshotsByPane: [String: TmuxPaneSnapshot] = [:]
    var errorMessage: String?

    private var client: TmuxControlClient?
    private var eventTask: Task<Void, Never>?
    private var followedPaneIds: Set<String> = []
    private var outputCaptureTasks: [String: Task<Void, Never>] = [:]
    private var pendingLocalEchoByPane: [String: PendingLocalEcho] = [:]

    init(host: Host) {
        self.host = host
    }

    func connectIfNeeded() async {
        guard client == nil else { return }
        await reconnect()
    }

    func reconnect() async {
        await disconnect()
        status = .connecting
        errorMessage = nil

        do {
            let controlClient = try await TmuxControlClient.connect(
                host: host,
                sessionName: host.defaultTmuxSessionName
            )
            client = controlClient
            status = .connected
            startEventPump(controlClient)
            await refreshSessions()
        } catch {
            status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        if let client {
            await client.disconnect()
        }
        client = nil
        outputCaptureTasks.values.forEach { $0.cancel() }
        outputCaptureTasks.removeAll()
        pendingLocalEchoByPane.removeAll()
        status = .disconnected
    }

    func refreshSessions() async {
        guard let client else {
            await connectIfNeeded()
            guard self.client != nil else { return }
            await refreshSessions()
            return
        }

        do {
            var fetched = try await client.listSessions().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            sessions = fetched
            errorMessage = nil

            for index in fetched.indices {
                do {
                    let windows = try await client.listWindows(sessionId: fetched[index].id)
                    fetched[index].windowCount = windows.count
                    windowsBySession[fetched[index].id] = windows.sorted { $0.index < $1.index }
                    if let sessionIndex = sessions.firstIndex(where: { $0.id == fetched[index].id }) {
                        sessions[sessionIndex].windowCount = windows.count
                    }
                } catch {
                    if windowsBySession[fetched[index].id] == nil {
                        windowsBySession[fetched[index].id] = []
                    }
                    errorMessage = "Some tmux windows could not be loaded: \(error.localizedDescription)"
                }
            }
        } catch {
            handle(error)
        }
    }

    func refreshWindows(for session: TmuxSession) async {
        guard let client else { return }
        do {
            let windows = try await client.listWindows(sessionId: session.id).sorted { $0.index < $1.index }
            windowsBySession[session.id] = windows

            for window in windows {
                let panes = try await client.listPanes(windowId: window.id).sorted { $0.index < $1.index }
                panesByWindow[window.id] = panes
            }
        } catch {
            handle(error)
        }
    }

    func loadWindow(_ window: TmuxWindow) async {
        guard let client else { return }
        do {
            let panes = try await client.listPanes(windowId: window.id).sorted { $0.index < $1.index }
            panesByWindow[window.id] = panes
            if let activePane = panes.first(where: \.isActive) ?? panes.first {
                await captureLive(activePane)
                setFollow(activePane.id, enabled: true)
                prefetchRecentScrollback(for: panes, excluding: activePane.id)
            } else {
                prefetchRecentScrollback(for: panes)
            }
        } catch {
            handle(error)
        }
    }

    func capture(_ pane: TmuxPane) async {
        await captureScrollback(pane)
    }

    func captureLive(_ pane: TmuxPane) async {
        await capture(paneId: pane.id, historyLimit: Self.liveCaptureHistoryLimit)
    }

    func captureScrollback(_ pane: TmuxPane) async {
        await capture(paneId: pane.id, historyLimit: Self.scrollbackCaptureHistoryLimit)
    }

    private func capture(paneId: String, historyLimit: Int) async {
        guard let client else { return }
        do {
            let rawText = try await client.capturePane(paneId: paneId, historyLimit: historyLimit)
            let displayText = textWithPendingLocalEcho(rawText, paneId: paneId)
            if snapshotsByPane[paneId]?.rawText != displayText {
                snapshotsByPane[paneId] = TmuxPaneSnapshot(paneId: paneId, rawText: displayText)
            }
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func select(_ pane: TmuxPane, in window: TmuxWindow) async {
        guard let client else { return }
        do {
            try await client.selectPane(paneId: pane.id)
            let selectedPaneId = pane.id
            panesByWindow[window.id] = panes(for: window).map {
                var updatedPane = $0
                updatedPane.isActive = updatedPane.id == selectedPaneId
                return updatedPane
            }
            setFollow(pane.id, enabled: true)
            await captureLive(pane)
        } catch {
            handle(error)
        }
    }

    func setFollow(_ paneId: String, enabled: Bool) {
        if enabled {
            followedPaneIds.insert(paneId)
        } else {
            followedPaneIds.remove(paneId)
        }
    }

    func send(_ macro: TmuxMacro, to pane: TmuxPane) async {
        do {
            if macro.sendsLiteralText {
                try await client?.sendText(macro.key, to: pane.id, enter: macro.appendsEnter)
            } else {
                try await client?.sendKey(macro.key, to: pane.id)
            }
            await captureAfterInput(pane)
        } catch {
            handle(error)
        }
    }

    func sendCommand(_ command: String, to pane: TmuxPane) async {
        do {
            try await client?.sendText(command, to: pane.id, enter: true)
            await captureAfterInput(pane)
        } catch {
            handle(error)
        }
    }

    func sendInputText(_ text: String, to pane: TmuxPane) async {
        guard !text.isEmpty else { return }
        do {
            try await client?.sendText(text, to: pane.id, enter: false)
        } catch {
            handle(error)
        }
    }

    func sendBackspace(count: Int, to pane: TmuxPane) async {
        guard count > 0 else { return }
        do {
            try await client?.sendBackspace(count: count, to: pane.id)
        } catch {
            handle(error)
        }
    }

    func sendEnter(to pane: TmuxPane) async {
        do {
            try await client?.sendText("", to: pane.id, enter: true)
            await captureAfterInput(pane)
        } catch {
            handle(error)
        }
    }

    func echoSubmittedCommand(_ command: String, to pane: TmuxPane) {
        appendLocalEcho(command + "\n", paneId: pane.id)
    }

    func echoInputText(_ text: String, to pane: TmuxPane) {
        appendLocalEcho(text, paneId: pane.id)
    }

    func echoEnter(to pane: TmuxPane) {
        appendLocalEcho("\n", paneId: pane.id)
    }

    func echoBackspace(count: Int, to pane: TmuxPane) {
        guard count > 0 else { return }
        guard var pendingEcho = pendingLocalEchoByPane[pane.id], !pendingEcho.text.isEmpty else { return }

        let removalCount = min(count, pendingEcho.text.count)
        pendingEcho.text.removeLast(removalCount)
        pendingEcho.expiresAt = Date().addingTimeInterval(Self.localEchoDuration)

        if pendingEcho.text.isEmpty {
            pendingLocalEchoByPane[pane.id] = nil
        } else {
            pendingLocalEchoByPane[pane.id] = pendingEcho
        }

        var displayedText = snapshotsByPane[pane.id]?.rawText ?? ""
        let displayRemovalCount = min(removalCount, displayedText.count)
        if displayRemovalCount > 0 {
            displayedText.removeLast(displayRemovalCount)
            snapshotsByPane[pane.id] = TmuxPaneSnapshot(paneId: pane.id, rawText: displayedText)
        }
    }

    func newSession(named name: String) async {
        guard !name.isEmpty else { return }
        do {
            try await client?.newSession(named: name)
            await refreshSessions()
        } catch {
            handle(error)
        }
    }

    func killSession(_ session: TmuxSession) async {
        do {
            try await client?.killSession(sessionId: session.id)
            await refreshSessions()
        } catch {
            handle(error)
        }
    }

    func newWindow(in session: TmuxSession) async {
        do {
            try await client?.newWindow(sessionId: session.id)
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func renameWindow(_ window: TmuxWindow, to name: String, in session: TmuxSession) async {
        guard !name.isEmpty else { return }
        do {
            try await client?.renameWindow(windowId: window.id, name: name)
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func killWindow(_ window: TmuxWindow, in session: TmuxSession) async {
        do {
            try await client?.killWindow(windowId: window.id)
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func moveWindow(_ window: TmuxWindow, by offset: Int, in session: TmuxSession) async {
        do {
            try await client?.moveWindow(windowId: window.id, by: offset)
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func selectWindow(_ window: TmuxWindow, in session: TmuxSession) async {
        do {
            try await client?.selectWindow(windowId: window.id)
            await refreshWindows(for: session)
            let selectedWindow = windows(for: session).first { $0.id == window.id } ?? window
            await loadWindow(selectedWindow)
        } catch {
            handle(error)
        }
    }

    func split(_ pane: TmuxPane, in window: TmuxWindow, vertical: Bool) async {
        do {
            try await client?.splitPane(paneId: pane.id, vertical: vertical)
            await refreshWindow(window)
        } catch {
            handle(error)
        }
    }

    func kill(_ pane: TmuxPane, in window: TmuxWindow) async {
        do {
            try await client?.killPane(paneId: pane.id)
            await refreshWindow(window)
        } catch {
            handle(error)
        }
    }

    func refreshWindow(_ window: TmuxWindow) async {
        guard let client else { return }
        do {
            panesByWindow[window.id] = try await client.listPanes(windowId: window.id).sorted { $0.index < $1.index }
        } catch {
            handle(error)
        }
    }

    func refreshPanes(for window: TmuxWindow) async {
        await refreshWindow(window)
    }

    func resizeForDisplay(_ pane: TmuxPane, cols: Int, rows: Int, in window: TmuxWindow) async {
        guard let client, cols > 0, rows > 0 else { return }
        guard abs(pane.width - cols) > 1 || abs(pane.height - rows) > 1 else { return }

        do {
            try await client.resizePane(paneId: pane.id, cols: cols, rows: rows)
            await refreshWindow(window)
            if let resizedPane = panes(for: window).first(where: { $0.id == pane.id }) {
                await captureLive(resizedPane)
            } else {
                await captureLive(pane)
            }
        } catch {
            handle(error)
        }
    }

    func windows(for session: TmuxSession) -> [TmuxWindow] {
        windowsBySession[session.id] ?? []
    }

    func panes(for window: TmuxWindow) -> [TmuxPane] {
        panesByWindow[window.id] ?? []
    }

    func activePane(for window: TmuxWindow) -> TmuxPane? {
        panes(for: window).first(where: \.isActive) ?? panes(for: window).first
    }

    private func startEventPump(_ controlClient: TmuxControlClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in controlClient.events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: TmuxControlEvent) async {
        switch event {
        case .output(let paneId, _), .extendedOutput(let paneId, _, _):
            scheduleOutputCapture(paneId: paneId)
        case .sessionsChanged:
            await refreshSessions()
        case .windowAdd, .windowClose, .windowRenamed, .layoutChange, .windowPaneChanged, .sessionWindowChanged:
            await refreshSessions()
        case .sessionChanged, .paneModeChanged, .pause, .continued:
            break
        case .exit:
            status = .disconnected
            client = nil
        }
    }

    private func scheduleOutputCapture(paneId: String) {
        guard followedPaneIds.contains(paneId) else { return }
        guard outputCaptureTasks[paneId] == nil else { return }

        outputCaptureTasks[paneId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.outputCaptureIntervalNanoseconds)
            await self?.captureScheduledOutput(for: paneId)
        }
    }

    private func captureScheduledOutput(for paneId: String) async {
        outputCaptureTasks[paneId] = nil
        if let pane = pane(withId: paneId) {
            await captureLive(pane)
        } else {
            await capture(paneId: paneId, historyLimit: Self.liveCaptureHistoryLimit)
        }
    }

    private func captureAfterInput(_ pane: TmuxPane) async {
        try? await Task.sleep(nanoseconds: Self.inputRefreshDelayNanoseconds)
        await captureLive(pane)
    }

    private func appendLocalEcho(_ text: String, paneId: String) {
        guard !text.isEmpty else { return }
        let existingEcho = pendingLocalEchoByPane[paneId]?.text ?? ""
        pendingLocalEchoByPane[paneId] = PendingLocalEcho(
            text: existingEcho + text,
            expiresAt: Date().addingTimeInterval(Self.localEchoDuration)
        )

        let existing = snapshotsByPane[paneId]?.rawText ?? ""
        snapshotsByPane[paneId] = TmuxPaneSnapshot(
            paneId: paneId,
            rawText: existing + text
        )
    }

    private func textWithPendingLocalEcho(_ rawText: String, paneId: String) -> String {
        guard let pendingEcho = pendingLocalEchoByPane[paneId] else {
            return rawText
        }

        if pendingEcho.expiresAt <= Date() {
            pendingLocalEchoByPane[paneId] = nil
            return rawText
        }

        let unappliedEcho = unappliedLocalEcho(pendingEcho.text, rawText: rawText)
        if unappliedEcho.isEmpty {
            pendingLocalEchoByPane[paneId] = nil
            return rawText
        }

        return rawText + unappliedEcho
    }

    private func unappliedLocalEcho(_ echoText: String, rawText: String) -> String {
        guard !echoText.isEmpty else { return "" }
        let echoCharacters = Array(echoText)

        for matchedCount in stride(from: echoCharacters.count, through: 1, by: -1) {
            let echoedPrefix = String(echoCharacters.prefix(matchedCount))
            if rawText.hasSuffix(echoedPrefix) {
                return String(echoCharacters.dropFirst(matchedCount))
            }
        }

        return echoText
    }

    private func pane(withId paneId: String) -> TmuxPane? {
        for panes in panesByWindow.values {
            if let pane = panes.first(where: { $0.id == paneId }) {
                return pane
            }
        }
        return nil
    }

    private func prefetchRecentScrollback(for panes: [TmuxPane], excluding excludedPaneId: String? = nil) {
        let panesToPrefetch = panes.filter { pane in
            pane.id != excludedPaneId && snapshotsByPane[pane.id] == nil
        }
        guard !panesToPrefetch.isEmpty else { return }

        Task { @MainActor [weak self] in
            for pane in panesToPrefetch {
                guard !Task.isCancelled else { return }
                await self?.captureLive(pane)
            }
        }
    }

    private func handle(_ error: Error) {
        errorMessage = error.localizedDescription
        if case .connecting = status {
            status = .failed(error.localizedDescription)
        }
    }
}
