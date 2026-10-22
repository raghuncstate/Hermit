import SwiftUI

@MainActor @Observable
final class AgentChatStore {
    private(set) var archive = AgentChatArchive()
    private(set) var connections: [UUID: String] = [:]
    var error: String?
    var trust: AgentTrustChallenge?
    var trustHost: Host?
    var active: AgentConversation?
    private(set) var loading = Set<String>()
    private(set) var sending = Set<String>()
    private var clients: [UUID: any AgentBridgeTransport] = [:]
    private let makeClient: @MainActor (Host) -> any AgentBridgeTransport
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTokens: [UUID: UUID] = [:]
    private var pendingRefresh = Set<UUID>()
    private var loadTokens: [String: UUID] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var file: URL?
    private var foreground = true
    private var lifecycle = UUID()
    private var heartbeat: Task<Void, Never>?
    private var storageUsable = true
    let demo: Bool

    init(demo: Bool = false, storageURL: URL? = nil,
         makeClient: @escaping @MainActor (Host) -> any AgentBridgeTransport = { AgentBridgeClient(host: $0) }) {
        self.demo = demo
        self.makeClient = makeClient
        if demo { seedDemo(); return }
        do {
            let folder = try storageURL?.deletingLastPathComponent() ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("AgentMessages", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var excluded = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            file = storageURL ?? folder.appendingPathComponent("messages-v1.json")
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count < 20_000_000 else { throw AgentChatError("Message cache exceeds the safe size limit") }
                archive = try JSONDecoder().decode(AgentChatArchive.self, from: data)
                guard archive.version == 1 else { throw AgentChatError("Unsupported message cache version") }
                for key in archive.outbox.keys where ["sending", "accepted", "working"].contains(archive.outbox[key]?.state ?? "") {
                    archive.outbox[key]?.state = "unknown"
                }
            }
        } catch {
            storageUsable = false
            self.error = "Messages storage could not be opened. Terminal is unaffected. \(error.localizedDescription)"
        }
    }

    var conversations: [AgentConversation] { archive.conversations.sorted { $0.updated > $1.updated } }
    func inboxConversations(includeCached: Bool = false) -> [AgentConversation] {
        conversations.filter { includeCached || $0.status != "cached" }
    }
    func history(_ conversation: AgentConversation) -> AgentHistory { archive.histories[conversation.id] ?? AgentHistory() }
    func draft(_ conversation: AgentConversation) -> String { archive.drafts[conversation.id] ?? "" }
    func setDraft(_ text: String, for conversation: AgentConversation) {
        archive.drafts[conversation.id] = text
        scheduleSave()
    }
    func favorite(_ conversation: AgentConversation) {
        if archive.favorites.contains(conversation.id) { archive.favorites.removeAll { $0 == conversation.id } }
        else { archive.favorites.insert(conversation.id, at: 0); archive.favorites = Array(archive.favorites.prefix(3)) }
        scheduleSave()
    }
    func isConnected(_ conversation: AgentConversation) -> Bool {
        if demo { return true }
        guard let client = clients[conversation.profileID] else { return false }
        return client.route == conversation.route && client.bridgeID == conversation.bridgeID && connections[conversation.profileID] == "Connected"
    }
    func canSend(_ conversation: AgentConversation) -> Bool {
        let descriptor = archive.conversations.first { $0.id == conversation.id } ?? conversation
        let status = history(conversation).status ?? descriptor.status
        let receipt = archive.outbox[conversation.id]?.state ?? ""
        return storageUsable && descriptor.writable && isConnected(conversation) && !sending.contains(conversation.id)
            && !["working", "needsInput", "starting", "unknown", "offline", "failed"].contains(status)
            && !["sending", "unknown", "accepted", "working"].contains(receipt)
    }

    func refresh(hosts: [Host]) async {
        guard !demo, foreground, storageUsable else { return }
        for host in hosts {
            guard !Task.isCancelled, foreground else { return }
            await connect(host)
        }
    }

    func connect(_ host: Host) async {
        guard !demo, foreground, storageUsable else { return }
        if let task = connectionTasks[host.id] { await task.value; return }
        let token = lifecycle
        let task = Task { [weak self] in await self?.connectNow(host, token: token) }
        let wrapper = Task<Void, Never> { await task.value }
        connectionTasks[host.id] = wrapper
        await wrapper.value
        if lifecycle == token { connectionTasks.removeValue(forKey: host.id) }
    }

