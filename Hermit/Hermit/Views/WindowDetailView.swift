import SwiftUI
import UIKit

struct WindowDetailView: View {
    private enum PaneScrollAction: Equatable {
        case top
        case bottom
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

    private struct PaneDeleteRequest {
        var pane: TmuxPane
        var window: TmuxWindow
    }

    private static let liveRefreshIntervalNanoseconds: UInt64 = 4_000_000
    private static let minimumTerminalFontSize: CGFloat = 8
    private static let maximumTerminalFontSize: CGFloat = 30
    private static let defaultTerminalFontSize: CGFloat = 14
    private static let terminalHorizontalChrome: CGFloat = 18
    private static let terminalCharacterWidthRatio: CGFloat = 0.66

    var model: TmuxWorkspaceModel
    var session: TmuxSession
    var window: TmuxWindow

    @Environment(VoiceInputCoordinator.self) private var voiceCoordinator
    @State private var selectedPaneId: String?
    @State private var selectedWindowId: String?
    @State private var commandText = ""
    @State private var streamedInputText = ""
    @State private var suppressInputChange = false
    @State private var showingVoiceModal = false
    @State private var showingWindowSwitcher = false
    @State private var windowSwitcherScope: WindowSwitcherScope = .currentSession
    @State private var voiceText = ""
    @State private var follow = true
    @State private var fontSize: CGFloat = 14
    @State private var zoomBase: CGFloat = 14
    @State private var panePendingDelete: PaneDeleteRequest?
    @State private var windowPendingDelete: TmuxWindow?
    @State private var scrollRequest = PaneScrollRequest(action: .bottom, token: 0)
    @State private var terminalViewportWidth: CGFloat = 0
    @State private var scrollbackLoadedPaneIds: Set<String> = []

    private var allKnownWindows: [TmuxWindow] {
        let loadedWindows = model.sessions.flatMap { model.windows(for: $0) }
        return loadedWindows.isEmpty ? model.windows(for: session) : loadedWindows
    }

    private var panes: [TmuxPane] {
        model.panes(for: currentWindow)
    }

    private var currentWindow: TmuxWindow {
        let targetWindowId = selectedWindowId ?? window.id
        return allKnownWindows.first { $0.id == targetWindowId } ?? allKnownWindows.first { $0.id == window.id } ?? window
    }

