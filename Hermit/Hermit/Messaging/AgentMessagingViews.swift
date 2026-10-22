import SwiftUI
import UIKit

private struct AgentTrustPrompt: ViewModifier {
    var store: AgentChatStore
    var enabled = true
    func body(content: Content) -> some View {
        content.alert(store.trust?.changed == true ? "SSH host key changed" : "Verify SSH host", isPresented: Binding(get: { enabled && store.trust != nil }, set: { _ in })) {
            Button("Cancel", role: .cancel) { store.trust = nil; store.trustHost = nil }
            Button("Trust verified key") {
                guard let challenge = store.trust, let host = store.trustHost else { return }
                store.trust = nil; store.trustHost = nil
                Task { await store.acceptTrust(challenge, host: host) }
            }
        } message: {
            Text("\(store.trust?.endpoint ?? "")\n\(store.trust?.fingerprint ?? "")\nVerify this fingerprint against the host before trusting it.")
        }
    }
}

struct HermitRootView: View {
    @AppStorage("agentMessagingEnabled") private var enabled = false
    @State private var terminal = false
    @State private var terminalHasOpened = false
    var body: some View {
        if enabled || AgentChatStore.demoRequested {
            TabView(selection: $terminal) {
                AgentInboxView().tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }.tag(false)
                Group { if terminal || terminalHasOpened { SessionListView() } else { Color.clear } }
                    .tabItem { Label("Terminals", systemImage: "terminal") }.tag(true)
            }
            .onChange(of: terminal) { _, selected in if selected { terminalHasOpened = true } }
        } else { SessionListView() }
    }
}