    private func connectNow(_ host: Host, token: UUID) async {
        if let client = clients[host.id], client.route == AgentBridgeClient.route(for: host), connections[host.id] == "Connected" {
            do { _ = try await client.request("ping"); try await list(client); await reconcile(client); return }
            catch { await client.close() }
        }
        guard foreground, lifecycle == token else { return }
        connections[host.id] = "Connecting"
        let client = makeClient(host)
        refreshTasks.removeValue(forKey: host.id)?.cancel()
        refreshTokens.removeValue(forKey: host.id)
        pendingRefresh.remove(host.id)
        if let old = clients.updateValue(client, forKey: host.id) { await old.close() }
        do {
            try await client.connect(pins: archive.pins)
            guard foreground, lifecycle == token, clients[host.id] === client else { await client.close(); return }
            connections[host.id] = "Connected"
            client.onDisconnect = { [weak self, weak client] message in
                guard let self, let client, self.clients[host.id] === client else { return }
                self.connections[host.id] = "Offline"
                self.markUncertain(host.id)
                self.error = message
            }
            client.onChange = { [weak self, weak client] _ in
                guard let self, let client, self.clients[host.id] === client else { return }
                self.scheduleRefresh(client)
            }
            try await list(client)
            await reconcile(client)
            if let active, active.profileID == host.id { await load(active) }
        } catch let challenge as AgentTrustChallenge {
            guard lifecycle == token else { return }
            connections[host.id] = "Verify host"
            if trust == nil { trust = challenge; trustHost = host }
        } catch {
            guard lifecycle == token else { return }
            connections[host.id] = "Offline"
            self.error = "\(host.displayName): \(error.localizedDescription)"
        }
    }

    func acceptTrust(_ challenge: AgentTrustChallenge, host: Host) async {
        archive.pins[challenge.route] = challenge.publicKey
        do { try persist() }
        catch { self.error = error.localizedDescription; return }
        self.trust = nil; trustHost = nil
        await connect(host)
    }

    private func list(_ client: any AgentBridgeTransport, discover: Bool = true) async throws {
        let response = try await client.request("list", ["discover": .bool(discover)])
        guard foreground, clients[client.host.id] === client else { return }
        let rows = response["conversations"].array.compactMap { row -> AgentConversation? in
            guard let id = row["id"].string, let title = row["title"].string, let provider = row["provider"].string else { return nil }
            let updated: Double
            if case .number(let value) = row["updated"] { updated = value } else { updated = 0 }
            return AgentConversation(profileID: client.host.id, route: client.route, bridgeID: client.bridgeID,
                                     conversationID: id, title: title, provider: provider, cwd: row["cwd"].string ?? "",
                                     status: row["status"].string ?? "unknown", writable: row["writable"].boolean, updated: updated)
        }
        // Limited discovery is NOT proof an absent session was deleted. Retain cached rows offline.
        for index in archive.conversations.indices where archive.conversations[index].profileID == client.host.id {
            if !discover && archive.conversations[index].conversationID.hasPrefix("history:") { continue }
            archive.conversations[index].writable = false
            archive.conversations[index].status = "cached"
        }
        for row in rows {
            if let index = archive.conversations.firstIndex(where: { $0.id == row.id }) { archive.conversations[index] = row }
            else { archive.conversations.append(row) }
        }
        scheduleSave()
    }

    private func scheduleRefresh(_ client: any AgentBridgeTransport) {
        pendingRefresh.insert(client.host.id)
        guard refreshTasks[client.host.id] == nil else { return }
        let token = lifecycle
        let refreshToken = UUID()
        refreshTokens[client.host.id] = refreshToken
        refreshTasks[client.host.id] = Task { [weak self, weak client] in
            guard let self, let client else { return }
            defer {
                if self.lifecycle == token, self.refreshTokens[client.host.id] == refreshToken {
                    self.refreshTokens.removeValue(forKey: client.host.id)
                    self.refreshTasks.removeValue(forKey: client.host.id)
                    self.pendingRefresh.remove(client.host.id)
                }
            }
            while self.pendingRefresh.contains(client.host.id) {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, self.foreground, self.lifecycle == token,
                      self.clients[client.host.id] === client else { return }
                // Retain the invalidation while a user-initiated history page is loading.
                if let active = self.active, active.profileID == client.host.id, self.loading.contains(active.id) { continue }
                self.pendingRefresh.remove(client.host.id)
                if let active = self.active, active.profileID == client.host.id { await self.load(active) }
                guard self.foreground, self.lifecycle == token, self.clients[client.host.id] === client else { return }
                // Do not rescan every native transcript for each token delta.
                try? await self.list(client, discover: false)
                await self.reconcile(client)
            }
        }
    }

