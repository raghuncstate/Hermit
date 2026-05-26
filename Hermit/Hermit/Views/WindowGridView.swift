import SwiftUI

struct WindowGridView: View {
    var model: TmuxWorkspaceModel
    var session: TmuxSession

    @Environment(DataStore.self) private var dataStore
    @State private var renamingWindow: TmuxWindow?
    @State private var renameText = ""
    @State private var windowPendingDelete: TmuxWindow?

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.windows(for: session)) { window in
                    ZStack(alignment: .topTrailing) {
                        NavigationLink {
                            WindowDetailView(model: model, session: session, window: window)
                        } label: {
                            windowCell(window)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 6) {
                            Button {
                                toggleFavorite(window)
                            } label: {
                                Image(systemName: dataStore.isFavorite(shortcut(for: window)) ? "star.fill" : "star")
                                    .frame(width: 32, height: 32, alignment: .center)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle)
                            .tint(.yellow)
                            .accessibilityLabel("Favorite Window \(window.name)")

                            Button(role: .destructive) {
                                windowPendingDelete = window
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 32, height: 32, alignment: .center)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle)
                            .tint(.red)
                            .accessibilityLabel("Kill Window \(window.name)")
                        }
                        .padding(8)
                    }
                    .contextMenu {
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
                }
            }
            .padding()
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
        .alert("Kill Window?", isPresented: Binding(
            get: { windowPendingDelete != nil },
            set: { if !$0 { windowPendingDelete = nil } }
        )) {
            Button("Kill", role: .destructive) {
                if let window = windowPendingDelete {
                    Task { await model.killWindow(window, in: session) }
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

    private func windowCell(_ window: TmuxWindow) -> some View {
        let panes = model.panes(for: window)
        let activeCommand = panes.first(where: \.isActive)?.currentCommand ?? panes.first?.currentCommand ?? "-"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("#\(window.index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .center)
                Text(window.name)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.trailing, 78)
                Spacer(minLength: 0)
                if window.isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                }
            }

            PaneLayoutView(
                layout: window.layout,
                panes: panes,
                activePaneId: panes.first(where: \.isActive)?.id,
                compact: true
            )
            .frame(height: 92)

            Label(activeCommand, systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}
