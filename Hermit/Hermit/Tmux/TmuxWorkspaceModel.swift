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
    var preservesViewport: Bool = false

    static let defaults: [TmuxMacro] = [
        TmuxMacro(label: "Esc", systemImage: nil, key: "Escape"),
        TmuxMacro(label: "Tab", systemImage: nil, key: "Tab"),
        TmuxMacro(label: "Enter", systemImage: "return", key: "Enter"),
        TmuxMacro(label: "Up", systemImage: "arrow.up", key: "Up"),
        TmuxMacro(label: "Down", systemImage: "arrow.down", key: "Down"),
        TmuxMacro(label: "PgUp", systemImage: "chevron.up.2", key: "PageUp", preservesViewport: true),
        TmuxMacro(label: "PgDn", systemImage: "chevron.down.2", key: "PageDown", preservesViewport: true),
        TmuxMacro(label: "Left", systemImage: "arrow.left", key: "Left"),
        TmuxMacro(label: "Right", systemImage: "arrow.right", key: "Right"),
        TmuxMacro(label: "Ctrl-U", systemImage: nil, key: "C-u"),
        TmuxMacro(label: "Ctrl-D", systemImage: nil, key: "C-d"),
        TmuxMacro(label: "Ctrl-Z", systemImage: nil, key: "C-z"),
    ]
}

struct TmuxKeyModifiers {
    var shift = false

    func resolve(_ macro: TmuxMacro) -> TmuxMacro {
        guard shift, !macro.sendsLiteralText else { return macro }
        let key: String
        switch macro.key {
        case "Tab": key = "BTab"
        case "Up", "Down", "Left", "Right": key = "S-\(macro.key)"
        default: return macro
        }
        var modified = macro
        modified.key = key
        modified.label = "Shift+\(macro.label)"
        return modified
    }

    mutating func consume(_ macro: TmuxMacro) -> TmuxMacro {
        defer { shift = false }
        return resolve(macro)
    }
}

@MainActor
@Observable
final class TmuxWorkspaceModel {
    private static let outputCaptureIntervalNanoseconds: UInt64 = 16_000_000
    private static let livePollIntervalNanoseconds: UInt64 = 200_000_000
    private static let liveCaptureHistoryLimit = 240
    private static let scrollbackCaptureHistoryLimit = 3000

    let host: Host
    var status: TmuxConnectionStatus = .disconnected
    var sessions: [TmuxSession] = []
    var windowsBySession: [String: [TmuxWindow]] = [:]
    var panesByWindow: [String: [TmuxPane]] = [:]
    var snapshotsByPane: [String: TmuxPaneSnapshot] = [:]
    var errorMessage: String?
    private(set) var inputErrorMessage: String?
    private(set) var isSuspended = false
    private(set) var connectionGeneration = 0

    private var client: (any TmuxCommandClient)?
    private let makeClient: @Sendable (Host) async throws -> any TmuxCommandClient
    private var connectionTask: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var inputTask: Task<Bool, Never>?
    private var inputRequestID: UUID?
    private var displaySizesByWindow: [String: String] = [:]
    private var eventTask: Task<Void, Never>?
    private var followedPaneIds: Set<String> = []
    private var outputCaptureTasks: [String: Task<Void, Never>] = [:]
    private var livePollTasks: [String: Task<Void, Never>] = [:]
    private var captureRequests: [String: UUID] = [:]
    private var pendingCaptureHistoryLimits: [String: Int] = [:]
    private var sparseFrameSkipCounts: [String: Int] = [:]
    init(
        host: Host,
        makeClient: @escaping @Sendable (Host) async throws -> any TmuxCommandClient = {
            try await TmuxControlClient.connect(host: $0, sessionName: $0.defaultTmuxSessionName)
        }
    ) {
        self.host = host
        self.makeClient = makeClient
    }

    func connectIfNeeded() async {
        guard !isSuspended, !Task.isCancelled else { return }
        if let connectionTask {
            await connectionTask.value
            return
        }
        guard client == nil else { return }
        await reconnect()
    }

