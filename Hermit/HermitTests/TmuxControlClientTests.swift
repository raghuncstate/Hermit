import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import Hermit

// Command-line macOS tests only. The runner supplies ephemeral keys and a forced
// loopback sshd which cannot execute commands against a production tmux socket.
final class TmuxControlClientTests: XCTestCase {
    struct Fixture: Decodable {
        let port: Int
        let username: String
        let key: String
        let tmux: String
        let socket: String
        let serverPID: Int
        let panes: String
        let sessions: String
        let clients: Int
        let clientPIDs: String
        let descriptors: Int
    }

    private var fixture: Fixture!
    private var clients: [TmuxControlClient] = []
    private var transports: [SSHClientConnection] = []

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["HERMIT_CONTROL_FIXTURE"] else {
            throw XCTSkip("Requires the isolated command-line fixture runner")
        }
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(fixture.socket.hasPrefix("hermit-control-test-"))
    }

    override func tearDown() async throws {
        guard fixture != nil else { return }
        for client in clients { await client.disconnect() }
        for connection in transports { await connection.close() }
        try await assertBaseline()
    }

    private func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Fixture command failed: \(args.first ?? "")")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tmux(_ args: [String]) throws -> String {
        try run(fixture.tmux, ["-L", fixture.socket] + args)
    }

    private func countClients() throws -> Int {
        try tmux(["list-clients", "-F", "#{client_pid}"]).split(separator: "\n").count
    }

    private func assertBaseline(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if try countClients() == fixture.clients { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try countClients(), fixture.clients, file: file, line: line)
        XCTAssertEqual(try tmux(["list-clients", "-F", "#{client_pid}"]), fixture.clientPIDs, "Unrelated fixture client was replaced", file: file, line: line)
        XCTAssertEqual(try tmux(["display-message", "-p", "#{pid}"]), String(fixture.serverPID), file: file, line: line)
        XCTAssertEqual(try tmux(["list-panes", "-a", "-F", "#{session_id}|#{window_id}|#{pane_id}|#{pane_pid}"]), fixture.panes, file: file, line: line)
        XCTAssertEqual(try tmux(["list-sessions", "-F", "#{session_id}|#{session_name}"]), fixture.sessions, file: file, line: line)
        try await Task.sleep(for: .milliseconds(40))
        let descriptors = try run("/usr/sbin/lsof", ["-a", "-p", String(fixture.serverPID), "-Ff"])
            .split(separator: "\n").filter { $0.first == "f" && Int($0.dropFirst()) != nil }.count
        XCTAssertLessThanOrEqual(descriptors, fixture.descriptors, "Server FDs leaked", file: file, line: line)
    }

    private func makeClient() async throws -> (TmuxControlClient, SSHClientConnection) {
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: Data(contentsOf: URL(fileURLWithPath: fixture.key)))
        let ssh = try await SSHClient.connect(host: "127.0.0.1", port: fixture.port,
                                             authenticationMethod: .ed25519(username: fixture.username, privateKey: key),
                                             hostKeyValidator: .acceptAnything(), reconnect: .never)
        let connection = SSHClientConnection(client: ssh, jumpClient: nil, localPortForwarders: [])
        let client = TmuxControlClient(connection: connection, timeouts: .init(startup: .milliseconds(500), command: .milliseconds(350), detach: .milliseconds(200)))
        clients.append(client)
        transports.append(connection)
        return (client, connection)
    }

    private func start(_ client: TmuxControlClient, session: String = "fixture") async throws {
        try await client.start(sessionName: session, socketName: fixture.socket, tmuxCommand: fixture.tmux)
    }

    func testRepeatedGracefulDisconnectPreservesPanesAndForeignClient() async throws {
        for _ in 0..<20 {
            let (client, _) = try await makeClient()
            try await start(client)
            let text = try await client.send("display-message -p 'roundtrip'")
            XCTAssertEqual(text, "roundtrip")
            await client.disconnect()
            let acknowledged = await client.receivedExitAcknowledgement
            XCTAssertTrue(acknowledged, "Normal disconnect must read tmux exit before closing SSH")
            try await assertBaseline()
        }
    }

    func testConcurrentDisconnectJoinsOneTeardown() async throws {
        let (client, _) = try await makeClient()
        try await start(client)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await client.disconnect() } }
        }
        do { _ = try await client.send("display-message -p unexpected"); XCTFail("Closed client accepted a command") } catch {}
        do { try await start(client); XCTFail("Closed client restarted") } catch {}
    }

    func testStartupTimeoutClosesTransportWithoutExternalDisconnect() async throws {
        let (client, _) = try await makeClient()
        do { try await start(client, session: "silent-start"); XCTFail("Expected startup timeout") }
        catch { XCTAssertEqual(error as? TmuxProtocolError, .startupTimedOut) }
        try await assertBaseline()
    }

    func testCancellationDuringStartupCleansUpImmediately() async throws {
        let (client, _) = try await makeClient()
        let task = Task { try await start(client, session: "silent-start") }
        for _ in 0..<50 {
            if try countClients() > fixture.clients { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled startup succeeded") } catch {}
        try await assertBaseline()
    }

    func testFailedExecClosesTransport() async throws {
        let (client, _) = try await makeClient()
        do {
            try await client.start(sessionName: "fixture", socketName: fixture.socket, tmuxCommand: "/hermit-fixture-missing-tmux")
            XCTFail("Expected exec failure")
        } catch {}
        await client.disconnect()
    }

    func testCommandTimeoutClosesClientWithMissingDetachAck() async throws {
        let (client, _) = try await makeClient()
        try await start(client, session: "silent-replies")
        do { _ = try await client.send("display-message -p once"); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? TmuxProtocolError, .commandTimedOut) }
        try await assertBaseline()
    }

    func testTransportFailureResolvesPendingCommandAndReleasesClient() async throws {
        let (client, connection) = try await makeClient()
        try await start(client, session: "silent-replies")
        let sending = Task { try await client.send("display-message -p once") }
        try await Task.sleep(for: .milliseconds(40))
        await connection.close()
        do { _ = try await sending.value; XCTFail("Expected transport failure") } catch {}
        await client.disconnect()
    }

    func testRemoteDetachWithReasonFinishesEvents() async throws {
        let (client, _) = try await makeClient()
        try await start(client)
        let reading = Task {
            var exited = false
            for await event in client.events { if event == .exit { exited = true } }
            return exited
        }
        _ = try? await client.send("detach-client")
        let exited = await reading.value
        XCTAssertTrue(exited)
        await client.disconnect()
    }

    func testQueuedCommandsResolveDuringDisconnect() async throws {
        let (client, _) = try await makeClient()
        try await start(client, session: "silent-replies")
        let sends = (0..<20).map { index in Task { try? await client.send("display-message -p \(index)") } }
        try await Task.sleep(for: .milliseconds(30))
        await client.disconnect()
        for task in sends { _ = await task.value }
    }

    func testPortForwardFailureRollsBackTransportsAndEarlierListener() async throws {
        let (_, target) = try await makeClient()
        let (_, jump) = try await makeClient()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
        let reserved = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let occupied = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let freePort = try XCTUnwrap(reserved.localAddress?.port)
        let occupiedPort = try XCTUnwrap(occupied.localAddress?.port)
        try await reserved.close().get()
        do {
            _ = try await SSHConnectionManager.finishConnectionSetup(client: target.client, jumpClient: jump.client, forwards: [
                LocalPortForward(localPort: freePort, remotePort: 22),
                LocalPortForward(localPort: occupiedPort, remotePort: 22),
            ])
            XCTFail("Expected address-in-use failure")
        } catch {}
        XCTAssertFalse(target.client.isConnected)
        XCTAssertFalse(jump.client.isConnected)
        let reopened = try await bootstrap.bind(host: "127.0.0.1", port: freePort).get()
        try await reopened.close().get()
        try await occupied.close().get()
        try await group.shutdownGracefully()
    }

    func testCancelledConnectionSetupClosesTargetAndJump() async throws {
        let (_, target) = try await makeClient()
        let (_, jump) = try await makeClient()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SSHConnectionManager.finishConnectionSetup(client: target.client, jumpClient: jump.client, forwards: [])
        }
        do { _ = try await task.value; XCTFail("Cancelled setup succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected setup error: \(error)") }
        XCTAssertFalse(target.client.isConnected)
        XCTAssertFalse(jump.client.isConnected)
    }

    @MainActor
    func testWorkspaceBackgroundForegroundCyclesPreservePanes() async throws {
        let model = TmuxWorkspaceModel(host: Host(displayName: "fixture", hostname: "127.0.0.1", username: fixture.username)) { _ in
            let (client, _) = try await self.makeClient()
            try await self.start(client)
            return client
        }
        for _ in 0..<10 {
            await model.activate()
            XCTAssertEqual(model.status, .connected)
            XCTAssertEqual(try countClients(), fixture.clients + 1)
            model.suspend()
            await model.disconnect()
            try await assertBaseline()
        }
    }

    @MainActor
    func testDroppingWorkspaceOwnerClosesItsClient() async throws {
        let (client, _) = try await makeClient()
        try await start(client)
        var model: TmuxWorkspaceModel? = TmuxWorkspaceModel(host: Host(displayName: "fixture", hostname: "127.0.0.1", username: fixture.username)) { _ in client }
        await model?.activate()
        weak var released = model
        model = nil
        XCTAssertNil(released)
        try await assertBaseline()
    }
}