    func load(_ conversation: AgentConversation, older: Bool = false, latest: Bool = false) async {
        guard !demo, isConnected(conversation), let client = clients[conversation.profileID], !loading.contains(conversation.id) else { return }
        let token = UUID()
        loadTokens[conversation.id] = token
        loading.insert(conversation.id)
        defer {
            if loadTokens[conversation.id] == token { loadTokens.removeValue(forKey: conversation.id); loading.remove(conversation.id) }
        }
        var params: [String: AgentJSON] = ["conversation": .string(conversation.conversationID)]
        if older {
            guard let before = history(conversation).before else { return }
            params["before"] = .number(Double(before))
        }
        do {
            let response = try await client.request("history", params)
            guard foreground, clients[conversation.profileID] === client, loadTokens[conversation.id] == token,
                  isConnected(conversation) else { return }
            let value = try response.decode(AgentHistory.self)
            var existing = latest ? AgentHistory() : history(conversation)
            existing.merge(value, older: older)
            archive.histories[conversation.id] = existing
            trimHistoryCache()
            if let status = value.status, let index = archive.conversations.firstIndex(where: { $0.id == conversation.id }) {
                archive.conversations[index].status = status
            }
            scheduleSave()
        } catch {
            if foreground, clients[conversation.profileID] === client, loadTokens[conversation.id] == token { self.error = error.localizedDescription }
        }
    }

    func send(_ text: String, to conversation: AgentConversation) async {
        guard canSend(conversation), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.utf8.count <= 128 * 1024 else { error = "Message exceeds 128 KiB. Draft retained."; return }
        sending.insert(conversation.id); defer { sending.remove(conversation.id) }
        let receipt = AgentOutboxItem(requestID: UUID().uuidString, text: text, state: "sending")
        archive.outbox[conversation.id] = receipt
        do {
            try persist() // No network write before the target and request ID are durable.
            if demo { demoSend(text, conversation: conversation, requestID: receipt.requestID); return }
            guard let client = clients[conversation.profileID], isConnected(conversation) else { throw AgentChatError("Destination disconnected") }
            let result = try await client.request("send", ["conversation": .string(conversation.conversationID), "requestID": .string(receipt.requestID), "text": .string(text)])
            archive.outbox[conversation.id]?.state = result["status"].string ?? "unknown"
            if ["accepted", "working", "completed"].contains(result["status"].string ?? ""), draft(conversation) == text { archive.drafts[conversation.id] = "" }
            try persist()
            await load(conversation, latest: true)
        } catch let rejected as AgentRequestRejected {
            archive.outbox[conversation.id]?.state = "rejected"
            self.error = rejected.localizedDescription
            scheduleSave()
        } catch {
            archive.outbox[conversation.id]?.state = "unknown"
            self.error = error.localizedDescription
            scheduleSave()
        }
    }

    private func reconcile(_ client: any AgentBridgeTransport) async {
        for conversation in conversations where conversation.profileID == client.host.id && isConnected(conversation) {
            guard let receipt = archive.outbox[conversation.id], ["sending", "unknown", "accepted", "working"].contains(receipt.state) else { continue }
            do {
                let result = try await client.request("receipt", ["conversation": .string(conversation.conversationID), "requestID": .string(receipt.requestID)])
                guard foreground, clients[client.host.id] === client,
                      archive.outbox[conversation.id]?.requestID == receipt.requestID else { return }
                archive.outbox[conversation.id]?.state = result["status"].string ?? "unknown"
                if result["status"].string != "unknown", draft(conversation) == receipt.text { archive.drafts[conversation.id] = "" }
                scheduleSave()
            } catch { return }
        }
    }

    func checkDelivery(_ conversation: AgentConversation) async {
        guard let client = clients[conversation.profileID], isConnected(conversation) else { return }
        await reconcile(client); await load(conversation)
    }

    func interrupt(_ conversation: AgentConversation) async {
        guard let client = clients[conversation.profileID], isConnected(conversation), let requestID = history(conversation).requestID else { return }
        do { _ = try await client.request("interrupt", ["conversation": .string(conversation.conversationID), "requestID": .string(requestID)]) }
        catch { self.error = error.localizedDescription }
    }

