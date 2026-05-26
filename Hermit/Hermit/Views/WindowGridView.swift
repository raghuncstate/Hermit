import SwiftUI

struct WindowGridView: View {
    var model: TmuxWorkspaceModel
    var session: TmuxSession

    @Environment(DataStore.self) private var dataStore
    @State private var renamingWindow: TmuxWindow?
    @State private var renameText = ""
    @State private var windowPendingDelete: TmuxWindow?

    var body: some View {
        List {
            ForEach(model.windows(for: session)) { window in
                NavigationLink {
                    WindowDetailView(model: model, session: session, window: window)
                } label: {
                    windowRow(window)
                }
                .contextMenu {
                    windowActions(for: window)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        toggleFavorite(window)
                    } label: {
                        Label(
                            dataStore.isFavorite(shortcut(for: window)) ? "Unfavorite" : "Favorite",
                            systemImage: dataStore.isFavorite(shortcut(for: window)) ? "star.slash" : "star"
                        )
                    }
                    .tint(.yellow)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        windowPendingDelete = window
                    } label: {
                        Label("Kill", systemImage: "trash")
                    }
                    Button {
                        renamingWindow = window
                        renameText = window.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.newWindow(in: session) }
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("New Window")
            }
        }
        .refreshable {
            await model.refreshWindows(for: session)
        }
        .task {
            await model.refreshWindows(for: session)
        }
        .alert("Rename Window", isPresented: Binding(
            get: { renamingWindow != nil },
            set: { if !$0 { renamingWindow = nil } }
        )) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                if let window = renamingWindow {
                    Task { await model.renameWindow(window, to: renameText, in: session) }
                }
                renamingWindow = nil
            }
            Button("Cancel", role: .cancel) {
                renamingWindow = nil
            }
        }
        .confirmationDialog(
            "Kill Window?",
            isPresented: Binding(
                get: { windowPendingDelete != nil },
                set: { if !$0 { windowPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: windowPendingDelete
        ) { window in
            Button("Kill", role: .destructive) {
                Task { await model.killWindow(window, in: session) }
                windowPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                windowPendingDelete = nil
            }
        } message: { window in
            Text("Window #\(window.index) \(window.name).")
        }
    }

    @ViewBuilder
    private func windowActions(for window: TmuxWindow) -> some View {
        Button {
            toggleFavorite(window)
        } label: {
            Label(
                dataStore.isFavorite(shortcut(for: window)) ? "Unfavorite" : "Favorite",
                systemImage: dataStore.isFavorite(shortcut(for: window)) ? "star.slash" : "star"
            )
        }
        Button {
            renamingWindow = window
            renameText = window.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { await model.moveWindow(window, by: -1, in: session) }
        } label: {
            Label("Move Left", systemImage: "arrow.left")
        }
        Button {
            Task { await model.moveWindow(window, by: 1, in: session) }
        } label: {
            Label("Move Right", systemImage: "arrow.right")
        }
        Button(role: .destructive) {
            windowPendingDelete = window
        } label: {
            Label("Kill", systemImage: "trash")
        }
    }

    private func shortcut(for window: TmuxWindow) -> TmuxShortcut {
        TmuxShortcut(
            kind: .window,
            host: model.host,
            session: session,
            window: window
        )
    }

    private func toggleFavorite(_ window: TmuxWindow) {
        dataStore.toggleFavorite(shortcut(for: window))
    }

    private func windowRow(_ window: TmuxWindow) -> some View {
        let panes = model.panes(for: window)
        let activeCommand = panes.first(where: \.isActive)?.currentCommand ?? panes.first?.currentCommand ?? "-"

        return HStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(window.index)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Text(window.name)
                        .font(.body.weight(window.isActive ? .semibold : .regular))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Label("\(panes.count)", systemImage: "square.split.2x1")
                    Label(activeCommand, systemImage: "terminal")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if dataStore.isFavorite(shortcut(for: window)) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }

            if window.isActive {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 5)
    }
}
