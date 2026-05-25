import SwiftUI

struct RemoteSessionListView: View {
    let host: Host

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TmuxWorkspaceModel
    @State private var showingNewSession = false
    @State private var newSessionName = "mobile"
    @State private var sessionPendingDelete: TmuxSession?

    init(host: Host) {
        self.host = host
        _model = State(initialValue: TmuxWorkspaceModel(host: host))
    }

    var body: some View {
        List {
            if case .failed(let message) = model.status {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if model.sessions.contains(where: { $0.attachedCount > 1 }) {
                Section {
                    Label("Another tmux client is attached. Use the dedicated mobile session to avoid size changes.", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(model.sessions) { session in
                    NavigationLink {
                        WindowGridView(model: model, session: session)
                    } label: {
                        sessionRow(session)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            sessionPendingDelete = session
                        } label: {
                            Label("Kill", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("tmux Sessions")
            }
        }
        .overlay {
            if model.sessions.isEmpty && model.status == .connected {
                ContentUnavailableView(
                    "No tmux Sessions",
                    systemImage: "rectangle.3.group",
                    description: Text("Create a session from the toolbar.")
                )
            }
        }
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(host.displayName)
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewSession = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New tmux Session")
            }
        }
        .refreshable {
            await model.refreshSessions()
        }
        .task {
            await model.connectIfNeeded()
            await model.refreshSessions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.connectIfNeeded()
                    await model.refreshSessions()
                }
            } else if phase == .background {
                Task { await model.disconnect() }
            }
        }
        .alert("New tmux Session", isPresented: $showingNewSession) {
            TextField("Session name", text: $newSessionName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                Task { await model.newSession(named: newSessionName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Kill tmux Session?", isPresented: Binding(
            get: { sessionPendingDelete != nil },
            set: { if !$0 { sessionPendingDelete = nil } }
        )) {
            Button("Kill", role: .destructive) {
                if let session = sessionPendingDelete {
                    Task { await model.killSession(session) }
                }
                sessionPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDelete = nil
            }
        } message: {
            if let session = sessionPendingDelete {
                Text(session.name)
            }
        }
    }

    private func sessionRow(_ session: TmuxSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    if let count = session.windowCount {
                        Label("\(count)", systemImage: "rectangle.split.3x1")
                    }
                    if let activity = session.activity {
                        Text(activity, style: .relative)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isAttached {
                Text("\(session.attachedCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.18), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        }
    }
}
