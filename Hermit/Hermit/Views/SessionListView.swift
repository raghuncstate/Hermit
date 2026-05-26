import SwiftUI

struct SessionListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var showingNewHost = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if dataStore.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host to open a mobile tmux control session.")
                    )
                } else {
                    hostList
                }
            }
            .navigationTitle("Hermit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewHost = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Host")
                }
            }
            .sheet(isPresented: $showingNewHost) {
                NewHostView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    private var hostList: some View {
        List {
            let favoriteShortcuts = dataStore.favoriteTmuxShortcuts()
            if !favoriteShortcuts.isEmpty {
                Section("Favorites") {
                    ForEach(favoriteShortcuts) { shortcut in
                        shortcutNavigationLink(shortcut)
                    }
                }
            }

            let frequentShortcuts = dataStore.frequentTmuxShortcuts()
            if !frequentShortcuts.isEmpty {
                Section("Frequently Used") {
                    ForEach(frequentShortcuts) { shortcut in
                        shortcutNavigationLink(shortcut)
                    }
                }
            }

            Section("Hosts") {
                ForEach(dataStore.hosts.sorted { $0.displayName < $1.displayName }) { host in
                    NavigationLink {
                        RemoteSessionListView(host: host)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.displayName)
                                .font(.body.weight(.medium))
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("mobile session: \(host.defaultTmuxSessionName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            dataStore.deleteHost(host)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutNavigationLink(_ shortcut: TmuxShortcut) -> some View {
        if let host = dataStore.host(for: shortcut) {
            NavigationLink {
                TmuxShortcutDestinationView(host: host, shortcut: shortcut)
            } label: {
                shortcutRow(shortcut)
            }
        }
    }

    private func shortcutRow(_ shortcut: TmuxShortcut) -> some View {
        HStack(spacing: 12) {
            Image(systemName: shortcut.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(shortcut.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if shortcut.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            } else if shortcut.visitCount > 1 {
                Text("\(shortcut.visitCount)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

struct ResolvedTmuxShortcut {
    var session: TmuxSession
    var window: TmuxWindow
    var pane: TmuxPane?
}

struct TmuxShortcutDestinationView: View {
    let host: Host
    let shortcut: TmuxShortcut

    @State private var model: TmuxWorkspaceModel
    @State private var resolvedShortcut: ResolvedTmuxShortcut?
    @State private var errorMessage: String?

    init(host: Host, shortcut: TmuxShortcut) {
        self.host = host
        self.shortcut = shortcut
        _model = State(initialValue: TmuxWorkspaceModel(host: host))
    }

    var body: some View {
        Group {
            if let resolvedShortcut {
                WindowDetailView(
                    model: model,
                    session: resolvedShortcut.session,
                    window: resolvedShortcut.window,
                    initialPaneId: resolvedShortcut.pane?.id ?? shortcut.paneID,
                    initialPaneIndex: shortcut.paneIndex
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "Shortcut Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Opening \(shortcut.displayTitle)")
                    .navigationTitle(shortcut.displayTitle)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: shortcut.id) {
            await resolveShortcut()
        }
    }

    @MainActor
    private func resolveShortcut() async {
        errorMessage = nil
        resolvedShortcut = nil

        await model.connectIfNeeded()
        await model.refreshSessions()

        guard let session = matchingSession() else {
            errorMessage = "The tmux session \(shortcut.sessionName) was not found on \(host.displayName)."
            return
        }

        await model.refreshWindows(for: session)

        guard let window = matchingWindow(in: session) else {
            errorMessage = "The tmux window \(shortcut.windowName) was not found in \(session.name)."
            return
        }

        await model.loadWindow(window)
        let pane = matchingPane(in: window)

        if shortcut.kind == .pane, pane == nil {
            errorMessage = "The saved pane was not found. The window may have changed."
            resolvedShortcut = ResolvedTmuxShortcut(session: session, window: window, pane: nil)
            return
        }

        resolvedShortcut = ResolvedTmuxShortcut(session: session, window: window, pane: pane)
    }

    private func matchingSession() -> TmuxSession? {
        model.sessions.first { $0.id == shortcut.sessionID }
            ?? model.sessions.first { $0.name == shortcut.sessionName }
    }

    private func matchingWindow(in session: TmuxSession) -> TmuxWindow? {
        let windows = model.windows(for: session)
        return windows.first { $0.id == shortcut.windowID }
            ?? windows.first { $0.name == shortcut.windowName && $0.index == shortcut.windowIndex }
            ?? windows.first { $0.name == shortcut.windowName }
            ?? windows.first { $0.index == shortcut.windowIndex }
    }

    private func matchingPane(in window: TmuxWindow) -> TmuxPane? {
        let panes = model.panes(for: window)
        return panes.first { $0.id == shortcut.paneID }
            ?? panes.first { $0.index == shortcut.paneIndex }
    }
}
