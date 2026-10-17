import XCTest
import Citadel
import Crypto
@testable import Hermit

final class AgentMessagingTests: XCTestCase {
    @MainActor func testOldDisconnectCannotOverwriteReconnectedHosts() async throws {
        let hosts = [Host(displayName: "One", hostname: "one.invalid", username: "fixture"),
                     Host(displayName: "Two", hostname: "two.invalid", username: "fixture")]
        let gate = AgentTestGate()
        var generation: [UUID: Int] = [:]
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = AgentChatStore(storageURL: location) { host in
            let client = AgentTestTransport(host: host)
            let old = generation[host.id, default: 0] == 0
            generation[host.id, default: 0] += 1
            if old { client.onClose = { await gate.wait() } }
            return client
        }
        await store.resume(hosts: hosts)
        let closing = Task { await store.suspend() }
        try await eventually { gate.entered }
        await store.resume(hosts: hosts)
        gate.release()
        await closing.value
        XCTAssertEqual(hosts.map { store.connections[$0.id] }, ["Connected", "Connected"])
        XCTAssertTrue(store.conversations.allSatisfy { store.isConnected($0) })
        await store.suspend()
    }

    @MainActor func testOldHistoryCannotReplaceNewConnectionSnapshot() async throws {
        let host = Host(displayName: "Fixture", hostname: "fixture.invalid", username: "fixture")
        let gate = AgentTestGate()
        var created = 0
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = AgentChatStore(storageURL: location) { host in
            created += 1
            let client = AgentTestTransport(host: host)
            if created == 1 {
                client.onHistory = { await gate.wait(); return AgentTestTransport.history("stale partial") }
            } else { client.onHistory = { AgentTestTransport.history("new complete reply") } }
            return client
        }
        await store.resume(hosts: [host])
        let conversation = try XCTUnwrap(store.conversations.first)
        store.active = conversation
        let oldLoad = Task { await store.load(conversation) }
        try await eventually { gate.entered }
        await store.suspend()
        await store.resume(hosts: [host])
        XCTAssertEqual(store.history(conversation).messages.last?.text, "new complete reply")
        gate.release()
        await oldLoad.value
        XCTAssertEqual(store.history(conversation).messages.last?.text, "new complete reply")
        XCTAssertFalse(store.loading.contains(conversation.id))
        await store.suspend()
    }

    @MainActor func testNotificationDuringHistoryLoadIsNotLost() async throws {
        let host = Host(displayName: "Fixture", hostname: "fixture.invalid", username: "fixture")
        let client = AgentTestTransport(host: host)
        let gate = AgentTestGate()
        var loads = 0
        client.onHistory = {
            loads += 1
            if loads == 1 { await gate.wait(); return AgentTestTransport.history("partial") }
            return AgentTestTransport.history("final reply")
        }
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = AgentChatStore(storageURL: location, makeClient: { _ in client })
        await store.resume(hosts: [host])
        let conversation = try XCTUnwrap(store.conversations.first)
        store.active = conversation
        let firstLoad = Task { await store.load(conversation) }
        try await eventually { gate.entered }
        client.onChange?(conversation.conversationID)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(loads, 1)
        gate.release()
        await firstLoad.value
        try await eventually { store.history(conversation).messages.last?.text == "final reply" }
        await store.suspend()
    }

    @MainActor private func eventually(_ check: () -> Bool) async throws {
        for _ in 0..<200 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for isolated async fixture")
        throw AgentChatError("Fixture timeout")
    }