    private var currentSession: TmuxSession {
        model.sessions.first { $0.id == currentWindow.sessionId } ?? session
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
                terminalFontMenu

                Toggle(isOn: $follow) {
                    Image(systemName: follow ? "dot.radiowaves.left.and.right" : "pause.fill")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Follow Output")
                .onChange(of: follow) { _, value in
                    if value {
                        requestPaneScroll(.bottom)
                    } else if let pane = selectedPane {
                        model.setFollow(pane.id, enabled: false)
                    }
                }
            }
        }
        .task(id: currentWindow.id) {
            selectedWindowId = currentWindow.id
            await model.loadWindow(currentWindow)
            selectedPaneId = model.activePane(for: currentWindow)?.id
            if let selectedPaneId {
                model.setFollow(selectedPaneId, enabled: follow)
            }
        }
        .task(id: liveRefreshID) {
            guard follow, let pane = selectedPane else { return }
            while !Task.isCancelled {
                await model.captureLive(pane)
                try? await Task.sleep(nanoseconds: Self.liveRefreshIntervalNanoseconds)
            }
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
        .alert("Kill Pane?", isPresented: Binding(
            get: { panePendingDelete != nil },
            set: { if !$0 { panePendingDelete = nil } }
        )) {
            Button("Kill", role: .destructive) {
                if let request = panePendingDelete {
                    killPane(request.pane, in: request.window)
                }
                panePendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                panePendingDelete = nil
            }
        } message: {
            if let request = panePendingDelete {
                Text(request.pane.id)
            }
        }
        .alert("Kill Window?", isPresented: Binding(
            get: { windowPendingDelete != nil },
            set: { if !$0 { windowPendingDelete = nil } }
        )) {
            Button("Kill", role: .destructive) {
                if let window = windowPendingDelete {
                    killWindow(window)
                }
                windowPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                windowPendingDelete = nil
            }
        } message: {
            if let window = windowPendingDelete {
                Text(window.name)
            }
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

            if let pane = selectedPane {
                Button {
                    requestPaneScroll(.top)
                } label: {
                    Image(systemName: "arrow.up.to.line")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .accessibilityLabel("Go to Top")

                Button {
                    requestPaneScroll(.bottom)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .accessibilityLabel("Go to Bottom")

                Menu {
                    Button {
                        Task { await model.split(pane, in: currentWindow, vertical: false) }
                    } label: {
                        Label("Split Horizontal", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        Task { await model.split(pane, in: currentWindow, vertical: true) }
                    } label: {
                        Label("Split Vertical", systemImage: "rectangle.split.1x2")
                    }
                    Button(role: .destructive) {
                        panePendingDelete = PaneDeleteRequest(pane: pane, window: currentWindow)
                    } label: {
                        Label("Kill Pane", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Pane Actions")
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
            ContentUnavailableView(
                model.errorMessage ?? "Loading Pane",
                systemImage: model.errorMessage == nil ? "terminal" : "exclamationmark.triangle",
                description: Text(model.errorMessage == nil ? "Fetching pane output." : "Pull to refresh or reopen the window.")
            )
        } else {
            ContentUnavailableView("No Pane Selected", systemImage: "rectangle.dashed")
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
                onManualScroll: {
                    prepareForManualPaneScroll(pane)
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

    private func sessionHeader(_ tmuxSession: TmuxSession) -> some View {
        Text(tmuxSession.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }

    private func windowSwitcherSection(for tmuxWindow: TmuxWindow, in tmuxSession: TmuxSession) -> some View {
        let windowPanes = model.panes(for: tmuxWindow)
        let isCurrentWindow = tmuxWindow.id == currentWindow.id

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    switchToWindow(tmuxWindow, in: tmuxSession)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Text("#\(tmuxWindow.index)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tmuxWindow.name)
                                .font(.body.weight(isCurrentWindow ? .semibold : .regular))
                                .lineLimit(1)
                            Text(windowSwitcherScope == .allSessions ? "\(tmuxSession.name) - \(windowPanes.count) panes" : "\(windowPanes.count) panes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if isCurrentWindow {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    windowPendingDelete = tmuxWindow
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 34, height: 34, alignment: .center)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .tint(.red)
                .accessibilityLabel("Kill Window \(tmuxWindow.name)")
            }
            .task(id: tmuxWindow.id) {
                await model.refreshPanes(for: tmuxWindow)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isCurrentWindow ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8)
            )

            if !windowPanes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(windowPanes) { pane in
                        HStack(alignment: .center, spacing: 6) {
                            Button {
                                switchToPane(pane, in: tmuxWindow, session: tmuxSession)
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: pane.id == selectedPane?.id ? "terminal.fill" : "terminal")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, alignment: .center)

                                    Text("#\(pane.index)")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, alignment: .center)

                                    Text(pane.currentCommand)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                panePendingDelete = PaneDeleteRequest(pane: pane, window: tmuxWindow)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .frame(width: 28, height: 28, alignment: .center)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle)
                            .tint(.red)
                            .accessibilityLabel("Kill Pane \(pane.index)")
                        }
                        .padding(.leading, 14)
                    }
                }
                .padding(.top, 2)
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
                    streamInputChange(to: newValue)
                }
                .onSubmit(sendEnter)

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

    private func streamInputChange(to newValue: String) {
        guard !suppressInputChange else { return }
        guard let pane = selectedPane else {
            streamedInputText = newValue
            return
        }

        let delta = inputDelta(from: streamedInputText, to: newValue)
        guard delta.backspaceCount > 0 || !delta.insertedText.isEmpty else {
            streamedInputText = newValue
            return
        }

        requestPaneScroll(.bottom)

        if delta.backspaceCount > 0 {
            model.echoBackspace(count: delta.backspaceCount, to: pane)
            Task { await model.sendBackspace(count: delta.backspaceCount, to: pane) }
        }

        if !delta.insertedText.isEmpty {
            model.echoInputText(delta.insertedText, to: pane)
            Task { await model.sendInputText(delta.insertedText, to: pane) }
        }

        streamedInputText = newValue
    }

    private func sendEnter() {
        guard let pane = selectedPane else { return }

        suppressInputChange = true
        commandText = ""
        streamedInputText = ""
        DispatchQueue.main.async {
            suppressInputChange = false
        }

        requestPaneScroll(.bottom)
        model.echoEnter(to: pane)
        Task { await model.sendEnter(to: pane) }
    }

    private func sendCommandText(_ command: String, to pane: TmuxPane) {
        requestPaneScroll(.bottom)
        model.echoSubmittedCommand(command, to: pane)
        Task { await model.sendCommand(command, to: pane) }
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
        requestPaneScroll(.bottom)
        Task { await model.send(macro, to: pane) }
    }

    private func switchToWindow(_ tmuxWindow: TmuxWindow, in tmuxSession: TmuxSession? = nil) {
        let targetSession = tmuxSession ?? session(for: tmuxWindow)
        selectedWindowId = tmuxWindow.id
        selectedPaneId = nil
        follow = true
        showingWindowSwitcher = false

        Task { @MainActor in
            await model.selectWindow(tmuxWindow, in: targetSession)
            await model.refreshWindows(for: targetSession)
            let loadedWindow = model.windows(for: targetSession).first { $0.id == tmuxWindow.id } ?? tmuxWindow
            selectedPaneId = model.activePane(for: loadedWindow)?.id
            if let selectedPaneId {
                model.setFollow(selectedPaneId, enabled: true)
            }
            scrollRequest = PaneScrollRequest(action: .bottom, token: scrollRequest.token + 1)
        }
    }

    private func switchToPane(_ pane: TmuxPane, in tmuxWindow: TmuxWindow, session tmuxSession: TmuxSession? = nil) {
        let targetSession = tmuxSession ?? session(for: tmuxWindow)
        selectedWindowId = tmuxWindow.id
        selectedPaneId = pane.id
        follow = true
        showingWindowSwitcher = false

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

    private func killPane(_ pane: TmuxPane, in tmuxWindow: TmuxWindow) {
        let targetSession = session(for: tmuxWindow)
        Task { @MainActor in
            await model.kill(pane, in: tmuxWindow)
            await model.refreshWindows(for: targetSession)
            if selectedPaneId == pane.id {
                selectedPaneId = model.activePane(for: currentWindow)?.id
            }
        }
    }

    private func killWindow(_ tmuxWindow: TmuxWindow) {
        let targetSession = session(for: tmuxWindow)
        Task { @MainActor in
            await model.killWindow(tmuxWindow, in: targetSession)
            await model.refreshWindows(for: targetSession)
            if selectedWindowId == tmuxWindow.id || currentWindow.id == tmuxWindow.id {
                selectedWindowId = model.windows(for: targetSession).first?.id ?? allKnownWindows.first?.id
                selectedPaneId = nil
            }
        }
    }

    private func session(for tmuxWindow: TmuxWindow) -> TmuxSession {
        model.sessions.first { $0.id == tmuxWindow.sessionId } ?? session
    }

    private func refreshWindowSwitcher() {
        Task { @MainActor in
            await model.refreshSessions()
            let sessionsToRefresh = windowSwitcherScope == .allSessions ? model.sessions : [currentSession]
            for tmuxSession in sessionsToRefresh {
                await model.refreshWindows(for: tmuxSession)
            }
        }
    }

    private func requestPaneScroll(_ action: PaneScrollAction) {
        follow = action == .bottom
        if let pane = selectedPane {
            model.setFollow(pane.id, enabled: follow)
            if action == .bottom {
                scrollbackLoadedPaneIds.remove(pane.id)
            }
        }

        if action == .bottom {
            scrollRequest = PaneScrollRequest(action: action, token: scrollRequest.token + 1)
            return
        }

        guard let pane = selectedPane else {
            scrollRequest = PaneScrollRequest(action: action, token: scrollRequest.token + 1)
            return
        }

        Task { @MainActor in
            await model.captureScrollback(pane)
            scrollbackLoadedPaneIds.insert(pane.id)
            scrollRequest = PaneScrollRequest(action: action, token: scrollRequest.token + 1)
        }
    }

    private func prepareForManualPaneScroll(_ pane: TmuxPane) {
        if follow {
            follow = false
            model.setFollow(pane.id, enabled: false)
        }

        guard !scrollbackLoadedPaneIds.contains(pane.id) else { return }
        scrollbackLoadedPaneIds.insert(pane.id)

        Task { @MainActor in
            await model.captureScrollback(pane)
        }
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
        let snapshotWidth = model.snapshotsByPane[pane.id].map { longestLineLength(in: $0) } ?? 0
        return max(pane.width, snapshotWidth)
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
        var onManualScroll: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onManualScroll: onManualScroll)
        }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.isEditable = false
            textView.isSelectable = true
            textView.isScrollEnabled = true
            textView.dataDetectorTypes = [.link]
            textView.backgroundColor = .systemBackground
            textView.textColor = .label
            textView.tintColor = .systemBlue
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
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            context.coordinator.onManualScroll = onManualScroll
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
                textView.attributedText = Self.attributedText(from: displayText, fontSize: fontSize)
                textView.isSelectable = true
                context.coordinator.rawText = snapshot.rawText
                context.coordinator.displayText = displayText
                context.coordinator.fontSize = fontSize
                textView.layoutIfNeeded()

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
                case .top:
                    context.coordinator.scrollToTop(textView)
                case .bottom:
                    context.coordinator.scrollToBottom(textView)
                }
            } else if follow && contentChanged {
                context.coordinator.scrollToBottom(textView)
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

        private static func attributedText(from plainText: String, fontSize: CGFloat) -> NSAttributedString {
            let output = NSMutableAttributedString(string: plainText)
            let baseFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping
            paragraphStyle.lineSpacing = 2

            let fullRange = NSRange(location: 0, length: output.length)
            output.addAttributes([
                .font: baseFont,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle,
            ], range: fullRange)
            addDetectedLinks(to: output)
            return output
        }

        private static func addDetectedLinks(to text: NSMutableAttributedString) {
            guard text.length > 0,
                  let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return
            }

            let fullRange = NSRange(location: 0, length: text.length)
            detector.enumerateMatches(in: text.string, options: [], range: fullRange) { result, _, _ in
                guard let result, let url = result.url else { return }
                text.addAttributes([
                    .link: url,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: result.range)
            }
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var onManualScroll: () -> Void
            var rawText = ""
            var displayText = ""
            var fontSize: CGFloat = 0
            var contentWidth: CGFloat = 0
            var scrollToken = -1
            var isProgrammaticScroll = false

            init(onManualScroll: @escaping () -> Void) {
                self.onManualScroll = onManualScroll
            }

            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                guard !isProgrammaticScroll else { return }
                onManualScroll()
            }

            func textViewDidChangeSelection(_ textView: UITextView) {
                guard !isProgrammaticScroll, textView.selectedRange.length > 0 else { return }
                onManualScroll()
            }

            func isAtBottom(_ textView: UITextView) -> Bool {
                let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
                let bottomOffset = max(-textView.adjustedContentInset.top, textView.contentSize.height - visibleHeight + textView.adjustedContentInset.bottom)
                return textView.contentOffset.y >= bottomOffset - 8
            }

            func scrollToTop(_ textView: UITextView) {
                DispatchQueue.main.async {
                    let minX = -textView.adjustedContentInset.left
                    let minY = -textView.adjustedContentInset.top
                    textView.setContentOffset(CGPoint(x: minX, y: minY), animated: false)
                }
            }

            func scrollToBottom(_ textView: UITextView) {
                DispatchQueue.main.async {
                    let visibleHeight = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
                    let maxY = max(-textView.adjustedContentInset.top, textView.contentSize.height - visibleHeight + textView.adjustedContentInset.bottom)
                    let minX = -textView.adjustedContentInset.left
                    textView.setContentOffset(CGPoint(x: minX, y: maxY), animated: false)
                }
            }

            func restore(offset: CGPoint, in textView: UITextView) {
                DispatchQueue.main.async {
                    let minX = -textView.adjustedContentInset.left
                    let minY = -textView.adjustedContentInset.top
                    let maxX = max(minX, textView.contentSize.width - textView.bounds.width + textView.adjustedContentInset.right)
                    let maxY = max(minY, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
                    let restored = CGPoint(
                        x: min(max(offset.x, minX), maxX),
                        y: min(max(offset.y, minY), maxY)
                    )
                    textView.setContentOffset(restored, animated: false)
                }
            }
        }
    }
}

private extension UIEdgeInsets {
    var horizontal: CGFloat {
        left + right
    }
}