struct AgentInboxView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AgentChatStore(demo: AgentChatStore.demoRequested)
    @State private var path: [AgentConversation] = []
    @State private var search = ""
    @State private var selectedHost: UUID?
    @State private var showingServers = false
    @State private var showingSettings = false
    @State private var composing = false
    @State private var showingHistory = false
    @State private var includeCached = false

    private var hosts: [Host] {
        if store.demo {
            return [Host(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "Studio Mac", hostname: "fixture.invalid", username: "fixture"),
                    Host(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, displayName: "Build host", hostname: "fixture.invalid", username: "fixture")]
        }
        return dataStore.hosts
    }
    private var visible: [AgentConversation] {
        store.inboxConversations(includeCached: includeCached).filter { c in
            (selectedHost == nil || c.profileID == selectedHost) && (search.isEmpty || c.title.localizedCaseInsensitiveContains(search) || c.cwd.localizedCaseInsensitiveContains(search))
        }
    }
    private var favorites: [AgentConversation] {
        visible.filter { c in
            store.archive.favorites.contains(c.id) && (store.demo || hosts.contains { $0.id == c.profileID && AgentBridgeClient.route(for: $0) == c.route })
        }.prefix(3).map { $0 }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = store.error {
                    Section {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            Text(error).font(.footnote).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button { store.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
                        }
                    }
                }
                if !favorites.isEmpty {
                    Section("Starred") { ForEach(favorites) { row($0) } }
                }
                let unstarred = visible.filter { !favorites.contains($0) }
                if unstarred.contains(where: { !$0.isNativeHistory }) {
                    Section("Conversations") {
                        ForEach(unstarred.filter { !$0.isNativeHistory }) { row($0) }
                    }
                }
                let histories = unstarred.filter(\.isNativeHistory)
                if !histories.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: Binding(get: { showingHistory || !search.isEmpty }, set: { showingHistory = $0 })) {
                            ForEach(histories) { row($0) }
                        } label: {
                            Label("Saved history (\(histories.count))", systemImage: "clock")
                                .accessibilityIdentifier("chat-saved-history")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if visible.isEmpty && store.error == nil { ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right") } }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search conversations")
            .refreshable { await store.refresh(hosts: hosts) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All hosts") { selectedHost = nil }
                        ForEach(hosts) { host in Button(host.displayName) { selectedHost = host.id } }
                        Toggle("Include cached history", isOn: $includeCached)
                        Divider()
                        Button("Connections", systemImage: "server.rack") { showingServers = true }
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        Button("Clear downloaded history", systemImage: "arrow.counterclockwise") { store.clearHistoryCache() }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel("Filter and connections")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation").disabled(store.demo || hosts.isEmpty)
                }
            }
            .navigationDestination(for: AgentConversation.self) { conversation in
                AgentConversationView(store: store, conversation: conversation, host: hosts.first { $0.id == conversation.profileID })
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingServers) { connectionSheet }
            .sheet(isPresented: $composing) {
                AgentNewConversationView(store: store, hosts: hosts) { conversation in composing = false; path.append(conversation) }
            }
            .modifier(AgentTrustPrompt(store: store, enabled: !composing && !showingServers && !showingSettings))
        }
        .task { await store.resume(hosts: hosts) }
        .onChange(of: scenePhase) { _, value in
            Task { if value == .background { await store.suspend() } else if value == .active { await store.resume(hosts: hosts) } }
        }
        .onDisappear { Task { await store.suspend() } }
        .overlay {
            if scenePhase != .active {
                ZStack { Color.black.ignoresSafeArea(); Image(systemName: "lock.fill").font(.title).foregroundStyle(.secondary) }.accessibilityLabel("Messages hidden")
            }
        }
    }

    private func row(_ conversation: AgentConversation) -> some View {
        let host = hosts.first { $0.id == conversation.profileID }
        return NavigationLink(value: conversation) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: conversation.provider == "claude" ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(conversation.provider == "claude" ? .orange : .mint).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title).font(.body.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(host?.displayName ?? "Removed host")
                        Text("/")
                        Text(conversation.provider.capitalized)
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !conversation.writable { Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Read-only history") }
                else if conversation.status == "working" { ProgressView().controlSize(.small) }
                else if conversation.status == "needsInput" { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange) }
            }.padding(.vertical, 5)
        }
        .accessibilityIdentifier("chat-row-\(conversation.conversationID)")
        .swipeActions(edge: .leading) {
            Button { store.favorite(conversation) } label: { Label("Star", systemImage: "star") }.tint(.orange)
        }
        .contextMenu {
            Button(store.archive.favorites.contains(conversation.id) ? "Unstar" : "Star", systemImage: "star") { store.favorite(conversation) }
        }
    }

    private var connectionSheet: some View {
        NavigationStack {
            List(hosts) { host in
                Button { Task { await store.connect(host) } } label: {
                    HStack {
                        VStack(alignment: .leading) { Text(host.displayName); Text(store.connections[host.id] ?? "Not connected").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                    }
                }.foregroundStyle(.primary)
            }
            .navigationTitle("Connections").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingServers = false } } }
            .modifier(AgentTrustPrompt(store: store))
        }
    }
}

private struct AgentNewConversationView: View {
    @Environment(\.dismiss) private var dismiss
    var store: AgentChatStore
    var hosts: [Host]
    var opened: (AgentConversation) -> Void
    @State private var hostID: UUID?
    @State private var provider = "codex"
    @State private var title = ""
    @State private var cwd = ""
    @State private var fullAccess = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Host", selection: $hostID) { ForEach(hosts) { Text($0.displayName).tag(Optional($0.id)) } }
                    Picker("Agent", selection: $provider) { Text("Codex").tag("codex"); Text("Claude").tag("claude") }.pickerStyle(.segmented)
                    TextField("Conversation name", text: $title).accessibilityIdentifier("chat-new-title")
                    TextField("Absolute project path", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if provider == "codex" { Section { Toggle("Full host permissions", isOn: $fullAccess) } footer: { Text("Codex can run commands and change files without approval on this host.") } }
                if let error = store.error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            }
            .navigationTitle("New conversation").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let host = hosts.first(where: { $0.id == hostID }) else { return }
                        busy = true
                        Task { if let c = await store.create(host: host, provider: provider, title: title, cwd: cwd) { opened(c) }; busy = false }
                    } label: { if busy { ProgressView() } else { Image(systemName: "checkmark") } }
                    .accessibilityLabel("Create conversation")
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !cwd.hasPrefix("/") || hostID == nil || (provider == "codex" && !fullAccess))
                }
            }.onAppear { hostID = hosts.first?.id }
        }.interactiveDismissDisabled(busy).modifier(AgentTrustPrompt(store: store))
    }
}