    func end(_ conversation: AgentConversation) async -> Bool {
        guard let client = clients[conversation.profileID], isConnected(conversation) else { return false }
        do {
            _ = try await client.request("close", ["conversation": .string(conversation.conversationID)])
            try await list(client, discover: false)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func answer(_ question: AgentQuestion, in conversation: AgentConversation, allow: Bool) async {
        guard let client = clients[conversation.profileID], isConnected(conversation) else { return }
        do { _ = try await client.request("answer", ["conversation": .string(conversation.conversationID), "questionID": .string(question.id), "allow": .bool(allow)]); await load(conversation) }
        catch { self.error = error.localizedDescription }
    }

    func create(host: Host, provider: String, title: String, cwd: String) async -> AgentConversation? {
        await connect(host)
        guard let client = clients[host.id], connections[host.id] == "Connected" else { return nil }
        let key = host.id.uuidString + ":" + client.route
        let request = archive.creations?[key] ?? AgentCreationRequest(id: UUID().uuidString, bridgeID: client.bridgeID, provider: provider, title: title, cwd: cwd)
        guard request.bridgeID == client.bridgeID, request.provider == provider, request.title == title, request.cwd == cwd else {
            error = "An earlier creation is unresolved on this host. Reopen it with the same name, agent and directory to check its result."
            return nil
        }
        do {
            if archive.creations == nil { archive.creations = [:] }
            archive.creations?[key] = request
            try persist()
            let result = try await client.request("create", ["requestID": .string(request.id), "provider": .string(provider), "title": .string(title), "cwd": .string(cwd)])
            try await list(client)
            let conversation = conversations.first { $0.profileID == host.id && $0.route == client.route && $0.bridgeID == client.bridgeID && $0.conversationID == result["id"].string }
            guard let conversation else { throw AgentChatError("Creation is unresolved; reconnect before retrying") }
            archive.creations?.removeValue(forKey: key)
            try persist()
            return conversation
        } catch let rejected as AgentRequestRejected {
            archive.creations?.removeValue(forKey: key)
            scheduleSave(); error = rejected.localizedDescription; return nil
        } catch { self.error = error.localizedDescription; return nil }
    }

    func suspend() async {
        foreground = false
        lifecycle = UUID()
        heartbeat?.cancel(); heartbeat = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        do { try persist() } catch { self.error = error.localizedDescription }
        for task in refreshTasks.values { task.cancel() }; refreshTasks.removeAll()
        refreshTokens.removeAll()
        pendingRefresh.removeAll()
        loading.removeAll(); loadTokens.removeAll()
        for task in connectionTasks.values { task.cancel() }; connectionTasks.removeAll()
        let old = clients; clients.removeAll()
        // Publish all old state before awaiting any close; foreground reconnection may interleave.
        for id in old.keys { connections[id] = "Offline"; markUncertain(id) }
        for client in old.values { await client.close() }
    }
    func resume(hosts: [Host]) async {
        foreground = true
        if !demo && heartbeat == nil {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, !Task.isCancelled, self.foreground else { return }
                    for host in hosts {
                        guard !Task.isCancelled, self.foreground else { return }
                        if let client = self.clients[host.id], self.connections[host.id] == "Connected" {
                            do { _ = try await client.request("ping") }
                            catch {
                                guard self.foreground, self.clients[host.id] === client else { continue }
                                self.connections[host.id] = "Offline"; self.markUncertain(host.id); await client.close()
                            }
                        } else if self.connections[host.id] != "Verify host" { await self.connect(host) }
                    }
                }
            }
        }
        await refresh(hosts: hosts)
    }