    func reconnect() async {
        guard !isSuspended, !Task.isCancelled else { return }
        if let connectionTask {
            await connectionTask.value
            return
        }
        let generation = nextConnectionGeneration()
        let closing = closeCurrentConnection()
        status = .connecting
        errorMessage = nil

        let task = Task { @MainActor in
            await closing.value
            guard !Task.isCancelled, !isSuspended, isCurrentConnectionGeneration(generation) else { return }
            do {
                let controlClient = try await makeClient(host)
                guard !Task.isCancelled, !isSuspended, isCurrentConnectionGeneration(generation) else {
                    await controlClient.disconnect()
                    return
                }
                client = controlClient
                status = .connected
                startEventPump(controlClient, generation: generation)
            } catch {
                guard isCurrentConnectionGeneration(generation), !isSuspended else { return }
                status = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
        connectionTask = task
        await task.value
        guard isCurrentConnectionGeneration(generation) else { return }
        connectionTask = nil
        guard client != nil else { return }
        await refreshSessions()
        guard isCurrentConnectionGeneration(generation), client != nil else { return }
        for paneId in followedPaneIds { startLivePolling(paneId: paneId) }
    }

    func disconnect() async {
        let closing = invalidateConnection()
        await closing.value
    }

    // Invalidate synchronously: delayed background tasks cannot close a new connection.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        _ = invalidateConnection()
    }

    func activate() async {
        isSuspended = false
        await connectIfNeeded()
    }

    private func invalidateConnection() -> Task<Void, Never> {
        _ = nextConnectionGeneration()
        let opening = connectionTask
        opening?.cancel()
        connectionTask = nil
        let closing = closeCurrentConnection()
        status = .disconnected
        let task = Task {
            await closing.value
            await opening?.value
        }
        closingTask = task
        return task
    }

    private func closeCurrentConnection() -> Task<Void, Never> {
        eventTask?.cancel()
        eventTask = nil
        let existingClient = client
        client = nil
        outputCaptureTasks.values.forEach { $0.cancel() }
        outputCaptureTasks.removeAll()
        livePollTasks.values.forEach { $0.cancel() }
        livePollTasks.removeAll()
        captureRequests.removeAll()
        pendingCaptureHistoryLimits.removeAll()
        sparseFrameSkipCounts.removeAll()
        displaySizesByWindow.removeAll()
        let previousClosing = closingTask
        let task = Task {
            await previousClosing?.value
            await existingClient?.disconnect()
        }
        closingTask = task
        return task
    }

    private func nextConnectionGeneration() -> Int {
        connectionGeneration += 1
        return connectionGeneration
    }

    private func isCurrentConnectionGeneration(_ generation: Int) -> Bool {
        generation == connectionGeneration
    }

    @discardableResult
    private func connectedClient() async -> (any TmuxCommandClient)? {
        guard !isSuspended, !Task.isCancelled else { return nil }
        if let client {
            return client
        }

        await connectIfNeeded()
        return client
    }

    func refreshSessions() async {
        do {
            var fetched = try await withConnectedClient { client in
                try await client.listSessions()
            }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            sessions = fetched
            errorMessage = nil

            for index in fetched.indices {
                do {
                    let windows = try await withConnectedClient { client in
                        try await client.listWindows(sessionId: fetched[index].id)
                    }
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
        do {
            let windows = try await withConnectedClient { client in
                try await client.listWindows(sessionId: session.id)
            }.sorted { $0.index < $1.index }
            windowsBySession[session.id] = windows

            for window in windows {
                let panes = try await withConnectedClient { client in
                    try await client.listPanes(windowId: window.id)
                }.sorted { $0.index < $1.index }
                panesByWindow[window.id] = panes
            }
        } catch {
            handle(error)
        }
    }

    func loadWindow(_ window: TmuxWindow) async {
        do {
            let panes = try await withConnectedClient { client in
                try await client.listPanes(windowId: window.id)
            }.sorted { $0.index < $1.index }
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
        await captureLive(paneId: pane.id)
    }

    func captureScrollback(_ pane: TmuxPane) async {
        await capture(paneId: pane.id, historyLimit: Self.scrollbackCaptureHistoryLimit)
    }

    private func capture(paneId: String, historyLimit: Int) async {
        guard !Task.isCancelled else { return }
        if captureRequests[paneId] != nil {
            queuePendingCapture(paneId: paneId, historyLimit: historyLimit)
            return
        }

        let requestID = UUID()
        captureRequests[paneId] = requestID
        let requestedHistoryLimit = pendingCaptureHistoryLimits.removeValue(forKey: paneId)
            .map { broaderHistoryLimit($0, historyLimit) } ?? historyLimit
        defer {
            // An old connection's read must not clear a replacement connection's work.
            if captureRequests[paneId] == requestID {
                captureRequests[paneId] = nil
                schedulePendingCapture(paneId: paneId)
            }
        }

        do {
            let rawText = try await withConnectedClient { client in
                try await client.capturePane(paneId: paneId, historyLimit: requestedHistoryLimit)
            }
            if shouldAcceptCapture(rawText, paneId: paneId, historyLimit: requestedHistoryLimit) {
                if snapshotsByPane[paneId]?.rawText != rawText {
                    snapshotsByPane[paneId] = TmuxPaneSnapshot(paneId: paneId, rawText: rawText)
                }
            } else {
                scheduleOutputCapture(paneId: paneId)
            }

            errorMessage = nil
        } catch {
            if captureRequests[paneId] == requestID {
                pendingCaptureHistoryLimits[paneId] = nil
            }
            handle(error)
        }
    }

    func select(_ pane: TmuxPane, in window: TmuxWindow) async {
        do {
            try await withConnectedClient { client in
                try await client.selectPane(paneId: pane.id)
            }
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
            for followedPaneId in Array(followedPaneIds) where followedPaneId != paneId {
                followedPaneIds.remove(followedPaneId)
                stopLivePolling(paneId: followedPaneId)
            }
            followedPaneIds.insert(paneId)
            startLivePolling(paneId: paneId)
        } else {
            followedPaneIds.remove(paneId)
            stopLivePolling(paneId: paneId)
        }
    }

    var canSendInput: Bool {
        !isSuspended && status == .connected && client != nil && inputErrorMessage == nil
    }

    func acknowledgeInputError() {
        inputErrorMessage = nil
    }

    @discardableResult
    func send(_ macro: TmuxMacro, to pane: TmuxPane, expectedGeneration: Int? = nil) async -> Bool {
        await sendInput(to: pane, expectedGeneration: expectedGeneration) { client in
            if macro.sendsLiteralText {
                try await client.sendText(macro.key, to: pane.id, enter: macro.appendsEnter)
            } else {
                try await client.sendKey(macro.key, to: pane.id)
            }
        }
    }

    @discardableResult
    func sendCommand(_ command: String, to pane: TmuxPane) async -> Bool {
        await sendInput(to: pane) { client in
            try await client.sendText(command, to: pane.id, enter: true)
        }
    }

    @discardableResult
    func sendInputText(_ text: String, to pane: TmuxPane) async -> Bool {
        await sendInputDelta(backspaceCount: 0, insertedText: text, enter: false, to: pane)
    }

    @discardableResult
    func sendBackspace(count: Int, to pane: TmuxPane) async -> Bool {
        await sendInputDelta(backspaceCount: count, insertedText: "", enter: false, to: pane)
    }

    @discardableResult
    func sendInputDelta(backspaceCount: Int, insertedText: String, enter: Bool, to pane: TmuxPane, expectedGeneration: Int? = nil) async -> Bool {
        guard backspaceCount > 0 || !insertedText.isEmpty || enter else { return true }
        return await sendInput(to: pane, expectedGeneration: expectedGeneration) { client in
            if backspaceCount > 0 {
                try await client.sendBackspace(count: backspaceCount, to: pane.id)
            }
            if !insertedText.isEmpty {
                try await client.sendText(insertedText, to: pane.id, enter: false)
            }
            if enter {
                try await client.sendText("", to: pane.id, enter: true)
            }
        }
    }

    @discardableResult
    func sendEnter(to pane: TmuxPane) async -> Bool {
        await sendInputDelta(backspaceCount: 0, insertedText: "", enter: true, to: pane)
    }

    private func sendInput(
        to pane: TmuxPane,
        expectedGeneration: Int? = nil,
        operation: @escaping @MainActor (any TmuxCommandClient) async throws -> Void
    ) async -> Bool {
        if let expectedGeneration, expectedGeneration != connectionGeneration {
            inputErrorMessage = "Input was interrupted by a connection change. Check the prompt before continuing; the input was not resent."
            return false
        }
        guard canSendInput, let client else { return false }
        let generation = connectionGeneration
        let previous = inputTask
        let requestID = UUID()
        // Keep edits and Enter ordered. Never replay a possibly delivered command
        // on another SSH connection, or synthesize output without a terminal cursor.
        let task = Task { @MainActor in
            if let previous, !(await previous.value) { return false }
            guard isCurrentConnectionGeneration(generation), canSendInput else {
                inputErrorMessage = "Input was interrupted by a connection change. Check the prompt before continuing; the input was not resent."
                return false
            }
            do {
                try await operation(client)
                guard isCurrentConnectionGeneration(generation) else { throw CancellationError() }
                queuePendingCapture(paneId: pane.id, historyLimit: Self.liveCaptureHistoryLimit)
                schedulePendingCapture(paneId: pane.id)
                return true
            } catch {
                inputErrorMessage = "Input delivery could not be confirmed. Check the prompt before continuing; the input was not resent."
                if isCurrentConnectionGeneration(generation) { handle(error) }
                return false
            }
        }
        inputTask = task
        inputRequestID = requestID
        let delivered = await task.value
        if inputRequestID == requestID {
            inputTask = nil
            inputRequestID = nil
        }
        return delivered
    }

    func newSession(named name: String) async {
        guard !name.isEmpty else { return }
        do {
            try await withConnectedClient { client in
                try await client.newSession(named: name)
            }
            await refreshSessions()
        } catch {
            handle(error)
        }
    }

    func killSession(_ session: TmuxSession) async {
        do {
            try await withConnectedClient { client in
                try await client.killSession(sessionId: session.id)
            }
            await refreshSessions()
        } catch {
            handle(error)
        }
    }

    func newWindow(in session: TmuxSession) async {
        do {
            try await withConnectedClient { client in
                try await client.newWindow(sessionId: session.id)
            }
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func openKasmHelperWindow() async -> (session: TmuxSession, window: TmuxWindow)? {
        do {
            await connectIfNeeded()
            await refreshSessions()

            guard let session = sessions.first(where: { $0.name == host.defaultTmuxSessionName }) ?? sessions.first else {
                throw TmuxProtocolError.commandFailed("No tmux session is available.")
            }

            let script = """
            source ~/.bashrc
            clear
            printf 'Hermit Kasm helper\\n\\n'
            kasm start
            printf '\\nPassword:\\n'
            kasm password
            printf '\\n\\nUseful commands:\\n'
            printf '  kasm --help\\n'
            printf '  kasm status\\n'
            printf '  kasm password\\n'
            printf '  kasm client\\n\\n'
            exec bash -l
            """
            let command = "bash -lc \(TmuxCommandQuoter.quote(script))"

            let createdWindow = try await withConnectedClient { client in
                try await client.newWindow(sessionId: session.id, name: "kasm", command: command, detached: true)
            }
            guard let createdWindow else {
                throw TmuxProtocolError.commandFailed("tmux did not return the created Kasm window.")
            }

            await refreshWindows(for: session)
            let window = windows(for: session).first { $0.id == createdWindow.id } ?? createdWindow
            if windowsBySession[session.id]?.contains(where: { $0.id == window.id }) != true {
                var windows = windowsBySession[session.id] ?? []
                windows.append(window)
                windowsBySession[session.id] = windows.sorted { $0.index < $1.index }
            }

            await loadWindow(window)
            return (session, window)
        } catch {
            handle(error)
            return nil
        }
    }

    func renameWindow(_ window: TmuxWindow, to name: String, in session: TmuxSession) async {
        guard !name.isEmpty else { return }
        do {
            try await withConnectedClient { client in
                try await client.renameWindow(windowId: window.id, name: name)
            }
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func killWindow(_ window: TmuxWindow, in session: TmuxSession) async {
        do {
            try await withConnectedClient { client in
                try await client.killWindow(windowId: window.id)
            }
            await refreshSessions()
            if sessions.contains(where: { $0.id == session.id }) {
                await refreshWindows(for: session)
            }
        } catch {
            handle(error)
        }
    }

    func moveWindow(_ window: TmuxWindow, by offset: Int, in session: TmuxSession) async {
        do {
            try await withConnectedClient { client in
                try await client.moveWindow(windowId: window.id, by: offset)
            }
            await refreshWindows(for: session)
        } catch {
            handle(error)
        }
    }

    func selectWindow(_ window: TmuxWindow, in session: TmuxSession) async {
        do {
            try await withConnectedClient { client in
                try await client.selectWindow(windowId: window.id)
            }
            await refreshWindows(for: session)
            let selectedWindow = windows(for: session).first { $0.id == window.id } ?? window
            await loadWindow(selectedWindow)
        } catch {
            handle(error)
        }
    }

    func split(_ pane: TmuxPane, in window: TmuxWindow, vertical: Bool) async {
        do {
            try await withConnectedClient { client in
                try await client.splitPane(paneId: pane.id, vertical: vertical)
            }
            await refreshWindow(window)
        } catch {
            handle(error)
        }
    }

    func kill(_ pane: TmuxPane, in window: TmuxWindow) async {
        do {
            try await withConnectedClient { client in
                try await client.killPane(paneId: pane.id)
            }
            await refreshSessions()
            if windowsBySession[window.sessionId]?.contains(where: { $0.id == window.id }) == true {
                await refreshWindow(window)
            }
        } catch {
            handle(error)
        }
    }

    func refreshWindow(_ window: TmuxWindow) async {
        do {
            panesByWindow[window.id] = try await withConnectedClient { client in
                try await client.listPanes(windowId: window.id)
            }.sorted { $0.index < $1.index }
        } catch {
            handle(error)
        }
    }

    func refreshPanes(for window: TmuxWindow) async {
        await refreshWindow(window)
    }

    func resizeForDisplay(_ pane: TmuxPane, cols: Int, rows: Int, in window: TmuxWindow) async {
        guard cols > 0, rows > 0 else { return }
        let singlePaneWindow = panes(for: window).count <= 1
        let sizeKey = "\(cols)x\(rows)"
        if singlePaneWindow, displaySizesByWindow[window.id] == sizeKey {
            guard abs(pane.width - cols) > 1 || abs(pane.height - rows) > 1 else { return }
        }

        do {
            try await withConnectedClient { client in
                try await client.resizeDisplay(windowId: window.id, cols: cols, rows: rows)
            }
            displaySizesByWindow[window.id] = sizeKey
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

    private func startEventPump(_ controlClient: any TmuxCommandClient, generation: Int) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in controlClient.events {
                guard self?.isCurrentConnectionGeneration(generation) == true else {
                    return
                }
                await self?.handle(event, generation: generation)
            }
            guard let self, isCurrentConnectionGeneration(generation), !isSuspended else { return }
            markConnectionDropped(TmuxProtocolError.disconnected)
        }
    }

    private func handle(_ event: TmuxControlEvent, generation: Int) async {
        guard isCurrentConnectionGeneration(generation) else { return }

        switch event {
        case .output(let paneId, _), .extendedOutput(let paneId, _, _):
            scheduleOutputCapture(paneId: paneId)
        case .sessionsChanged:
            await refreshSessions()
        case .windowAdd, .windowClose, .windowRenamed, .layoutChange, .windowPaneChanged, .sessionWindowChanged:
            await refreshSessions()
        case .pause(let paneId):
            do {
                try await withConnectedClient { client in
                    try await client.continuePaneOutput(paneId: paneId)
                }
            } catch {
                handle(error)
            }
            scheduleOutputCapture(paneId: paneId)
        case .continued(let paneId):
            scheduleOutputCapture(paneId: paneId)
        case .sessionChanged, .paneModeChanged:
            break
        case .exit:
            guard isCurrentConnectionGeneration(generation) else { return }
            markConnectionDropped(TmuxProtocolError.disconnected)
        }
    }

    private func scheduleOutputCapture(paneId: String) {
        guard followedPaneIds.contains(paneId) else { return }
        queuePendingCapture(paneId: paneId, historyLimit: Self.liveCaptureHistoryLimit)
        schedulePendingCapture(paneId: paneId)
    }

    private func schedulePendingCapture(paneId: String) {
        guard pendingCaptureHistoryLimits[paneId] != nil,
              captureRequests[paneId] == nil,
              outputCaptureTasks[paneId] == nil else { return }
        let generation = connectionGeneration
        // Continuous output may always enqueue another read. Never drain it in the
        // caller's task: input and navigation must finish after one SSH round trip.
        outputCaptureTasks[paneId] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.outputCaptureIntervalNanoseconds)
            } catch {
                return
            }
            guard let self, isCurrentConnectionGeneration(generation) else { return }
            outputCaptureTasks[paneId] = nil
            guard let historyLimit = pendingCaptureHistoryLimits.removeValue(forKey: paneId) else { return }
            await capture(paneId: paneId, historyLimit: historyLimit)
        }
    }

    private func captureLive(paneId: String) async {
        await capture(paneId: paneId, historyLimit: Self.liveCaptureHistoryLimit)
    }

    private func startLivePolling(paneId: String) {
        guard !isSuspended, client != nil, livePollTasks[paneId] == nil else { return }

        livePollTasks[paneId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.livePollIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.captureLiveIfFollowed(paneId: paneId)
            }
        }
    }

    private func stopLivePolling(paneId: String) {
        livePollTasks[paneId]?.cancel()
        livePollTasks[paneId] = nil
    }

    private func withConnectedClient<T>(
        _ operation: (any TmuxCommandClient) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !isSuspended else { throw CancellationError() }
        guard let currentClient = await connectedClient() else {
            throw TmuxProtocolError.disconnected
        }
        let generation = connectionGeneration

        do {
            let result = try await operation(currentClient)
            try Task.checkCancellation()
            guard isCurrentConnectionGeneration(generation) else { throw CancellationError() }
            errorMessage = nil
            return result
        } catch {
            // A closing connection must not invalidate or reopen its replacement.
            try Task.checkCancellation()
            guard isCurrentConnectionGeneration(generation) else { throw CancellationError() }
            guard shouldReconnect(after: error) else {
                throw error
            }

            markConnectionDropped(error)
            guard let retryClient = await connectedClient() else {
                throw error
            }
            let retryGeneration = connectionGeneration

            do {
                let result = try await operation(retryClient)
                try Task.checkCancellation()
                guard isCurrentConnectionGeneration(retryGeneration) else { throw CancellationError() }
                errorMessage = nil
                return result
            } catch {
                try Task.checkCancellation()
                guard isCurrentConnectionGeneration(retryGeneration) else { throw CancellationError() }
                if shouldReconnect(after: error) {
                    markConnectionDropped(error)
                }
                throw error
            }
        }
    }

    private func captureLiveIfFollowed(paneId: String) async {
        guard followedPaneIds.contains(paneId) else {
            stopLivePolling(paneId: paneId)
            return
        }
        await captureLive(paneId: paneId)
    }

    private func queuePendingCapture(paneId: String, historyLimit: Int) {
        if let pendingHistoryLimit = pendingCaptureHistoryLimits[paneId] {
            pendingCaptureHistoryLimits[paneId] = broaderHistoryLimit(pendingHistoryLimit, historyLimit)
        } else {
            pendingCaptureHistoryLimits[paneId] = historyLimit
        }
    }

    private func broaderHistoryLimit(_ lhs: Int, _ rhs: Int) -> Int {
        if lhs <= 0 || rhs <= 0 {
            return 0
        }
        return max(lhs, rhs)
    }

    private func shouldAcceptCapture(_ rawText: String, paneId: String, historyLimit: Int) -> Bool {
        guard historyLimit == Self.liveCaptureHistoryLimit,
              followedPaneIds.contains(paneId),
              let previousText = snapshotsByPane[paneId]?.rawText,
              !previousText.isEmpty else {
            sparseFrameSkipCounts[paneId] = nil
            return true
        }

        let previousVisibleCount = visibleNonWhitespaceCount(in: previousText)
        let visibleCount = visibleNonWhitespaceCount(in: rawText)
        let sparseThreshold = max(20, previousVisibleCount / 4)
        let looksLikePartialRedraw = previousVisibleCount >= 80 && visibleCount < sparseThreshold

        guard looksLikePartialRedraw else {
            sparseFrameSkipCounts[paneId] = nil
            return true
        }

        let skippedCount = sparseFrameSkipCounts[paneId] ?? 0
        guard skippedCount >= 2 else {
            sparseFrameSkipCounts[paneId] = skippedCount + 1
            return false
        }

        sparseFrameSkipCounts[paneId] = nil
        return true
    }

    private func visibleNonWhitespaceCount(in text: String) -> Int {
        var count = 0
        var isInEscapeSequence = false

        for scalar in text.unicodeScalars {
            if isInEscapeSequence {
                if scalar.value >= 0x40 && scalar.value <= 0x7E {
                    isInEscapeSequence = false
                }
                continue
            }

            if scalar.value == 0x1B {
                isInEscapeSequence = true
                continue
            }

            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }

        return count
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
        guard !isSuspended, !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
        if shouldReconnect(after: error) {
            markConnectionDropped(error)
        } else if case .connecting = status {
            status = .failed(error.localizedDescription)
        }
    }

    private func shouldReconnect(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let tmuxError = error as? TmuxProtocolError {
            switch tmuxError {
            case .disconnected, .commandTimedOut:
                return true
            case .commandFailed, .malformedControlLine, .startupTimedOut:
                return false
            }
        }

        return true
    }

    private func markConnectionDropped(_ error: Error) {
        _ = invalidateConnection()
        errorMessage = error.localizedDescription
    }
}