struct AgentConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AgentChatStore
    let conversation: AgentConversation
    let host: Host?
    @State private var voice = AgentVoiceController()
    @State private var atBottom = true
    @State private var scrollRequest = 0
    @AppStorage("agentMessageFontSize") private var size: Double = 16
    @AppStorage("agentVoiceQuietSeconds") private var quietSeconds = 2.5
    @State private var clearedDraft: String?
    @State private var pendingLink: URL?
    @State private var confirmingEnd = false
    @FocusState private var composerFocused: Bool

    private var history: AgentHistory { store.history(conversation) }
    private var draft: Binding<String> { Binding(get: { store.draft(conversation) }, set: { store.setDraft($0, for: conversation) }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.isConnected(conversation) ? Color.mint : Color.orange).frame(width: 6, height: 6)
                Text(host?.displayName ?? "Removed host").fontWeight(.medium)
                Text("/")
                Text(history.status ?? (conversation.writable ? "Offline" : "Read-only history"))
                Spacer(minLength: 0)
                if store.loading.contains(conversation.id) { ProgressView().controlSize(.mini) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            AgentTimeline(messages: history.messages, fontSize: size, atBottom: $atBottom, scrollRequest: scrollRequest,
                          canLoadOlder: history.before != nil, loadOlder: { Task { await store.load(conversation, older: true) } },
                          refresh: { Task { await store.load(conversation) } }, openLink: { pendingLink = $0 })
                .accessibilityIdentifier("chat-timeline")
                .overlay {
                    if history.messages.isEmpty {
                        VStack(spacing: 12) {
                            if store.loading.contains(conversation.id) {
                                ProgressView("Loading history")
                            } else if !store.isConnected(conversation) {
                                Label("Not connected", systemImage: "wifi.slash")
                            } else {
                                Text(history.before == nil ? "No recorded messages" : "No messages in this page")
                                if history.before != nil {
                                    Button("Earlier messages", systemImage: "arrow.up") { Task { await store.load(conversation, older: true) } }
                                }
                            }
                        }.font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
            if !atBottom || history.hasNewer == true {
                HStack {
                    Spacer()
                    Button {
                        Task { if history.hasNewer == true { await store.load(conversation, latest: true) }; scrollRequest += 1 }
                    } label: { Label("Latest", systemImage: "arrow.down") }.font(.caption.weight(.semibold))
                }.padding(.horizontal, 16).padding(.vertical, 6).background(.bar)
            }
            if let question = history.question {
                VStack(alignment: .leading, spacing: 8) {
                    Label(question.title, systemImage: "hand.raised").font(.headline)
                    ScrollView { Text(question.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    HStack {
                        Button("Deny", role: .destructive) { Task { await store.answer(question, in: conversation, allow: false) } }
                        Spacer()
                        Button("Allow once") { Task { await store.answer(question, in: conversation, allow: true) } }
                    }
                }.padding(12).background(.bar)
            }
            if store.archive.outbox[conversation.id]?.state == "unknown" {
                HStack {
                    Label("Delivery unknown", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { Task { await store.checkDelivery(conversation) } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Check delivery")
                }.padding(12)
            }
            if let error = voice.error ?? store.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(4)
                    Spacer(minLength: 0)
                    Button { voice.error = nil; store.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            if voice.isOn { voicePanel }
            Divider()
            if conversation.writable { composer }
            else { Label("Read-only history", systemImage: "lock").font(.caption).foregroundStyle(.secondary).padding(12) }
        }
        .navigationTitle(conversation.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(store.archive.favorites.contains(conversation.id) ? "Unstar" : "Star", systemImage: "star") { store.favorite(conversation) }
                    ControlGroup {
                        Button("Smaller text", systemImage: "textformat.size.smaller") { size = max(12, size - 2) }
                        Button("Larger text", systemImage: "textformat.size.larger") { size = min(26, size + 2) }
                    }
                    Button("Reconnect", systemImage: "arrow.clockwise") { if let host { Task { await store.connect(host); await store.load(conversation) } } }
                    if conversation.writable && !store.demo {
                        Button("End conversation", systemImage: "stop.circle", role: .destructive) { confirmingEnd = true }
                            .disabled(!store.isConnected(conversation) || history.status == "working" || history.status == "needsInput")
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Conversation options")
            }
        }
        .confirmationDialog("End \(conversation.title) on \(host?.displayName ?? "this host")?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End agent process", role: .destructive) { Task { voice.stop(); if await store.end(conversation) { dismiss() } } }
        } message: { Text("The conversation remains in history.") }
        .confirmationDialog("Open link", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }), titleVisibility: .visible) {
            if let url = pendingLink {
                Button("Open in browser") { UIApplication.shared.open(url); pendingLink = nil }
                Button("Copy link") { UIPasteboard.general.url = url; pendingLink = nil }
            }
        } message: { Text(pendingLink?.absoluteString ?? "") }
        .task(id: conversation.id) {
            store.active = conversation
            voice.onDraft = { store.setDraft($0, for: conversation) }
            voice.onSend = { text in
                guard store.canSend(conversation) else { store.setDraft(text, for: conversation); voice.stop(preserveDraft: false); return }
                store.setDraft(text, for: conversation)
                Task { await store.send(text, to: conversation); scrollRequest += 1; voice.receive(store.history(conversation), receipt: store.archive.outbox[conversation.id]?.state) }
            }
            if let host { await store.connect(host) }
            await store.load(conversation)
        }
        .onChange(of: history) { _, value in voice.receive(value, receipt: store.archive.outbox[conversation.id]?.state) }
        .onChange(of: store.archive.outbox[conversation.id]?.state) { _, value in voice.receive(history, receipt: value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && voice.phase != .permission) { voice.stop() }
        }
        .onDisappear {
            voice.stop(); voice.onSend = nil; voice.onDraft = nil
            if store.active?.id == conversation.id { store.active = nil }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                composerFocused = false
                if voice.isOn { voice.stop() }
                else {
                    Task {
                        if history.hasNewer == true { await store.load(conversation, latest: true) }
                        voice.start(target: conversation.id, afterSeq: history.messages.last?.seq ?? 0, quietSeconds: quietSeconds)
                    }
                }
            } label: { Image(systemName: voice.isOn ? "mic.slash.fill" : "mic.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(voice.isOn ? "Stop voice" : "Start voice")
                .disabled(!voice.isOn && (!store.canSend(conversation) || !draft.wrappedValue.isEmpty))
            TextField("Message", text: draft, axis: .vertical).lineLimit(1...6).padding(.vertical, 12)
                .focused($composerFocused).accessibilityIdentifier("chat-composer").disabled(voice.isOn)
            if !draft.wrappedValue.isEmpty && !voice.isOn {
                Button { clearedDraft = draft.wrappedValue; draft.wrappedValue = "" } label: { Image(systemName: "delete.left").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Clear draft")
            } else if let clearedDraft, !voice.isOn {
                Button { draft.wrappedValue = clearedDraft; self.clearedDraft = nil } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Undo clear draft")
            }
            if history.status == "working" || history.status == "needsInput" {
                Button { Task { await store.interrupt(conversation) } } label: { Image(systemName: "stop.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Interrupt agent")
            } else {
                Button { let text = draft.wrappedValue; Task { await store.send(text, to: conversation); scrollRequest += 1 } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Send message").accessibilityIdentifier("chat-send")
                    .disabled(!store.canSend(conversation) || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voice.isOn)
            }
        }.padding(.horizontal, 10).background(.bar)
    }
    private var voicePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: voice.phase == .speaking ? "speaker.wave.2.fill" : "waveform").foregroundStyle(.mint)
                Text(voice.phase.rawValue).font(.subheadline.weight(.semibold))
                if let countdown = voice.countdown { Text("\(countdown)").monospacedDigit().foregroundStyle(.secondary) }
                Spacer()
                if voice.phase == .speaking { Button { voice.skipSpeech() } label: { Image(systemName: "forward.end") }.accessibilityLabel("Skip speech") }
                Button { voice.stop() } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Cancel voice")
            }
            if !voice.transcript.isEmpty { Text(voice.transcript).font(.body).lineLimit(6).textSelection(.enabled) }
        }.padding(12).background(.bar)
    }
}

struct AgentTimeline: UIViewRepresentable {
    let messages: [AgentMessage]
    let fontSize: Double
    @Binding var atBottom: Bool
    let scrollRequest: Int
    let canLoadOlder: Bool
    let loadOlder: () -> Void
    let refresh: () -> Void
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITableView {
        let table = AgentTimelineTable(frame: .zero, style: .plain)
        table.backgroundColor = .clear; table.separatorStyle = .none
        table.keyboardDismissMode = .interactive
        table.estimatedRowHeight = 0
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.register(AgentMessageCell.self, forCellReuseIdentifier: "message")
        table.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 10, right: 0)
        let refresh = UIRefreshControl(); refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulled(_:)), for: .valueChanged)
        table.refreshControl = refresh
        context.coordinator.table = table
        table.geometryChanged = { [weak coordinator = context.coordinator] in coordinator?.geometryChanged() }
        return table
    }
    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        let old = coordinator.items
        coordinator.parent = self
        let resized = coordinator.width != table.bounds.width
        coordinator.width = table.bounds.width
        guard old != messages || previous.fontSize != fontSize || previous.scrollRequest != scrollRequest || resized else { return }
        if previous.scrollRequest != scrollRequest { coordinator.followLatest = true }
        let anchor = table.indexPathsForVisibleRows?.sorted().first
        let anchorID = anchor.flatMap { old.indices.contains($0.row) ? old[$0.row].id : nil }
        let delta = anchor.map { table.rectForRow(at: $0).minY - table.contentOffset.y } ?? 0
        coordinator.items = messages
        UIView.performWithoutAnimation {
            if old.map(\.id) == messages.map(\.id), previous.fontSize == fontSize, !resized {
                let changed = messages.indices.filter { messages[$0] != old[$0] }.map { IndexPath(row: $0, section: 0) }
                for path in changed { (table.cellForRow(at: path) as? AgentMessageCell)?.configure(messages[path.row], fontSize: fontSize, delegate: coordinator) }
                table.beginUpdates(); table.endUpdates()
            } else { table.reloadData() }
            table.layoutIfNeeded()
            if !messages.isEmpty && (old.isEmpty || coordinator.followLatest) {
                table.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false)
            } else if let anchorID, let row = messages.firstIndex(where: { $0.id == anchorID }) {
                table.setContentOffset(CGPoint(x: 0, y: table.rectForRow(at: IndexPath(row: row, section: 0)).minY - delta), animated: false)
            }
        }
        if old.isEmpty && !messages.isEmpty {
            DispatchQueue.main.async { [weak table] in
                guard let table, !table.isDragging else { return }
                table.layoutIfNeeded()
                table.scrollToRow(at: IndexPath(row: messages.count - 1, section: 0), at: .bottom, animated: false)
            }
        }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
        var parent: AgentTimeline
        var items: [AgentMessage] = []
        var width: CGFloat = 0
        var followLatest = true
        private var resizing = false
        private var heights: [String: (Int, CGFloat, Double, String, CGFloat)] = [:]
        private let sizing = UITextView()
        weak var table: UITableView?
        private var requestingOlder = false
        init(_ parent: AgentTimeline) {
            self.parent = parent
            super.init()
            sizing.isScrollEnabled = false
            sizing.textContainerInset = .zero
            sizing.textContainer.lineFragmentPadding = 0
            sizing.textContainer.lineBreakMode = .byWordWrapping
        }
        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            let item = items[indexPath.row]
            let width = max(1, tableView.bounds.width - 32)
            let category = tableView.traitCollection.preferredContentSizeCategory.rawValue
            if let cached = heights[item.id], cached.0 == item.text.hashValue, cached.1 == width, cached.2 == parent.fontSize, cached.3 == category { return cached.4 }
            let base = item.role == "tool" ? UIFont.monospacedSystemFont(ofSize: parent.fontSize - 2, weight: .regular) : UIFont.systemFont(ofSize: parent.fontSize)
            sizing.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
            sizing.text = item.text
            let height = ceil(sizing.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + UIFont.preferredFont(forTextStyle: .caption1).lineHeight + 27)
            heights[item.id] = (item.text.hashValue, width, parent.fontSize, category, height)
            if heights.count > 2000 { heights = heights.filter { key, _ in items.contains { $0.id == key } } }
            return height
        }
        func geometryChanged() {
            guard !resizing else { return }
            resizing = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.resizing = false
                guard !self.items.isEmpty else { return }
                if self.followLatest && !table.isDragging {
                    table.layoutIfNeeded()
                    table.scrollToRow(at: IndexPath(row: self.items.count - 1, section: 0), at: .bottom, animated: false)
                }
            }
        }
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as! AgentMessageCell
            cell.configure(items[indexPath.row], fontSize: parent.fontSize, delegate: self)
            return cell
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let table, let row = table.indexPathsForVisibleRows?.sorted().first(where: { table.rectForRow(at: $0).minY >= table.contentOffset.y + table.adjustedContentInset.top })?.row {
                table.accessibilityValue = "Message \(row + 1) of \(items.count)"
            }
            let bottom = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.adjustedContentInset.bottom < 64
            if scrollView.isDragging || scrollView.isDecelerating { followLatest = bottom }
            if parent.atBottom != bottom { DispatchQueue.main.async { [weak self] in self?.parent.atBottom = bottom } }
            if scrollView.isDragging, scrollView.contentOffset.y < 80, parent.canLoadOlder, !requestingOlder {
                requestingOlder = true; parent.loadOlder()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestingOlder = false }
            }
        }
        @objc func pulled(_ control: UIRefreshControl) { if parent.canLoadOlder { parent.loadOlder() } else { parent.refresh() }; control.endRefreshing() }
        private func safeURL(_ item: UITextItem) -> URL? {
            guard case .link(let url) = item.content, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
            return url
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard let url = safeURL(textItem) else { return nil }
            return UIAction { [weak self] _ in self?.parent.openLink(url) }
        }
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard let url = safeURL(textItem) else { return nil }
            let menu = UIMenu(children: [UIAction(title: "Open link", image: UIImage(systemName: "safari")) { [weak self] _ in self?.parent.openLink(url) },
                                        UIAction(title: "Copy link", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = url }])
            return UITextItem.MenuConfiguration(preview: nil, menu: menu)
        }
    }
}

