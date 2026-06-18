import SwiftUI
import UIKit

struct WindowDetailView: View {
    private enum PaneScrollAction: Equatable {
        case pageUp
        case pageDown
        case bottom
        case bottomLeading
    }

    private enum TerminalPageDirection {
        case up
        case down

        static func forFingerSwipe(translationY: CGFloat) -> TerminalPageDirection {
            translationY < 0 ? .up : .down
        }

        var macro: TmuxMacro {
            switch self {
            case .up:
                TmuxMacro(label: "PgUp", systemImage: "chevron.up.2", key: "PageUp", preservesViewport: true)
            case .down:
                TmuxMacro(label: "PgDn", systemImage: "chevron.down.2", key: "PageDown", preservesViewport: true)
            }
        }
    }

    private enum TerminalInteractionMode: String {
        case codex
        case claude

        var label: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .codex:
                "Up and down use Hermit tmux scrollback."
            case .claude:
                "Up, down, and swipe scrolling send Page Up and Page Down to the terminal."
            }
        }

        var toggled: TerminalInteractionMode {
            self == .claude ? .codex : .claude
        }
    }

    private enum WindowSwitcherScope: String, CaseIterable, Identifiable {
        case currentSession
        case allSessions

        var id: String { rawValue }
    }

    private struct PaneScrollRequest: Equatable {
        var action: PaneScrollAction
        var token: Int
    }

    private struct KillRequest: Identifiable {
        var window: TmuxWindow
        var id: String { "window-\(window.id)" }
        var title: String { "Kill Window?" }
        var destructiveLabel: String { "Kill Window" }
        var message: String { "Window #\(window.index) \(window.name)." }
    }

    private static let minimumTerminalFontSize: CGFloat = 8
    private static let maximumTerminalFontSize: CGFloat = 30
    private static let defaultTerminalFontSize: CGFloat = 14
    private static let terminalHorizontalChrome: CGFloat = 18
    private static let terminalCharacterWidthRatio: CGFloat = 0.66

    var model: TmuxWorkspaceModel
    var session: TmuxSession
    var window: TmuxWindow
    var initialPaneId: String?
    var initialPaneIndex: Int?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(VoiceInputCoordinator.self) private var voiceCoordinator
    @Environment(DataStore.self) private var dataStore
    @Environment(AppNavigator.self) private var navigator
    @State private var selectedPaneId: String?
    @State private var selectedWindowId: String?
    @State private var selectedSessionId: String?
    @State private var commandText = ""
    @State private var streamedInputText = ""
    @State private var suppressInputChange = false
    @State private var commandIdleSubmitTask: Task<Void, Never>?
    @State private var showingVoiceModal = false
    @State private var showingWindowSwitcher = false
    @State private var windowSwitcherScope: WindowSwitcherScope = .currentSession
    @State private var voiceText = ""
    @State private var follow = true
    @State private var fontSize: CGFloat = 14
    @State private var zoomBase: CGFloat = 14
    @State private var killRequest: KillRequest?
    @State private var scrollRequest = PaneScrollRequest(action: .bottom, token: 0)
    @State private var terminalViewportWidth: CGFloat = 0
    @State private var activationRefreshTask: Task<Void, Never>?
    @AppStorage("hermit.windowTerminalInteractionModes.v1") private var terminalInteractionModesJSON = "{}"

    private var allKnownWindows: [TmuxWindow] {
        let loadedWindows = model.sessions.flatMap { model.windows(for: $0) }
        return loadedWindows.isEmpty ? model.windows(for: session) : loadedWindows
    }

    private var panes: [TmuxPane] {
        model.panes(for: currentWindow)
    }

    private var currentWindow: TmuxWindow {
        let targetWindowId = selectedWindowId ?? window.id
        let targetSessionId = selectedSessionId ?? window.sessionId
        return allKnownWindows.first { $0.id == targetWindowId && $0.sessionId == targetSessionId }
            ?? allKnownWindows.first { $0.id == targetWindowId }
            ?? allKnownWindows.first { $0.id == window.id && $0.sessionId == window.sessionId }
            ?? allKnownWindows.first { $0.id == window.id }
            ?? window
    }

    private var currentSession: TmuxSession {
        if let selectedSessionId,
           let selectedSession = model.sessions.first(where: { $0.id == selectedSessionId }) {
            return selectedSession
        }
        return model.sessions.first { $0.id == currentWindow.sessionId } ?? session
    }

    private var selectedPane: TmuxPane? {
        if let selectedPaneId {
            return panes.first { $0.id == selectedPaneId }
        }
        return panes.first(where: \.isActive) ?? panes.first
    }

    private var liveRefreshID: String {
        follow ? "live-\(selectedPane?.id ?? "none")" : "paused"
    }

    private var shortcutSwitcherFavoriteLimit: Int {
        UIDevice.current.userInterfaceIdiom == .phone ? 3 : 6
    }

    private var terminalInteractionModeKey: String {
        [
            model.host.id.uuidString,
            currentSession.name,
            currentWindow.name,
        ].joined(separator: "|")
    }

    private var currentTerminalInteractionMode: TerminalInteractionMode {
        if let override = terminalInteractionModeOverrides()[terminalInteractionModeKey] {
            return override
        }
        if selectedPane?.prefersTerminalPager(windowName: currentWindow.name) == true {
            return .claude
        }
        return .codex
    }

    var body: some View {
        ZStack(alignment: .leading) {
            terminalWorkspace

            if showingWindowSwitcher {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingWindowSwitcher = false
                    }
                    .transition(.opacity)

                windowSwitcher
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingWindowSwitcher)
        .navigationTitle(currentWindow.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingWindowSwitcher.toggle()
                    if showingWindowSwitcher {
                        refreshWindowSwitcher()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("tmux Windows")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    toggleFavorite(window: currentWindow, session: currentSession)
                } label: {
                    Image(systemName: dataStore.isFavorite(windowShortcut(currentWindow, session: currentSession)) ? "star.fill" : "star")
                }
                .accessibilityLabel("Favorite Window")

                Button {
                    fitTerminalToScreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Fit to Screen")

                terminalFontMenu
            }
        }
        .task(id: "\(currentSession.id)|\(currentWindow.id)") {
            selectedSessionId = currentSession.id
            selectedWindowId = currentWindow.id
            await model.loadWindow(currentWindow)
            let loadedPanes = model.panes(for: currentWindow)
            let preferredPane = preferredInitialPane(in: loadedPanes) ?? model.activePane(for: currentWindow)
            selectedPaneId = preferredPane?.id
            recordVisit(window: currentWindow, session: currentSession)
            if let preferredPane {
                recordVisit(pane: preferredPane, in: currentWindow, session: currentSession)
            }
            if let selectedPaneId {
                model.setFollow(selectedPaneId, enabled: follow)
            }
        }
        .task(id: liveRefreshID) {
            guard follow, let pane = selectedPane else { return }
            await model.captureLive(pane)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onDisappear {
            activationRefreshTask?.cancel()
            commandIdleSubmitTask?.cancel()
        }
        .sheet(isPresented: $showingVoiceModal) {
            VoiceInputModal(text: $voiceText) { finalText in
                if let pane = selectedPane {
                    sendCommandText(finalText, to: pane)
                }
            }
        }
        .onChange(of: voiceCoordinator.isShowingVoiceModal) { _, show in
            if show {
                voiceText = voiceCoordinator.transcribedText
                showingVoiceModal = true
                voiceCoordinator.isShowingVoiceModal = false
            }
        }
        .confirmationDialog(
            killRequest?.title ?? "Kill tmux Item?",
            isPresented: Binding(
                get: { killRequest != nil },
                set: { if !$0 { killRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: killRequest
        ) { request in
            Button(request.destructiveLabel, role: .destructive) {
                killWindow(request.window)
                killRequest = nil
            }
            Button("Cancel", role: .cancel) {
                killRequest = nil
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var terminalWorkspace: some View {
        VStack(spacing: 0) {
            paneToolbar
            Divider()

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            setTerminalFontSize(zoomBase * value)
                        }
                        .onEnded { _ in
                            zoomBase = fontSize
                        }
                )

            Divider()

            macroRibbon
            inputBar
        }
    }

    private var terminalFontMenu: some View {
        Menu {
            Text("\(Int(fontSize.rounded())) pt")

            Button {
                fitTerminalToScreen()
            } label: {
                Label("Fit to Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Divider()

            Button {
                adjustTerminalFont(by: 1)
            } label: {
                Label("Larger", systemImage: "plus")
            }

            Button {
                adjustTerminalFont(by: -1)
            } label: {
                Label("Smaller", systemImage: "minus")
            }

            Button {
                setTerminalFontSize(Self.defaultTerminalFontSize)
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("Text Size")
    }

    private var paneToolbar: some View {
        HStack(spacing: 8) {
            let interactionMode = currentTerminalInteractionMode
            let usesTerminalPager = interactionMode == .claude

            Text(currentSession.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(panes) { pane in
                        paneButton(pane)
                    }
                }
                .padding(.vertical, 1)
            }

            if selectedPane != nil {
                Button {
                    setTerminalInteractionMode(interactionMode.toggled)
                } label: {
                    Text(interactionMode.label)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: 54, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .tint(usesTerminalPager ? Color.blue : Color.secondary)
                .accessibilityLabel("\(interactionMode.label) Mode")
                .accessibilityHint(interactionMode.accessibilityHint)

                Button {
                    pageSelectedPane(.up)
                } label: {
                    Image(systemName: "chevron.up.2")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .accessibilityLabel(usesTerminalPager ? "Page Up" : "Pane Up")

                Button {
                    pageSelectedPane(.down)
                } label: {
                    Image(systemName: "chevron.down.2")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .accessibilityLabel(usesTerminalPager ? "Page Down" : "Pane Down")

                Button {
                    goToLiveOutput()
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .accessibilityLabel(usesTerminalPager ? "Send Control End" : "Go to Live Output")
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 8)
        .background(.regularMaterial)
    }

    private func paneButton(_ pane: TmuxPane) -> some View {
        let isSelected = pane.id == selectedPane?.id

        return Button {
            selectedPaneId = pane.id
            model.setFollow(pane.id, enabled: follow)
            recordVisit(pane: pane, in: currentWindow, session: currentSession)
            Task { await model.select(pane, in: currentWindow) }
        } label: {
            HStack(spacing: 4) {
                Text("#\(pane.index)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                Text(pane.currentCommand)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pane \(pane.index)")
    }

    @ViewBuilder
    private var paneContent: some View {
        if let pane = selectedPane,
           let snapshot = model.snapshotsByPane[pane.id] {
            paneOutputView(pane: pane, snapshot: snapshot)
        } else if selectedPane != nil {
            refreshableUnavailableView(
                title: model.errorMessage ?? "Loading Pane",
                systemImage: model.errorMessage == nil ? "terminal" : "exclamationmark.triangle",
                description: model.errorMessage == nil ? "Fetching pane output." : "Pull to refresh or reopen the window."
            )
        } else {
            refreshableUnavailableView(
                title: "No Pane Selected",
                systemImage: "rectangle.dashed",
                description: "Pull to refresh the window."
            )
        }
    }

    private func refreshableUnavailableView(title: String, systemImage: String, description: String) -> some View {
        ScrollView {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(description)
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 320)
        }
        .refreshable {
            await refreshSelectedPane(forceReconnect: true)
        }
    }

    private func paneOutputView(pane: TmuxPane, snapshot: TmuxPaneSnapshot) -> some View {
        GeometryReader { geometry in
            let displayFontSize = fontSize
            let targetColumns = terminalColumns(availableWidth: geometry.size.width, fontSize: displayFontSize)
            let targetRows = terminalRows(availableHeight: geometry.size.height, fontSize: displayFontSize)
            let lineColumns = max(targetColumns, max(pane.width, longestLineLength(in: snapshot)))
            let contentWidth = terminalContentWidth(columns: lineColumns, availableWidth: geometry.size.width, fontSize: displayFontSize)

            TerminalTextOutputView(
                snapshot: snapshot,
                fontSize: displayFontSize,
                contentWidth: contentWidth,
                follow: follow,
                scrollRequest: scrollRequest,
                usesTerminalPagerScroll: currentTerminalInteractionMode == .claude,
                onManualScrollAwayFromBottom: {
                    pauseFollowForManualPaneScroll(pane)
                },
                onManualScrollToBottom: {
                    resumeFollowForManualPaneScroll(pane)
                },
                onTerminalPagerScroll: { direction in
                    Task { @MainActor in
                        await pagePane(direction, pane: pane)
                    }
                },
                onRefresh: { finish in
                    Task { @MainActor in
                        await pagePane(.up, pane: pane)
                        finish()
                    }
                }
            )
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
            .onAppear {
                terminalViewportWidth = geometry.size.width
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                terminalViewportWidth = newWidth
            }
            .task(id: "\(pane.id)-\(targetColumns)x\(targetRows)") {
                await model.resizeForDisplay(pane, cols: targetColumns, rows: targetRows, in: currentWindow)
            }
        }
    }

    private var windowSwitcher: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Windows")
                    .font(.headline)
                Spacer()
                Button {
                    showingWindowSwitcher = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close Windows")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Picker("Window Scope", selection: $windowSwitcherScope) {
                Text("This").tag(WindowSwitcherScope.currentSession)
                Text("All").tag(WindowSwitcherScope.allSessions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .onChange(of: windowSwitcherScope) { _, _ in
                refreshWindowSwitcher()
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    shortcutSwitcherSections
                    windowSwitcherList
                }
                .padding(8)
            }
        }
        .frame(width: 286)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var windowSwitcherList: some View {
        if windowSwitcherScope == .allSessions {
            ForEach(model.sessions) { tmuxSession in
                if !model.windows(for: tmuxSession).isEmpty {
                    sessionHeader(tmuxSession)
                    ForEach(model.windows(for: tmuxSession)) { tmuxWindow in
                        windowSwitcherSection(for: tmuxWindow, in: tmuxSession)
                    }
                }
            }
        } else {
            ForEach(model.windows(for: currentSession)) { tmuxWindow in
                windowSwitcherSection(for: tmuxWindow, in: currentSession)
            }
        }
    }

    @ViewBuilder
    private var shortcutSwitcherSections: some View {
        let favorites = dataStore.favoriteTmuxShortcuts(limit: shortcutSwitcherFavoriteLimit, kind: .window)
        if !favorites.isEmpty {
            shortcutHeader("Favorites")
            ForEach(favorites) { shortcut in
                shortcutSwitcherRow(shortcut)
            }
            Divider()
                .padding(.vertical, 4)
        }

        let frequent = dataStore.frequentTmuxShortcuts(limit: 6, kind: .window)
        if !frequent.isEmpty {
            shortcutHeader("Frequent")
            ForEach(frequent) { shortcut in
                shortcutSwitcherRow(shortcut)
            }
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func shortcutHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }

    @ViewBuilder
    private func shortcutSwitcherRow(_ shortcut: TmuxShortcut) -> some View {
        if dataStore.host(for: shortcut) != nil {
            Button {
                showingWindowSwitcher = false
                navigator.open(shortcut)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: shortcut.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(shortcut.windowName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("\(shortcut.hostDisplayName) - \(shortcut.sessionName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if shortcut.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sessionHeader(_ tmuxSession: TmuxSession) -> some View {
        Text(tmuxSession.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }

    private func windowSwitcherSection(for tmuxWindow: TmuxWindow, in tmuxSession: TmuxSession) -> some View {
        let isCurrentWindow = tmuxWindow.id == currentWindow.id

        return HStack(alignment: .center, spacing: 8) {
            Button {
                switchToWindow(tmuxWindow, in: tmuxSession)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text(tmuxWindow.name)
                        .font(.body.weight(isCurrentWindow ? .semibold : .regular))
                        .foregroundStyle(isCurrentWindow ? .primary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isCurrentWindow {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleFavorite(window: tmuxWindow, session: tmuxSession)
            } label: {
                Image(systemName: dataStore.isFavorite(windowShortcut(tmuxWindow, session: tmuxSession)) ? "star.fill" : "star")
                    .foregroundStyle(dataStore.isFavorite(windowShortcut(tmuxWindow, session: tmuxSession)) ? .yellow : .secondary)
                    .frame(width: 30, height: 30, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dataStore.isFavorite(windowShortcut(tmuxWindow, session: tmuxSession)) ? "Unfavorite \(tmuxWindow.name)" : "Favorite \(tmuxWindow.name)")

            Button(role: .destructive) {
                killRequest = KillRequest(window: tmuxWindow)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kill Window \(tmuxWindow.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isCurrentWindow ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if isCurrentWindow {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
    }

    private var macroRibbon: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(TmuxMacro.defaults) { macro in
                    Button {
                        sendMacro(macro)
                    } label: {
                        if let systemImage = macro.systemImage {
                            Image(systemName: systemImage)
                                .frame(width: 50, height: 38, alignment: .center)
                        } else {
                            Text(macro.label)
                                .font(.system(.caption, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .frame(width: 50, height: 38, alignment: .center)
                        }
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle)
                    .accessibilityLabel(macro.label)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .background(.regularMaterial)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Command", text: $commandText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .submitLabel(.return)
                .onChange(of: commandText) { _, newValue in
                    handleCommandTextChange(to: newValue)
                }
                .onSubmit(sendEnter)

            Button {
                clearCommandBox()
            } label: {
                Image(systemName: "delete.left.fill")
                    .frame(width: 34, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(commandText.isEmpty && streamedInputText.isEmpty)
            .accessibilityLabel("Clear Command")

            Button {
                let settings = AppSettings.load()
                voiceCoordinator.handleVoiceButton(settings: settings)
            } label: {
                Image(systemName: "mic.fill")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Voice Input")
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.regularMaterial)
    }

    private func handleCommandTextChange(to newValue: String) {
        guard !suppressInputChange else { return }

        let submitPhraseResult = VoiceCommandAutoSubmit.commandByRemovingSubmitPhrase(from: newValue)
        if submitPhraseResult.shouldSubmit {
            commandIdleSubmitTask?.cancel()
            submitCommandBoxText(submitPhraseResult.command, allowEmpty: false)
            return
        }

        let delta = streamInputChange(to: newValue)
        if shouldScheduleCommandIdleSubmit(delta: delta, command: newValue) {
            scheduleCommandIdleSubmit(for: newValue)
        } else if newValue.isEmpty {
            commandIdleSubmitTask?.cancel()
        }
    }

    @discardableResult
    private func streamInputChange(to newValue: String) -> (backspaceCount: Int, insertedText: String) {
        guard !suppressInputChange else { return (0, "") }
        guard let pane = selectedPane else {
            let delta = inputDelta(from: streamedInputText, to: newValue)
            streamedInputText = newValue
            return delta
        }

        let delta = inputDelta(from: streamedInputText, to: newValue)
        guard delta.backspaceCount > 0 || !delta.insertedText.isEmpty else {
            streamedInputText = newValue
            return delta
        }

        resumeFollowForInput(pane)
        Task {
            await model.sendInputDelta(
                backspaceCount: delta.backspaceCount,
                insertedText: delta.insertedText,
                enter: false,
                to: pane
            )
        }
        streamedInputText = newValue
        return delta
    }

    private func sendEnter() {
        submitCommandBoxText(commandText, allowEmpty: true)
    }

    private func submitCommandBoxText(_ text: String, allowEmpty: Bool) {
        let command = text
        guard allowEmpty || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let pane = selectedPane else { return }

        commandIdleSubmitTask?.cancel()
        let delta = inputDelta(from: streamedInputText, to: command)
        suppressInputChange = true
        commandText = ""
        streamedInputText = ""
        DispatchQueue.main.async {
            suppressInputChange = false
        }

        resumeFollowForInput(pane)
        Task {
            await model.sendInputDelta(
                backspaceCount: delta.backspaceCount,
                insertedText: delta.insertedText,
                enter: true,
                to: pane
            )
        }
    }

    private func clearCommandBox() {
        commandIdleSubmitTask?.cancel()
        let pendingText = streamedInputText

        suppressInputChange = true
        commandText = ""
        streamedInputText = ""
        DispatchQueue.main.async {
            suppressInputChange = false
        }

        guard !pendingText.isEmpty, let pane = selectedPane else { return }
        resumeFollowForInput(pane)
        Task {
            await model.sendInputDelta(
                backspaceCount: pendingText.count,
                insertedText: "",
                enter: false,
                to: pane
            )
        }
    }

    private func sendCommandText(_ command: String, to pane: TmuxPane) {
        let cleanedCommand = VoiceCommandAutoSubmit.commandByRemovingSubmitPhrase(from: command).command
        guard !cleanedCommand.isEmpty else { return }

        commandIdleSubmitTask?.cancel()
        resumeFollowForInput(pane)
        Task {
            await model.sendInputDelta(
                backspaceCount: 0,
                insertedText: cleanedCommand,
                enter: true,
                to: pane
            )
        }
    }

    private func shouldScheduleCommandIdleSubmit(
        delta: (backspaceCount: Int, insertedText: String),
        command: String
    ) -> Bool {
        VoiceCommandAutoSubmit.shouldScheduleIdleSubmit(
            backspaceCount: delta.backspaceCount,
            insertedText: delta.insertedText,
            command: command,
            alreadyArmed: commandIdleSubmitTask != nil
        )
    }

    private func scheduleCommandIdleSubmit(for command: String) {
        commandIdleSubmitTask?.cancel()
        commandIdleSubmitTask = Task {
            try? await Task.sleep(nanoseconds: VoiceCommandAutoSubmit.idleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard commandText == command else { return }
                submitCommandBoxText(command, allowEmpty: false)
            }
        }
    }

    private func resumeFollowForInput(_ pane: TmuxPane) {
        if follow {
            model.setFollow(pane.id, enabled: true)
            return
        }

        follow = true
        model.setFollow(pane.id, enabled: true)
        requestPaneScroll(.bottom)
    }

    private func inputDelta(from oldValue: String, to newValue: String) -> (backspaceCount: Int, insertedText: String) {
        let oldCharacters = Array(oldValue)
        let newCharacters = Array(newValue)
        var sharedPrefixCount = 0

        while sharedPrefixCount < oldCharacters.count,
              sharedPrefixCount < newCharacters.count,
              oldCharacters[sharedPrefixCount] == newCharacters[sharedPrefixCount] {
            sharedPrefixCount += 1
        }

        var sharedSuffixCount = 0
        while sharedSuffixCount + sharedPrefixCount < oldCharacters.count,
              sharedSuffixCount + sharedPrefixCount < newCharacters.count,
              oldCharacters[oldCharacters.count - 1 - sharedSuffixCount] == newCharacters[newCharacters.count - 1 - sharedSuffixCount] {
            sharedSuffixCount += 1
        }

        let removedCount = oldCharacters.count - sharedPrefixCount - sharedSuffixCount
        let insertedEnd = newCharacters.count - sharedSuffixCount
        let insertedText: String
        if sharedPrefixCount < insertedEnd {
            insertedText = String(newCharacters[sharedPrefixCount..<insertedEnd])
        } else {
            insertedText = ""
        }

        return (removedCount, insertedText)
    }

    private func sendMacro(_ macro: TmuxMacro) {
        guard let pane = selectedPane else { return }
        if macro.preservesViewport {
            follow = false
            model.setFollow(pane.id, enabled: false)
        } else {
            requestPaneScroll(.bottom)
        }
        Task { await model.send(macro, to: pane) }
    }

    private func terminalInteractionModeOverrides() -> [String: TerminalInteractionMode] {
        guard let data = terminalInteractionModesJSON.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return rawValues.compactMapValues(TerminalInteractionMode.init(rawValue:))
    }

    private func setTerminalInteractionMode(_ mode: TerminalInteractionMode) {
        var overrides = terminalInteractionModeOverrides()
        overrides[terminalInteractionModeKey] = mode
        let rawValues = overrides.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(rawValues),
           let json = String(data: data, encoding: .utf8) {
            terminalInteractionModesJSON = json
        }
    }

    private func switchToWindow(_ tmuxWindow: TmuxWindow, in tmuxSession: TmuxSession? = nil) {
        let targetSession = tmuxSession ?? session(for: tmuxWindow)
        selectedSessionId = targetSession.id
        selectedWindowId = tmuxWindow.id
        selectedPaneId = nil
        follow = true
        showingWindowSwitcher = false
        recordVisit(window: tmuxWindow, session: targetSession)

        Task { @MainActor in
            await model.selectWindow(tmuxWindow, in: targetSession)
            await model.refreshWindows(for: targetSession)
            let loadedWindow = model.windows(for: targetSession).first { $0.id == tmuxWindow.id } ?? tmuxWindow
            selectedPaneId = model.activePane(for: loadedWindow)?.id
            if let selectedPaneId {
                model.setFollow(selectedPaneId, enabled: true)
                if let pane = model.panes(for: loadedWindow).first(where: { $0.id == selectedPaneId }) {
                    recordVisit(pane: pane, in: loadedWindow, session: targetSession)
                }
            }
            scrollRequest = PaneScrollRequest(action: .bottom, token: scrollRequest.token + 1)
        }
    }

    private func switchToPane(_ pane: TmuxPane, in tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession? = nil) {
        let targetSession = tmuxSession ?? session(for: tmuxWindow)
        selectedSessionId = targetSession.id
        selectedWindowId = tmuxWindow.id
        selectedPaneId = pane.id
        follow = true
        showingWindowSwitcher = false
        recordVisit(window: tmuxWindow, session: targetSession)
        recordVisit(pane: pane, in: tmuxWindow, session: targetSession)

        Task { @MainActor in
            await model.selectWindow(tmuxWindow, in: targetSession)
            await model.refreshWindows(for: targetSession)
            let loadedWindow = model.windows(for: targetSession).first { $0.id == tmuxWindow.id } ?? tmuxWindow
            await model.select(pane, in: loadedWindow)
            selectedPaneId = pane.id
            model.setFollow(pane.id, enabled: true)
            scrollRequest = PaneScrollRequest(action: .bottom, token: scrollRequest.token + 1)
        }
    }

    private func killWindow(_ tmuxWindow: TmuxWindow) {
        let targetSession = session(for: tmuxWindow)
        Task { @MainActor in
            await model.killWindow(tmuxWindow, in: targetSession)
            await model.refreshSessions()
            if model.sessions.contains(where: { $0.id == targetSession.id }) {
                await model.refreshWindows(for: targetSession)
            }
            if selectedWindowId == tmuxWindow.id || currentWindow.id == tmuxWindow.id {
                let replacementWindow = model.windows(for: targetSession).first ?? allKnownWindows.first
                selectedSessionId = replacementWindow?.sessionId
                selectedWindowId = replacementWindow?.id
                selectedPaneId = nil
            }
        }
    }

    private func session(for tmuxWindow: TmuxWindow) -> TmuxSession {
        model.sessions.first { $0.id == tmuxWindow.sessionId } ?? session
    }

    private func preferredInitialPane(in panes: [TmuxPane]) -> TmuxPane? {
        if let initialPaneId,
           let pane = panes.first(where: { $0.id == initialPaneId }) {
            return pane
        }

        if let initialPaneIndex,
           let pane = panes.first(where: { $0.index == initialPaneIndex }) {
            return pane
        }

        return nil
    }

    private func windowShortcut(_ tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession) -> TmuxShortcut {
        TmuxShortcut(
            kind: .window,
            host: model.host,
            session: tmuxSession,
            window: tmuxWindow
        )
    }

    private func paneShortcut(_ pane: TmuxPane, in tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession) -> TmuxShortcut {
        TmuxShortcut(
            kind: .pane,
            host: model.host,
            session: tmuxSession,
            window: tmuxWindow,
            pane: pane
        )
    }

    private func recordVisit(window tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession) {
        dataStore.recordVisit(windowShortcut(tmuxWindow, session: tmuxSession))
    }

    private func recordVisit(pane: TmuxPane, in tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession) {
        dataStore.recordVisit(paneShortcut(pane, in: tmuxWindow, session: tmuxSession))
    }

    private func toggleFavorite(window tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession) {
        dataStore.toggleFavorite(windowShortcut(tmuxWindow, session: tmuxSession))
    }

    private func toggleFavorite(pane: TmuxPane, in tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession) {
        dataStore.toggleFavorite(paneShortcut(pane, in: tmuxWindow, session: tmuxSession))
    }

    private func refreshWindowSwitcher() {
        Task { @MainActor in
            await model.refreshSessions()
            let sessionsToRefresh = windowSwitcherScope == .allSessions ? model.sessions : [currentSession]
            for tmuxSession in sessionsToRefresh {
                await model.refreshWindows(for: tmuxSession)
            }
            dataStore.reconcileTmuxShortcuts(
                for: model.host,
                sessions: model.sessions,
                windowsBySession: model.windowsBySession,
                panesByWindow: model.panesByWindow
            )
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            activationRefreshTask?.cancel()
            activationRefreshTask = Task { @MainActor in
                await restoreTerminalAfterActivation(forceFollow: true)
            }
        case .background:
            activationRefreshTask?.cancel()
            commandIdleSubmitTask?.cancel()
            streamedInputText = commandText
            Task { @MainActor in
                await model.disconnect()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    @MainActor
    private func restoreTerminalAfterActivation(forceFollow: Bool) async {
        let previousSession = currentSession
        let previousWindow = currentWindow
        let previousPaneId = selectedPaneId

        await model.reconnect()

        let restoredSession = model.sessions.first { $0.id == previousSession.id }
            ?? model.sessions.first { $0.name == previousSession.name }
            ?? previousSession

        await model.refreshWindows(for: restoredSession)

        let restoredWindow = model.windows(for: restoredSession).first { $0.id == previousWindow.id }
            ?? model.windows(for: restoredSession).first {
                $0.name == previousWindow.name && $0.index == previousWindow.index
            }
            ?? model.windows(for: restoredSession).first { $0.name == previousWindow.name }
            ?? previousWindow

        selectedSessionId = restoredSession.id
        selectedWindowId = restoredWindow.id
        await model.loadWindow(restoredWindow)

        let restoredPanes = model.panes(for: restoredWindow)
        let restoredPane = previousPaneId.flatMap { paneId in
            restoredPanes.first { $0.id == paneId }
        } ?? model.activePane(for: restoredWindow) ?? restoredPanes.first

        selectedPaneId = restoredPane?.id
        streamedInputText = commandText

        guard let restoredPane else { return }
        if forceFollow {
            follow = true
        }
        model.setFollow(restoredPane.id, enabled: follow)
        if follow {
            await model.captureLive(restoredPane)
            requestPaneScroll(.bottomLeading)
        } else {
            await model.captureScrollback(restoredPane)
        }
    }

    private func refreshSelectedPane(forceReconnect: Bool = false) async {
        if forceReconnect {
            await restoreTerminalAfterActivation(forceFollow: true)
            return
        }

        let previousPaneId = selectedPane?.id
        await model.refreshWindow(currentWindow)

        let refreshedPanes = model.panes(for: currentWindow)
        let refreshedPane = previousPaneId.flatMap { paneId in
            refreshedPanes.first { $0.id == paneId }
        } ?? model.activePane(for: currentWindow) ?? refreshedPanes.first

        guard let refreshedPane else {
            selectedPaneId = nil
            return
        }

        selectedPaneId = refreshedPane.id
        model.setFollow(refreshedPane.id, enabled: follow)
        if follow {
            await model.captureLive(refreshedPane)
            requestPaneScroll(.bottom)
        } else {
            await model.captureScrollback(refreshedPane)
        }
    }

    private func requestPaneScroll(_ action: PaneScrollAction) {
        follow = action == .bottom || action == .bottomLeading
        if let pane = selectedPane {
            model.setFollow(pane.id, enabled: follow)
        }

        scrollRequest = PaneScrollRequest(action: action, token: scrollRequest.token + 1)
    }

    private func goToLiveOutput() {
        guard let pane = selectedPane else {
            requestPaneScroll(.bottom)
            return
        }

        guard currentTerminalInteractionMode == .claude else {
            requestPaneScroll(.bottom)
            return
        }

        follow = true
        model.setFollow(pane.id, enabled: true)
        Task { @MainActor in
            let controlEnd = TmuxMacro(label: "Ctrl-End", systemImage: nil, key: "C-End")
            await model.send(controlEnd, to: pane)
            await model.captureLive(pane)
            requestPaneScroll(.bottom)
        }
    }

    private func pageSelectedPane(_ direction: TerminalPageDirection) {
        guard let pane = selectedPane else { return }
        Task { @MainActor in
            await pagePane(direction, pane: pane)
        }
    }

    private func pagePane(_ direction: TerminalPageDirection, pane: TmuxPane) async {
        if currentTerminalInteractionMode == .claude {
            await sendTerminalPage(direction, to: pane)
        } else {
            await pageCapturedPane(direction, pane: pane)
        }
    }

    private func pageCapturedPane(_ direction: TerminalPageDirection, pane: TmuxPane) async {
        follow = false
        model.setFollow(pane.id, enabled: false)
        if direction == .up {
            await model.captureScrollback(pane)
        }
        scrollRequest = PaneScrollRequest(
            action: direction == .up ? .pageUp : .pageDown,
            token: scrollRequest.token + 1
        )
    }

    private func sendTerminalPage(_ direction: TerminalPageDirection) {
        guard let pane = selectedPane else { return }
        Task { @MainActor in
            await sendTerminalPage(direction, to: pane)
        }
    }

    private func sendTerminalPage(_ direction: TerminalPageDirection, to pane: TmuxPane) async {
        follow = false
        model.setFollow(pane.id, enabled: false)
        await model.send(direction.macro, to: pane)
    }

    private func pauseFollowForManualPaneScroll(_ pane: TmuxPane) {
        if follow {
            follow = false
            model.setFollow(pane.id, enabled: false)
        }
    }

    private func resumeFollowForManualPaneScroll(_ pane: TmuxPane) {
        guard !follow else { return }
        follow = true
        model.setFollow(pane.id, enabled: true)
    }

    private func adjustTerminalFont(by delta: CGFloat) {
        setTerminalFontSize(fontSize + delta)
    }

    private func fitTerminalToScreen() {
        let viewportWidth = terminalViewportWidth > 0 ? terminalViewportWidth : 390
        let usableWidth = max(80, viewportWidth - Self.terminalHorizontalChrome)
        let columnCount = max(1, selectedPaneColumnCountForFit())
        let fittedSize = usableWidth / (CGFloat(columnCount) * Self.terminalCharacterWidthRatio)
        setTerminalFontSize(fittedSize)
        requestPaneScroll(.bottomLeading)
    }

    private func setTerminalFontSize(_ size: CGFloat) {
        let adjustedSize = min(Self.maximumTerminalFontSize, max(Self.minimumTerminalFontSize, size))
        guard abs(fontSize - adjustedSize) > 0.01 else { return }

        fontSize = adjustedSize
        zoomBase = adjustedSize
        if follow {
            requestPaneScroll(.bottom)
        }
    }

    private func terminalColumns(availableWidth: CGFloat, fontSize: CGFloat) -> Int {
        let usableWidth = max(80, availableWidth - Self.terminalHorizontalChrome)
        let characterWidth = terminalCharacterWidth(fontSize: fontSize)
        return max(24, min(120, Int(usableWidth / characterWidth)))
    }

    private func terminalRows(availableHeight: CGFloat, fontSize: CGFloat) -> Int {
        let usableHeight = max(120, availableHeight - 24)
        let lineHeight = max(10, fontSize * 1.25)
        return max(10, min(80, Int(usableHeight / lineHeight)))
    }

    private func terminalContentWidth(columns: Int, availableWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        let visibleWidth = max(80, availableWidth - Self.terminalHorizontalChrome)
        let renderedWidth = CGFloat(max(1, columns)) * terminalCharacterWidth(fontSize: fontSize)
        return max(visibleWidth, renderedWidth)
    }

    private func terminalContentMinHeight(availableHeight: CGFloat) -> CGFloat {
        max(0, availableHeight - 6)
    }

    private func terminalCharacterWidth(fontSize: CGFloat) -> CGFloat {
        max(4, fontSize * Self.terminalCharacterWidthRatio)
    }

    private func selectedPaneColumnCountForFit() -> Int {
        guard let pane = selectedPane else { return 80 }
        return max(24, pane.width)
    }

    private func longestLineLength(in snapshot: TmuxPaneSnapshot) -> Int {
        snapshot.lines.map { $0.text.characters.count }.max() ?? 0
    }

    private struct TerminalTextOutputView: UIViewRepresentable {
        var snapshot: TmuxPaneSnapshot
        var fontSize: CGFloat
        var contentWidth: CGFloat
        var follow: Bool
        var scrollRequest: PaneScrollRequest
        var usesTerminalPagerScroll: Bool
        var onManualScrollAwayFromBottom: () -> Void
        var onManualScrollToBottom: () -> Void
        var onTerminalPagerScroll: (TerminalPageDirection) -> Void
        var onRefresh: (@escaping () -> Void) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                usesTerminalPagerScroll: usesTerminalPagerScroll,
                onManualScrollAwayFromBottom: onManualScrollAwayFromBottom,
                onManualScrollToBottom: onManualScrollToBottom,
                onTerminalPagerScroll: onTerminalPagerScroll,
                onRefresh: onRefresh
            )
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.isEditable = false
            textView.isSelectable = true
            textView.isScrollEnabled = true
            textView.dataDetectorTypes = [.link]
            textView.backgroundColor = .systemBackground
            textView.isOpaque = true
            textView.textColor = .label
            textView.tintColor = .systemBlue
            textView.layer.drawsAsynchronously = true
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 6, bottom: 2, right: 8)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.lineBreakMode = .byClipping
            textView.textContainer.widthTracksTextView = false
            textView.alwaysBounceHorizontal = true
            textView.alwaysBounceVertical = true
            textView.showsHorizontalScrollIndicator = true
            textView.showsVerticalScrollIndicator = true
            textView.keyboardDismissMode = .interactive
            textView.adjustsFontForContentSizeCategory = false
            textView.linkTextAttributes = [
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                context.coordinator,
                action: #selector(Coordinator.refreshPulled(_:)),
                for: .valueChanged
            )
            textView.refreshControl = refreshControl

            let pagerPan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.terminalPagerPan(_:))
            )
            pagerPan.delegate = context.coordinator
            pagerPan.cancelsTouchesInView = false
            pagerPan.delaysTouchesBegan = false
            textView.addGestureRecognizer(pagerPan)
            textView.panGestureRecognizer.require(toFail: pagerPan)
            context.coordinator.terminalPagerPanGesture = pagerPan

            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            context.coordinator.usesTerminalPagerScroll = usesTerminalPagerScroll
            context.coordinator.onManualScrollAwayFromBottom = onManualScrollAwayFromBottom
            context.coordinator.onManualScrollToBottom = onManualScrollToBottom
            context.coordinator.onTerminalPagerScroll = onTerminalPagerScroll
            context.coordinator.onRefresh = onRefresh
            textView.refreshControl?.isEnabled = !usesTerminalPagerScroll
            context.coordinator.isProgrammaticScroll = true
            defer { context.coordinator.isProgrammaticScroll = false }

            let clampedContentWidth = max(contentWidth, textView.bounds.width - textView.adjustedContentInset.horizontal)
            if abs(context.coordinator.contentWidth - clampedContentWidth) > 0.5 {
                textView.textContainer.size = CGSize(width: clampedContentWidth, height: .greatestFiniteMagnitude)
                context.coordinator.contentWidth = clampedContentWidth
            }

            let wasAtBottom = context.coordinator.isAtBottom(textView)
            let currentOffset = textView.contentOffset
            let previousContentHeight = textView.contentSize.height
            let previousDisplayText = context.coordinator.displayText
            let displayText = Self.displayText(from: snapshot)
            let contentChanged = context.coordinator.rawText != snapshot.rawText
                || abs(context.coordinator.fontSize - fontSize) > 0.01
            let scrollbackWasPrepended = !previousDisplayText.isEmpty
                && displayText != previousDisplayText
                && displayText.hasSuffix(previousDisplayText)

            if contentChanged {
                context.coordinator.apply(
                    Self.attributedText(from: snapshot, displayText: displayText, fontSize: fontSize),
                    to: textView
                )
                textView.isSelectable = true
                context.coordinator.rawText = snapshot.rawText
                context.coordinator.displayText = displayText
                context.coordinator.fontSize = fontSize
                textView.layoutIfNeeded()
                context.coordinator.updateScrollableWidth(clampedContentWidth, in: textView)

                if follow {
                    context.coordinator.scrollToBottom(textView)
                } else if scrollbackWasPrepended {
                    let heightDelta = max(0, textView.contentSize.height - previousContentHeight)
                    context.coordinator.restore(
                        offset: CGPoint(x: currentOffset.x, y: currentOffset.y + heightDelta),
                        in: textView
                    )
                } else if wasAtBottom {
                    context.coordinator.scrollToBottom(textView)
                } else {
                    context.coordinator.restore(offset: currentOffset, in: textView)
                }
            }

            if context.coordinator.scrollToken != scrollRequest.token {
                context.coordinator.scrollToken = scrollRequest.token
                switch scrollRequest.action {
                case .pageUp:
                    context.coordinator.pageUp(textView)
                case .pageDown:
                    context.coordinator.pageDown(textView)
                case .bottom:
                    context.coordinator.scrollToBottom(textView)
                case .bottomLeading:
                    context.coordinator.scrollToBottomLeading(textView)
                }
            } else {
                context.coordinator.updateScrollableWidth(clampedContentWidth, in: textView)
            }
        }

        private static func displayText(from snapshot: TmuxPaneSnapshot) -> String {
            var plainText = AnsiAttributedStringParser.plainText(snapshot.rawText)
            if plainText.isEmpty, !snapshot.lines.isEmpty {
                plainText = snapshot.lines
                    .map { String($0.text.characters) }
                    .joined(separator: "\n")
            }
            return plainText
        }

        private static func attributedText(
            from snapshot: TmuxPaneSnapshot,
            displayText: String,
            fontSize: CGFloat
        ) -> NSAttributedString {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping
            paragraphStyle.lineSpacing = 2
            let output = AnsiAttributedStringParser.attributedText(
                snapshot.rawText.isEmpty ? displayText : snapshot.rawText,
                fontSize: fontSize,
                paragraphStyle: paragraphStyle
            )

            let fullRange = NSRange(location: 0, length: output.length)
            if output.length == 0, !displayText.isEmpty {
                output.append(NSMutableAttributedString(
                    string: displayText,
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: paragraphStyle,
                    ]
                ))
            } else {
                output.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
            }
            TerminalLinkDetector.addDetectedLinks(to: output)
            return output
        }

        final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
            private static let terminalPagerSwipeThreshold: CGFloat = 44

            var usesTerminalPagerScroll: Bool
            var onManualScrollAwayFromBottom: () -> Void
            var onManualScrollToBottom: () -> Void
            var onTerminalPagerScroll: (TerminalPageDirection) -> Void
            var onRefresh: (@escaping () -> Void) -> Void
            weak var terminalPagerPanGesture: UIPanGestureRecognizer?
            var rawText = ""
            var displayText = ""
            var fontSize: CGFloat = 0
            var contentWidth: CGFloat = 0
            var scrollToken = -1
            var isProgrammaticScroll = false
            private var terminalPagerStartOffset: CGPoint?
            private var dragStartOffset: CGPoint?
            private var didHandleManualScrollAwayFromBottom = false
            private var didHandleManualScrollToBottom = false
            private var didHandleTerminalPagerScroll = false

            init(
                usesTerminalPagerScroll: Bool,
                onManualScrollAwayFromBottom: @escaping () -> Void,
                onManualScrollToBottom: @escaping () -> Void,
                onTerminalPagerScroll: @escaping (TerminalPageDirection) -> Void,
                onRefresh: @escaping (@escaping () -> Void) -> Void
            ) {
                self.usesTerminalPagerScroll = usesTerminalPagerScroll
                self.onManualScrollAwayFromBottom = onManualScrollAwayFromBottom
                self.onManualScrollToBottom = onManualScrollToBottom
                self.onTerminalPagerScroll = onTerminalPagerScroll
                self.onRefresh = onRefresh
            }

            @objc func refreshPulled(_ refreshControl: UIRefreshControl) {
                onRefresh {
                    DispatchQueue.main.async {
                        refreshControl.endRefreshing()
                    }
                }
            }

            @objc func terminalPagerPan(_ recognizer: UIPanGestureRecognizer) {
                guard usesTerminalPagerScroll,
                      let scrollView = recognizer.view as? UIScrollView else {
                    return
                }

                switch recognizer.state {
                case .began:
                    terminalPagerStartOffset = scrollView.contentOffset
                    didHandleTerminalPagerScroll = false
                case .changed:
                    let translation = recognizer.translation(in: scrollView)
                    let verticalDelta = abs(translation.y)
                    guard verticalDelta >= Self.terminalPagerSwipeThreshold else {
                        restoreTerminalPagerOffset(in: scrollView)
                        return
                    }

                    didHandleTerminalPagerScroll = true
                    onTerminalPagerScroll(.forFingerSwipe(translationY: translation.y))
                    recognizer.setTranslation(.zero, in: scrollView)
                    restoreTerminalPagerOffset(in: scrollView)
                case .ended, .cancelled, .failed:
                    restoreTerminalPagerOffset(in: scrollView)
                    terminalPagerStartOffset = nil
                    didHandleTerminalPagerScroll = false
                default:
                    break
                }
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard usesTerminalPagerScroll,
                      gestureRecognizer === terminalPagerPanGesture,
                      let pan = gestureRecognizer as? UIPanGestureRecognizer,
                      let view = pan.view else {
                    return false
                }

                let velocity = pan.velocity(in: view)
                return abs(velocity.y) > abs(velocity.x)
            }

            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                guard !isProgrammaticScroll else { return }
                dragStartOffset = scrollView.contentOffset
                didHandleManualScrollAwayFromBottom = false
                didHandleManualScrollToBottom = false
                didHandleTerminalPagerScroll = false
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                guard !isProgrammaticScroll,
                      let dragStartOffset else {
                    return
                }

                guard scrollView.contentOffset.y >= -scrollView.adjustedContentInset.top else {
                    return
                }

                let deltaX = abs(scrollView.contentOffset.x - dragStartOffset.x)
                let deltaY = scrollView.contentOffset.y - dragStartOffset.y
                let verticalDelta = abs(deltaY)
                guard verticalDelta > 8, verticalDelta >= deltaX else { return }

                let movedTowardHistory = deltaY < -8
                if usesTerminalPagerScroll {
                    guard verticalDelta > 28, !didHandleTerminalPagerScroll else { return }
                    didHandleTerminalPagerScroll = true
                    onTerminalPagerScroll(.forFingerSwipe(translationY: -deltaY))
                    isProgrammaticScroll = true
                    restore(offset: dragStartOffset, in: scrollView)
                    isProgrammaticScroll = false
                    return
                }

                if movedTowardHistory {
                    guard !didHandleManualScrollAwayFromBottom else { return }
                    didHandleManualScrollAwayFromBottom = true
                    onManualScrollAwayFromBottom()
                    return
                }

                if isNearBottom(scrollView, tolerance: 12) {
                    guard !didHandleManualScrollToBottom else { return }
                    didHandleManualScrollToBottom = true
                    onManualScrollToBottom()
                }
            }

            func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
                if !decelerate {
                    dragStartOffset = nil
                    didHandleManualScrollAwayFromBottom = false
                    didHandleManualScrollToBottom = false
                    didHandleTerminalPagerScroll = false
                }
            }

            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
                dragStartOffset = nil
                didHandleManualScrollAwayFromBottom = false
                didHandleManualScrollToBottom = false
                didHandleTerminalPagerScroll = false
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                guard !isProgrammaticScroll, textView.selectedRange.length > 0 else { return }
                if !isNearBottom(textView, tolerance: 32) {
                    onManualScrollAwayFromBottom()
                }
            }

            func textView(
                _ textView: UITextView,
                primaryActionFor textItem: UITextItem,
                defaultAction: UIAction
            ) -> UIAction? {
                guard case let .link(url) = textItem.content else {
                    return defaultAction
                }
                return UIAction { _ in
                    UIApplication.shared.open(url)
                }
            }

            func apply(_ attributedText: NSAttributedString, to textView: UITextView) {
                let selectedRange = textView.selectedRange
                UIView.performWithoutAnimation {
                    textView.textStorage.setAttributedString(attributedText)
                    if selectedRange.location <= textView.textStorage.length {
                        let length = min(selectedRange.length, textView.textStorage.length - selectedRange.location)
                        textView.selectedRange = NSRange(location: selectedRange.location, length: length)
                    }
                }
            }

            func isAtBottom(_ textView: UITextView) -> Bool {
                isNearBottom(textView, tolerance: 8)
            }

            func scrollToBottom(_ textView: UITextView) {
                let maxY = bottomOffset(for: textView)
                restore(offset: CGPoint(x: textView.contentOffset.x, y: maxY), in: textView)
            }

            func scrollToBottomLeading(_ textView: UITextView) {
                let minX = -textView.adjustedContentInset.left
                let maxY = bottomOffset(for: textView)
                restore(offset: CGPoint(x: minX, y: maxY), in: textView)
            }

            func pageUp(_ textView: UITextView) {
                scrollByPage(textView, direction: -1)
            }

            func pageDown(_ textView: UITextView) {
                scrollByPage(textView, direction: 1)
            }

            private func isNearBottom(_ scrollView: UIScrollView, tolerance: CGFloat) -> Bool {
                scrollView.contentOffset.y >= bottomOffset(for: scrollView) - tolerance
            }

            private func bottomOffset(for scrollView: UIScrollView) -> CGFloat {
                let visibleHeight = scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
                return max(
                    -scrollView.adjustedContentInset.top,
                    scrollView.contentSize.height - visibleHeight + scrollView.adjustedContentInset.bottom
                )
            }

            func restore(offset: CGPoint, in textView: UITextView) {
                restore(offset: offset, in: textView as UIScrollView)
            }

            func restore(offset: CGPoint, in scrollView: UIScrollView) {
                let minX = -scrollView.adjustedContentInset.left
                let minY = -scrollView.adjustedContentInset.top
                let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.adjustedContentInset.right)
                let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
                let restored = CGPoint(
                    x: min(max(offset.x, minX), maxX),
                    y: min(max(offset.y, minY), maxY)
                )

                UIView.performWithoutAnimation {
                    scrollView.setContentOffset(restored, animated: false)
                }
            }

            private func restoreTerminalPagerOffset(in scrollView: UIScrollView) {
                guard let terminalPagerStartOffset else { return }
                isProgrammaticScroll = true
                restore(offset: terminalPagerStartOffset, in: scrollView)
                isProgrammaticScroll = false
            }

            private func scrollByPage(_ textView: UITextView, direction: CGFloat) {
                let visibleHeight = max(
                    80,
                    textView.bounds.height
                        - textView.adjustedContentInset.top
                        - textView.adjustedContentInset.bottom
                )
                let delta = visibleHeight * 0.88 * direction
                restore(
                    offset: CGPoint(x: textView.contentOffset.x, y: textView.contentOffset.y + delta),
                    in: textView
                )
            }

            func updateScrollableWidth(_ width: CGFloat, in textView: UITextView) {
                let desiredWidth = width + textView.textContainerInset.left + textView.textContainerInset.right
                guard textView.contentSize.width < desiredWidth - 0.5 else { return }
                textView.contentSize = CGSize(width: desiredWidth, height: textView.contentSize.height)
            }
        }
    }
}

private extension UIEdgeInsets {
    var horizontal: CGFloat {
        left + right
    }
}

enum TerminalLinkDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let minimumWrappedURLFragmentLength = 24

    static func addDetectedLinks(to text: NSMutableAttributedString) {
        guard text.length > 0,
              let detector else {
            return
        }

        let scanText = linkScanText(from: text.string)
        let fullRange = NSRange(location: 0, length: scanText.text.utf16.count)
        detector.enumerateMatches(in: scanText.text, options: [], range: fullRange) { result, _, _ in
            guard let result,
                  let url = result.url ?? URL(string: (scanText.text as NSString).substring(with: result.range)) else {
                return
            }

            for originalRange in scanText.originalRanges(for: result.range) {
                text.addAttributes([
                    .link: url,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: originalRange)
            }
        }
    }

    private struct LinkScanText {
        var text: String
        var originalUTF16Offsets: [Int]

        func originalRanges(for range: NSRange) -> [NSRange] {
            guard range.location >= 0, range.length > 0 else { return [] }
            let upperBound = range.location + range.length
            guard range.location < originalUTF16Offsets.count,
                  upperBound <= originalUTF16Offsets.count else {
                return []
            }

            var ranges: [NSRange] = []
            var start = originalUTF16Offsets[range.location]
            var previous = start

            for index in (range.location + 1)..<upperBound {
                let current = originalUTF16Offsets[index]
                if current == previous + 1 {
                    previous = current
                } else {
                    ranges.append(NSRange(location: start, length: previous - start + 1))
                    start = current
                    previous = current
                }
            }

            ranges.append(NSRange(location: start, length: previous - start + 1))
            return ranges
        }
    }

    private static func linkScanText(from original: String) -> LinkScanText {
        var normalized = ""
        var originalUTF16Offsets: [Int] = []
        var originalUTF16Offset = 0
        var index = original.startIndex

        while index < original.endIndex {
            let character = original[index]
            let characterString = String(character)

            if character == "\n",
               let resumeIndex = softWrappedURLResumeIndex(in: original, at: index, normalizedSoFar: normalized) {
                while index < resumeIndex {
                    originalUTF16Offset += String(original[index]).utf16.count
                    index = original.index(after: index)
                }
                continue
            }

            normalized.append(character)
            for offset in 0..<characterString.utf16.count {
                originalUTF16Offsets.append(originalUTF16Offset + offset)
            }
            originalUTF16Offset += characterString.utf16.count
            index = original.index(after: index)
        }

        return LinkScanText(text: normalized, originalUTF16Offsets: originalUTF16Offsets)
    }

    private static func softWrappedURLResumeIndex(
        in text: String,
        at newlineIndex: String.Index,
        normalizedSoFar: String
    ) -> String.Index? {
        guard newlineIndex > text.startIndex else { return nil }
        let previousIndex = text.index(before: newlineIndex)
        let previousCharacter = text[previousIndex]
        guard isURLContinuationCharacter(previousCharacter),
              let activeFragment = activeURLFragment(in: normalizedSoFar) else {
            return nil
        }

        var resumeIndex = text.index(after: newlineIndex)
        while resumeIndex < text.endIndex, isHorizontalWhitespace(text[resumeIndex]) {
            resumeIndex = text.index(after: resumeIndex)
        }
        guard resumeIndex < text.endIndex else { return nil }

        let nextCharacter = text[resumeIndex]
        guard isURLContinuationCharacter(nextCharacter) else { return nil }

        if activeFragment.count >= minimumWrappedURLFragmentLength {
            return resumeIndex
        }

        if isStrongURLContinuationBoundary(previousCharacter) || isStrongURLContinuationBoundary(nextCharacter) {
            return resumeIndex
        }

        return nil
    }

    private static func activeURLFragment(in normalizedText: String) -> String? {
        guard let last = normalizedText.last,
              isURLContinuationCharacter(last) else {
            return nil
        }

        let start = normalizedText.lastIndex(where: { !isURLContinuationCharacter($0) })
            .map { normalizedText.index(after: $0) }
            ?? normalizedText.startIndex
        let fragment = String(normalizedText[start...])
        let lowercased = fragment.lowercased()
        guard lowercased.contains("://") || lowercased.hasPrefix("www.") else { return nil }
        return fragment
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func isURLContinuationCharacter(_ character: Character) -> Bool {
        let scalarView = character.unicodeScalars
        guard scalarView.count == 1, let scalar = scalarView.first else { return false }
        guard scalar.value >= 0x21 && scalar.value <= 0x7E else { return false }
        guard !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return false }
        return character != "<" && character != ">" && character != "\""
    }

    private static func isStrongURLContinuationBoundary(_ character: Character) -> Bool {
        "/?#&=_%.-:+~".contains(character)
    }
}