    @MainActor func testSSHBridgeDirectJumpAndReconnect() async throws {
        #if targetEnvironment(simulator)
        let path = ProcessInfo.processInfo.environment["HERMIT_AGENT_TEST_CONFIG"] ?? ""
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Run with the isolated SSH fixture configuration") }
        struct Configuration: Decodable { var port: Int; var username: String; var privateKeyPath: String; var publicHostKey: [String]; var cwd: String; var live: Bool?; var provider: String? }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(config.port, 1024)
        let keyRef = "hermit-messages-test-" + UUID().uuidString
        let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: Data(contentsOf: URL(fileURLWithPath: config.privateKeyPath)))
        if config.live == true {
            let host = Host(displayName: "Isolated real agent test", hostname: "127.0.0.1", port: config.port, username: config.username, privateKeyRef: keyRef)
            try await exerciseLiveStore(host: host, key: privateKey, hostKey: config.publicHostKey.joined(separator: " "), cwd: config.cwd, provider: config.provider ?? "codex")
            return
        }
        for jump in [false, true] {
            let host = Host(displayName: "Isolated fixture", hostname: "127.0.0.1", port: config.port, username: config.username, privateKeyRef: keyRef,
                            jumpHost: jump ? SSHJumpHost(hostname: "127.0.0.1", port: config.port, username: config.username, privateKeyRef: keyRef) : nil)
            let client = AgentBridgeClient(host: host, authenticate: { username, _ in .ed25519(username: username, privateKey: privateKey) })
            var pins: [String: String] = [:]
            for _ in 0..<(jump ? 2 : 1) {
                do { try await client.connect(pins: pins); XCTFail("Unverified key was accepted") }
                catch let challenge as AgentTrustChallenge {
                    XCTAssertFalse(challenge.changed)
                    XCTAssertEqual(challenge.publicKey, config.publicHostKey.joined(separator: " "))
                    pins[challenge.route] = challenge.publicKey
                }
            }
            try await client.connect(pins: pins)
            let bridgeID = client.bridgeID
            let conversation = UUID().uuidString
            let created = try await client.request("create", ["requestID": .string(conversation), "provider": .string("codex"), "title": .string("SSH fixture"), "cwd": .string(config.cwd)])
            XCTAssertEqual(created["id"].string, conversation)
            let request = UUID().uuidString
            let params: [String: AgentJSON] = ["conversation": .string(conversation), "requestID": .string(request), "text": .string("literal\nmessage!")]
            _ = try await client.request("send", params)
            await client.close()
            try await Task.sleep(for: .seconds(1))
            try await client.connect(pins: pins)
            XCTAssertEqual(client.bridgeID, bridgeID)
            let duplicate = try await client.request("send", params)
            XCTAssertEqual(duplicate["status"].string, "completed")
            let history = try await client.request("history", ["conversation": .string(conversation)])
            let rows = try history.decode(AgentHistory.self).messages
            XCTAssertEqual(rows.filter { $0.role == "user" }.count, 1)
            XCTAssertEqual(rows.last?.text, "Hello world")
            await client.close()
            pins[client.route + ":target"] = "ssh-ed25519 invalid-test-key"
            do { try await client.connect(pins: pins); XCTFail("Changed key was accepted") }
            catch let challenge as AgentTrustChallenge { XCTAssertTrue(challenge.changed) }
            await client.close()
        }
        #endif
    }

    @MainActor private func exerciseLiveStore(host: Host, key: Curve25519.Signing.PrivateKey, hostKey: String, cwd: String, provider: String) async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.json")
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = AgentChatStore(storageURL: location) { host in
            AgentBridgeClient(host: host, authenticate: { username, _ in .ed25519(username: username, privateKey: key) })
        }
        var created: [AgentConversation] = []
        do {
            await store.resume(hosts: [host])
            let challenge = try XCTUnwrap(store.trust)
            XCTAssertEqual(challenge.publicKey, hostKey)
            await store.acceptTrust(challenge, host: host)
            XCTAssertEqual(store.connections[host.id], "Connected", store.error ?? "")
            for index in 1...2 {
                guard let conversation = await store.create(host: host, provider: provider, title: "Simulator live test \(index)", cwd: cwd) else {
                    XCTFail(store.error ?? "Live conversation creation failed")
                    throw AgentChatError("Live conversation creation failed")
                }
                created.append(conversation)
            }
            let first = created[0], second = created[1]
            XCTAssertNotEqual(first.id, second.id)
            let nonce = "hermit-" + UUID().uuidString.prefix(8)
            store.active = first
            await store.send("No tools, agents, or file access. Remember \(nonce). Reply with exactly \(nonce) and no punctuation.", to: first)
            let request = try XCTUnwrap(store.archive.outbox[first.id]?.requestID)
            await store.suspend()
            XCTAssertEqual(store.connections[host.id], "Offline")
            try await Task.sleep(for: .seconds(2))
            await store.resume(hosts: [host])
            try await liveReply(store, conversation: first)
            XCTAssertEqual(store.archive.outbox[first.id]?.requestID, request)
            XCTAssertEqual(store.history(first).messages.filter { $0.role == "user" }.count, 1)
            XCTAssertEqual(store.history(first).messages.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines), String(nonce))

            store.active = second
            await store.send("No tools, agents, or file access. Reply with exactly SECOND_CHANNEL and no punctuation.", to: second)
            try await liveReply(store, conversation: second)
            XCTAssertEqual(store.history(second).messages.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines), "SECOND_CHANNEL")
            XCTAssertFalse(store.history(second).messages.contains { $0.text.contains(nonce) })

            store.active = first
            await store.load(first)
            await store.send("No tools. What nonce did I ask you to remember? Reply only with that nonce.", to: first)
            try await liveReply(store, conversation: first)
            XCTAssertEqual(store.history(first).messages.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines), String(nonce))
            XCTAssertEqual(store.history(first).messages.filter { $0.role == "user" }.count, 2)
            XCTAssertFalse(store.history(first).messages.contains { $0.text.contains("SECOND_CHANNEL") })
            for conversation in created { let ended = await store.end(conversation); XCTAssertTrue(ended, store.error ?? "") }
            await store.suspend()
        } catch {
            for conversation in created {
                await store.load(conversation)
                await store.interrupt(conversation)
                try? await Task.sleep(for: .seconds(2))
                _ = await store.end(conversation)
            }
            await store.suspend()
            throw error
        }
    }

    @MainActor private func liveReply(_ store: AgentChatStore, conversation: AgentConversation) async throws {
        for _ in 0..<360 {
            let status = store.archive.outbox[conversation.id]?.state
            if status == "completed" {
                await store.load(conversation)
                XCTAssertTrue(store.canSend(conversation))
                return
            }
            if status == "failed" || status == "rejected" {
                throw AgentChatError(store.error ?? "Real provider rejected the test prompt")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AgentChatError("Real reply did not reconcile within three minutes")
    }
    func testFramesSplitAtEveryByteAndUnicode() throws {
        let expected = AgentJSON.object(["id": .string("abc"), "text": .string("multiline\n\u{4e2d}\u{00e9}"), "ok": .bool(true)])
        var data = try JSONEncoder().encode(expected); data.append(10)
        for offset in 0...data.count {
            var decoder = AgentFrameDecoder()
            let a = try decoder.append(data.prefix(offset))
            let b = try decoder.append(data.suffix(data.count - offset))
            XCTAssertEqual(a + b, [expected], "split \(offset)")
        }
    }
    func testMalformedAndOversizedFramesFailClosed() throws {
        var invalid = AgentFrameDecoder()
        XCTAssertThrowsError(try invalid.append(Data("{oops}\n".utf8)))
        var huge = AgentFrameDecoder()
        XCTAssertThrowsError(try huge.append(Data(repeating: 65, count: AgentFrameDecoder.limit + 1)))
    }
    func testVoiceNeverSendsDraftOrPartialOrWrongDestination() {
        var gate = AgentVoiceGate()
        XCTAssertNil(gate.finish(capture: UUID(), target: "A", text: "pasted text", final: true))
        let capture = gate.begin(target: "A")
        XCTAssertNil(gate.finish(capture: capture, target: "A", text: "partial", final: false))
        XCTAssertNil(gate.finish(capture: capture, target: "B", text: "final", final: true))
        XCTAssertEqual(gate.finish(capture: capture, target: "A", text: "  final!  ", final: true), "  final!  ")
        XCTAssertNil(gate.finish(capture: capture, target: "A", text: "duplicate callback", final: true))
    }
    func testVoiceCancellationAndOldCapture() {
        var gate = AgentVoiceGate()
        let old = gate.begin(target: "A")
        gate.cancel()
        XCTAssertNil(gate.finish(capture: old, target: "A", text: "late callback", final: true))
        let new = gate.begin(target: "A")
        XCTAssertNil(gate.finish(capture: old, target: "A", text: "old callback", final: true))
        XCTAssertNil(gate.finish(capture: new, target: "A", text: " \n", final: true))
        XCTAssertEqual(gate.finish(capture: new, target: "A", text: "current", final: true), "current")
    }
    func testSpeechDoesNotReadCodeLinksOrAuthentication() {
        let prose = AgentSpeechText.reply("The check passed.\n\n```bash\nrm -rf /example\n```\n\n[Review](https://example.com/private)")
        XCTAssertTrue(prose.contains("check passed"))
        XCTAssertFalse(prose.contains("rm -rf"))
        XCTAssertFalse(prose.contains("example.com"))
        XCTAssertFalse(AgentSpeechText.reply("Your device code is ABCD-EFGH").contains("ABCD"))
        XCTAssertFalse(AgentSpeechText.reply("The password is example").contains("example"))
        var gate = AgentVoiceGate()
        let capture = gate.begin(target: "A")
        XCTAssertEqual(gate.finish(capture: capture, target: "A", text: "Quote: send the message", final: true), "Quote: send the message")
    }
    func testHistoryMergesStableIDsWithoutDuplicateStreamingRows() {
        var history = AgentHistory(messages: [AgentMessage(id: "a", role: "assistant", text: "hel", status: "streaming", seq: 2)], before: 2)
        history.merge(AgentHistory(messages: [AgentMessage(id: "a", role: "assistant", text: "hello", status: "complete", seq: 2)], status: "ready"), older: false)
        history.merge(AgentHistory(messages: [AgentMessage(id: "old", role: "user", text: "prompt", status: "complete", seq: 1)]), older: true)
        XCTAssertEqual(history.messages.map(\.id), ["old", "a"])
        XCTAssertEqual(history.messages.last?.text, "hello")
        XCTAssertEqual(history.status, "ready")
        XCTAssertNil(history.before)
    }
    func testOlderHistoryWindowDoesNotThrowAwayRequestedPage() {
        var history = AgentHistory(messages: (101...1600).map { AgentMessage(id: "m\($0)", role: "user", text: "line", status: "complete", seq: $0) }, before: 101)
        history.merge(AgentHistory(messages: (1...100).map { AgentMessage(id: "m\($0)", role: "user", text: "older", status: "complete", seq: $0) }), older: true)
        XCTAssertEqual(history.messages.first?.seq, 1)
        XCTAssertEqual(history.messages.count, 1500)
        XCTAssertEqual(history.hasNewer, true)
        history.merge(AgentHistory(messages: [AgentMessage(id: "latest", role: "assistant", text: "new output", status: "complete", seq: 1601)], status: "ready"), older: false)
        XCTAssertEqual(history.messages.first?.seq, 1)
        XCTAssertFalse(history.messages.contains { $0.id == "latest" })
        XCTAssertEqual(history.status, "ready")
    }
    @MainActor func testRouteIncludesJumpPortUserAndKeyReference() {
        var host = Host(displayName: "Same title", hostname: "127.0.0.1", port: 22221, username: "u", privateKeyRef: "k", jumpHost: SSHJumpHost(hostname: "jump", username: "j"))
        let initial = AgentBridgeClient.route(for: host)
        host.displayName = "Renamed"
        XCTAssertEqual(initial, AgentBridgeClient.route(for: host))
        host.port = 22220
        XCTAssertNotEqual(initial, AgentBridgeClient.route(for: host))
        host.port = 22221; host.jumpHost?.hostname = "another"
        XCTAssertNotEqual(initial, AgentBridgeClient.route(for: host))
    }
    @MainActor func testGlobalIdentityAndDraftIsolation() async {
        let store = AgentChatStore(demo: true)
        let first = store.conversations[0]
        let second = store.conversations[3]
        XCTAssertEqual(first.title, second.title)
        XCTAssertNotEqual(first.id, second.id)
        store.setDraft("first draft", for: first)
        store.setDraft("second draft", for: second)
        await store.send("first draft", to: first)
        XCTAssertEqual(store.draft(first), "")
        XCTAssertEqual(store.draft(second), "second draft")
        XCTAssertFalse(store.history(second).messages.contains { $0.text == "first draft" })
    }
    @MainActor func testFavoritesCappedAtThreeAndReadonlySendDisabled() {
        let store = AgentChatStore(demo: true)
        store.favorite(store.conversations[3])
        XCTAssertEqual(store.archive.favorites.count, 3)
        XCTAssertFalse(store.canSend(store.conversations[2]))
    }
}

@MainActor private final class AgentTestGate {
    var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor private final class AgentTestTransport: AgentBridgeTransport {
    let host: Host
    let bridgeID = "isolated-unit-fixture"
    var route: String { AgentBridgeClient.route(for: host) }
    var onChange: ((String?) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onClose: (() async -> Void)?
    var onHistory: (() async -> AgentJSON)?
    init(host: Host) { self.host = host }
    func connect(pins: [String: String]) async throws {}
    func close() async { await onClose?() }
    func request(_ method: String, _ params: [String: AgentJSON]) async throws -> AgentJSON {
        if method == "list" {
            return .object(["conversations": .array([.object([
                "id": .string("conversation"), "title": .string("Fixture"), "provider": .string("codex"),
                "cwd": .string("/tmp/fixture"), "status": .string("ready"), "writable": .bool(true), "updated": .number(1)
            ])])])
        }
        if method == "history" { return await onHistory?() ?? Self.history("reply") }
        return .object([:])
    }
    static func history(_ text: String) -> AgentJSON {
        .object(["messages": .array([.object(["id": .string("response"), "role": .string("assistant"), "text": .string(text), "seq": .number(1), "status": .string("complete")])]), "partial": .bool(false), "status": .string("ready")])
    }
}