private final class AgentTimelineTable: UITableView {
    var geometryChanged: (() -> Void)?
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        let changed = previousSize != bounds.size
        previousSize = bounds.size
        super.layoutSubviews()
        if changed { geometryChanged?() }
    }
}

private final class AgentMessageCell: UITableViewCell {
    private let heading = UILabel()
    private let message = UITextView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; selectionStyle = .none
        heading.font = .preferredFont(forTextStyle: .caption1); heading.adjustsFontForContentSizeCategory = true
        message.isEditable = false; message.isSelectable = true; message.isScrollEnabled = false
        message.backgroundColor = .clear; message.textContainerInset = .zero; message.textContainer.lineFragmentPadding = 0
        message.textContainer.lineBreakMode = .byWordWrapping
        message.dataDetectorTypes = [.link]; message.adjustsFontForContentSizeCategory = true
        message.linkTextAttributes = [.foregroundColor: UIColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
        let stack = UIStackView(arrangedSubviews: [heading, message]); stack.axis = .vertical; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ item: AgentMessage, fontSize: Double, delegate: UITextViewDelegate) {
        heading.text = item.role == "user" ? "You" : item.role == "assistant" ? "Agent" : item.role.capitalized
        if item.status == "streaming" { heading.text?.append(" / Working") }
        heading.textColor = item.role == "user" ? .systemTeal : .secondaryLabel
        let base = item.role == "tool" ? UIFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular) : UIFont.systemFont(ofSize: fontSize)
        message.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        message.textColor = item.role == "notice" ? .systemOrange : .label
        if message.text != item.text { message.text = item.text }
        message.delegate = delegate
        message.accessibilityIdentifier = "chat-message-\(item.id)"
    }
}
