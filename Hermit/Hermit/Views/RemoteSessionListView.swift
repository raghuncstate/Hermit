import SwiftUI
import SafariServices
import UIKit
import Network

struct RemoteSessionListView: View {
    let host: Host

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TmuxWorkspaceModel
    @State private var showingNewSession = false
    @State private var newSessionName = ""
    @State private var sessionPendingDelete: TmuxSession?
    @State private var kasmDestination: KasmWindowDestination?
    @State private var kasmBrowserRequest: KasmBrowserRequest?
    @State private var kasmIsBusy = false
    @State private var kasmStatusMessage: String?
    @State private var kasmAlertMessage: String?

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
                    Label("Another tmux client is attached. This can make terminal sizing change.", systemImage: "rectangle.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if supportsKasm {
                kasmSection
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
        .navigationDestination(item: $kasmDestination) { destination in
            WindowDetailView(
                model: model,
                session: destination.session,
                window: destination.window
            )
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
        .alert("Kasm", isPresented: Binding(
            get: { kasmAlertMessage != nil },
            set: { if !$0 { kasmAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(kasmAlertMessage ?? "")
        }
        .sheet(item: $kasmBrowserRequest) { request in
            SafariBrowserView(url: request.url)
                .ignoresSafeArea()
        }
    }

    private var supportsKasm: Bool {
        host.displayName.localizedCaseInsensitiveCompare("Hedgehog") == .orderedSame ||
            (host.username == "raghu" && host.hostname == "hedgehog6209.ddns.net" && host.port == 10000)
    }

    private var kasmSection: some View {
        Section {
            if let kasmStatusMessage {
                Label(kasmStatusMessage, systemImage: kasmIsBusy ? "clock" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(kasmIsBusy ? Color.secondary : Color.green)
            }

            Button {
                Task { await openKasmTerminal() }
            } label: {
                Label("Start Kasm Terminal", systemImage: "terminal")
            }
            .disabled(kasmIsBusy)

            Button {
                Task { await copyKasmPassword() }
            } label: {
                Label("Copy Kasm Password", systemImage: "doc.on.clipboard")
            }
            .disabled(kasmIsBusy)

            Button {
                Task { await openKasmBrowser() }
            } label: {
                Label("Open Kasm Browser", systemImage: "safari")
            }
            .disabled(kasmIsBusy)
        } header: {
            Text("Kasm")
        } footer: {
            Text("Hermit keeps the SSH tunnel open while the in-app browser is open.")
        }
    }

    @MainActor
    private func openKasmTerminal() async {
        kasmIsBusy = true
        kasmStatusMessage = "Opening Kasm terminal..."
        defer { kasmIsBusy = false }

        await model.connectIfNeeded()
        guard model.status == .connected else {
            kasmAlertMessage = model.errorMessage ?? "Could not connect to Hedgehog."
            kasmStatusMessage = nil
            return
        }

        guard let destination = await model.openKasmHelperWindow() else {
            kasmAlertMessage = model.errorMessage ?? "Could not create the Kasm tmux window."
            kasmStatusMessage = nil
            return
        }

        kasmStatusMessage = "Kasm terminal opened."
        kasmDestination = KasmWindowDestination(session: destination.session, window: destination.window)
    }

    @MainActor
    private func copyKasmPassword() async {
        kasmIsBusy = true
        kasmStatusMessage = "Copying Kasm password..."
        defer { kasmIsBusy = false }

        do {
            let password = try await fetchKasmPassword(startIfNeeded: true)
            UIPasteboard.general.string = password
            kasmStatusMessage = "Kasm password copied."
        } catch {
            kasmAlertMessage = error.localizedDescription
            kasmStatusMessage = nil
        }
    }

    @MainActor
    private func openKasmBrowser() async {
        kasmIsBusy = true
        kasmStatusMessage = "Starting Kasm and tunnel..."
        defer { kasmIsBusy = false }

        await model.connectIfNeeded()
        guard model.status == .connected else {
            kasmAlertMessage = model.errorMessage ?? "Could not connect to Hedgehog."
            kasmStatusMessage = nil
            return
        }

        do {
            let password = try await fetchKasmPassword(startIfNeeded: true)
            UIPasteboard.general.string = password
            let isTunnelReady = await KasmTunnelProbe.waitForOpenPort()
            guard isTunnelReady else {
                throw KasmError.tunnelUnavailable
            }

            let url = kasmURL()
            kasmStatusMessage = "Kasm password copied. Username: kasm_user."
            kasmBrowserRequest = KasmBrowserRequest(url: url)
        } catch {
            kasmAlertMessage = error.localizedDescription
            kasmStatusMessage = nil
        }
    }

    private func fetchKasmPassword(startIfNeeded: Bool) async throws -> String {
        let script: String
        if startIfNeeded {
            script = "source ~/.bashrc; kasm start >/tmp/hermit-kasm-start.log; kasm password"
        } else {
            script = "cat ~/.config/kasm-browser/password"
        }

        let command = "bash -lc \(TmuxCommandQuoter.quote(script))"
        let output = try await SSHConnectionManager.executeCommand(command, on: host, maxResponseSize: 4096)
        let password = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            throw KasmError.emptyPassword
        }
        return password
    }

    private func kasmURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "127.0.0.1"
        components.port = 6901
        return components.url ?? URL(string: "https://127.0.0.1:6901/")!
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

private struct KasmWindowDestination: Identifiable, Hashable {
    var session: TmuxSession
    var window: TmuxWindow
    var id: String { "\(session.id)|\(window.id)" }
}

private struct KasmBrowserRequest: Identifiable {
    var id = UUID()
    var url: URL
}

private struct SafariBrowserView: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum KasmError: LocalizedError {
    case emptyPassword
    case tunnelUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            "Kasm password command returned no password."
        case .tunnelUnavailable:
            "Kasm is running, but the local SSH tunnel to 127.0.0.1:6901 is not available yet. Reopen Hedgehog and try again."
        }
    }
}

private enum KasmTunnelProbe {
    static func waitForOpenPort(
        host: String = "127.0.0.1",
        port: UInt16 = 6901,
        attempts: Int = 20,
        delayNanoseconds: UInt64 = 100_000_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if await isOpen(host: host, port: port) {
                return true
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return false
    }

    private static func isOpen(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var didResume = false

            func finish(_ isOpen: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                continuation.resume(returning: isOpen)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .waiting:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                finish(false)
            }
        }
    }
}