    private func markUncertain(_ host: UUID) {
        for c in conversations where c.profileID == host {
            if ["sending", "accepted", "working"].contains(archive.outbox[c.id]?.state ?? "") { archive.outbox[c.id]?.state = "unknown" }
        }
        scheduleSave()
    }
    private func scheduleSave() {
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.persistenceTask = nil
            do { try self.persist() } catch { self.error = error.localizedDescription }
        }
    }
    func clearHistoryCache() {
        archive.histories.removeAll()
        scheduleSave()
    }
    private func trimHistoryCache() {
        let ordered = Array(Set(archive.histories.keys)).sorted { left, right in
            if left == right { return false }
            if left == active?.id { return true }
            if right == active?.id { return false }
            return (archive.conversations.first { $0.id == left }?.updated ?? 0) > (archive.conversations.first { $0.id == right }?.updated ?? 0)
        }
        var budget = 16 * 1024 * 1024
        for key in ordered {
            guard var history = archive.histories[key] else { continue }
            if key != active?.id {
                if history.messages.count > 50 { history.messages = Array(history.messages.suffix(50)); history.before = history.messages.first?.seq }
                history.question = nil
            }
            let bytes = history.messages.reduce(0) { $0 + $1.text.utf8.count + 512 }
            if bytes > budget { archive.histories.removeValue(forKey: key) }
            else { archive.histories[key] = history; budget -= bytes }
        }
    }
    private func persist() throws {
        guard storageUsable else { throw AgentChatError("Messages storage is unavailable; nothing was sent") }
        guard !demo, let file else { return }
        trimHistoryCache()
        var cache = archive
        let retained = Set(conversations.prefix(20).map(\.id)).union(archive.favorites).union(active.map { [$0.id] } ?? [])
        cache.histories = archive.histories.filter { retained.contains($0.key) }.mapValues { value in
            var history = value
            if history.messages.count > 50 { history.messages = Array(history.messages.suffix(50)); history.before = history.messages.first?.seq }
            history.question = nil
            return history
        }
        let data = try JSONEncoder().encode(cache)
        guard data.count < 20_000_000 else { throw AgentChatError("Message cache is full. Nothing was sent.") }
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    #if DEBUG && targetEnvironment(simulator)
    static var demoRequested: Bool { ProcessInfo.processInfo.arguments.contains("--agent-chat-demo") }
    #else
    static var demoRequested: Bool { false }
    #endif

    private func seedDemo() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--agent-chat-reset-test-preferences") {
            UserDefaults.standard.set(16.0, forKey: "agentMessageFontSize")
        }
        let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        for (index, title) in ["Release review", "Interface polish", "Build verification", "Release review"].enumerated() {
            let c = AgentConversation(profileID: index == 3 ? other : host, route: "fixture", bridgeID: "isolated-fixture", conversationID: "demo-\(index)", title: title, provider: index == 1 ? "claude" : "codex", cwd: "/tmp/hermit-ui-fixture", status: "ready", writable: index != 2, updated: Double(100 - index))
            archive.conversations.append(c)
            archive.histories[c.id] = AgentHistory(messages: [
                AgentMessage(id: "\(index)-1", role: "user", text: "Review the changes and show me what still needs testing.", status: "complete", seq: 1),
                AgentMessage(id: "\(index)-2", role: "assistant", text: "The conversation list is ready. Each destination keeps its own draft and delivery status.\n\nNext checks:\n- Background and reconnect\n- Long messages and wrapped links\n- Voice cancellation\n\nhttps://example.com/review/a-long-link-that-wraps-on-an-iphone-screen?case=history&view=messages", status: "complete", seq: 2),
                AgentMessage(id: "\(index)-3", role: "tool", text: "swift test\n12 checks passed", status: "complete", seq: 3)
            ], status: "ready")
            if index == 2 {
                archive.histories[c.id] = AgentHistory(messages: (1...300).map { line in
                    AgentMessage(id: "history-\(line)", role: line.isMultiple(of: 2) ? "assistant" : "user", text: "History line \(line)\nA stable, selectable message in a long conversation.", status: "complete", seq: line)
                }, status: "history")
            }
            if index < 3 { archive.favorites.append(c.id) }
        }
        if ProcessInfo.processInfo.arguments.contains("--agent-chat-history-regression") {
            for (index, title) in ["Saved Codex conversation", "Empty transcript", "Cached helper"].enumerated() {
                let c = AgentConversation(profileID: host, route: "fixture", bridgeID: "isolated-fixture", conversationID: "history:demo-\(index)", title: title, provider: "codex", cwd: "/tmp/hermit-ui-fixture", status: index == 2 ? "cached" : "history", writable: false, updated: Double(200 - index))
                archive.conversations.append(c)
                archive.histories[c.id] = AgentHistory(messages: index == 0 ? [
                    AgentMessage(id: "native-question", role: "user", text: "A saved question", status: "complete", seq: 1),
                    AgentMessage(id: "native-answer", role: "assistant", text: "A readable saved answer", status: "complete", seq: 2)
                ] : [], status: "history")
            }
            for index in 0..<50 {
                archive.conversations.append(AgentConversation(profileID: host, route: "fixture", bridgeID: "isolated-fixture", conversationID: "history:older-\(index)", title: "Older conversation \(index)", provider: "claude", cwd: "/tmp/hermit-ui-fixture", status: "history", writable: false, updated: Double(50 - index)))
            }
        }
        #endif
    }
    private func demoSend(_ text: String, conversation: AgentConversation, requestID: String) {
        #if DEBUG && targetEnvironment(simulator)
        var history = history(conversation)
        let next = (history.messages.last?.seq ?? 0) + 1
        history.messages.append(AgentMessage(id: requestID, role: "user", text: text, status: "complete", seq: next))
        history.messages.append(AgentMessage(id: UUID().uuidString, role: "assistant", text: "Fixture reply for \(conversation.title) on \(conversation.profileID.uuidString.prefix(8)). No agent or terminal was contacted.", status: "complete", seq: next + 1))
        archive.histories[conversation.id] = history
        archive.outbox[conversation.id]?.state = "completed"
        archive.drafts[conversation.id] = ""
        #endif
    }
}
