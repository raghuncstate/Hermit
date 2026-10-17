import Foundation
import Citadel
import CryptoKit
import NIOCore
import NIOSSH

struct AgentTrustChallenge: LocalizedError, Identifiable {
    let route: String
    let endpoint: String
    let publicKey: String
    let changed: Bool
    var id: String { route }
    var fingerprint: String {
        let parts = publicKey.split(separator: " ")
        guard parts.count >= 2, let data = Data(base64Encoded: String(parts[1])) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    var errorDescription: String? { changed ? "SSH host key changed. Verify the new fingerprint." : "Verify this SSH host before connecting." }
}

private final class AgentKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let route: String
    let endpoint: String
    let expected: String?
    private let lock = NSLock()
    private var failure: AgentTrustChallenge?
    init(route: String, endpoint: String, expected: String?) { self.route = route; self.endpoint = endpoint; self.expected = expected }
    var challenge: AgentTrustChallenge? { lock.lock(); defer { lock.unlock() }; return failure }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let actual = String(openSSHPublicKey: hostKey)
        if actual == expected { validationCompletePromise.succeed(()); return }
        let error = AgentTrustChallenge(route: route, endpoint: endpoint, publicKey: actual, changed: expected != nil)
        lock.lock(); failure = error; lock.unlock()
        validationCompletePromise.fail(error)
    }
}

@MainActor
protocol AgentBridgeTransport: AnyObject {
    var host: Host { get }
    var route: String { get }
    var bridgeID: String { get }
    var onChange: ((String?) -> Void)? { get set }
    var onDisconnect: ((String) -> Void)? { get set }
    func connect(pins: [String: String]) async throws
    func request(_ method: String, _ params: [String: AgentJSON]) async throws -> AgentJSON
    func close() async
}

extension AgentBridgeTransport {
    func request(_ method: String) async throws -> AgentJSON { try await request(method, [:]) }
}

@MainActor
final class AgentBridgeClient: AgentBridgeTransport {
    let host: Host
    let route: String
    private(set) var bridgeID = ""
    var onChange: ((String?) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connection: SSHClientConnection?
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<AgentJSON, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var generation = UUID()
    private let authenticate: (String, String) throws -> SSHAuthenticationMethod

    init(host: Host, authenticate: @escaping (String, String) throws -> SSHAuthenticationMethod = { try SSHConnectionManager.authenticationMethod(username: $0, privateKeyRef: $1) }) {
        self.host = host; route = Self.route(for: host); self.authenticate = authenticate
    }
    static func route(for host: Host) -> String {
        let fields = [host.hostname, String(host.port), host.username, host.privateKeyRef,
                      host.jumpHost?.hostname ?? "", String(host.jumpHost?.port ?? 0),
                      host.jumpHost?.username ?? "", host.jumpHost?.privateKeyRef ?? ""]
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func connect(pins: [String: String]) async throws {
        await close()
        let token = generation
        let target = AgentKeyValidator(route: route + ":target", endpoint: "\(host.hostname):\(host.port)", expected: pins[route + ":target"])
        let auth = try authenticate(host.username, host.privateKeyRef)
        let targetSettings = SSHClientSettings(host: host.hostname, port: host.port,
                                              authenticationMethod: { auth }, hostKeyValidator: .custom(target))
        var jumpClient: SSHClient?
        var jumpValidator: AgentKeyValidator?
        do {
            let client: SSHClient
            if let jump = host.jumpHost {
                let validator = AgentKeyValidator(route: route + ":jump", endpoint: "\(jump.hostname):\(jump.port)", expected: pins[route + ":jump"])
                jumpValidator = validator
                let auth = try authenticate(jump.username, jump.privateKeyRef.isEmpty ? host.privateKeyRef : jump.privateKeyRef)
                let settings = SSHClientSettings(host: jump.hostname, port: jump.port,
                                                 authenticationMethod: { auth }, hostKeyValidator: .custom(validator))
                let jumpSSH = try await SSHClient.connect(to: settings)
                jumpClient = jumpSSH
                client = try await jumpSSH.jump(to: targetSettings)
            } else {
                client = try await SSHClient.connect(to: targetSettings)
            }
            guard generation == token else { try? await client.close(); try? await jumpClient?.close(); throw CancellationError() }
            // A separate channel/connection deliberately owns NO terminal port forwards.
            connection = SSHClientConnection(client: client, jumpClient: jumpClient, localPortForwarders: [])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                task = Task { [weak self] in
                    do {
                        try await client.withExec("exec \"$HOME/.local/bin/hermit-agent-bridge\" connect") { inbound, outbound in
                            guard let self, self.generation == token else { throw CancellationError() }
                            self.writer = outbound
                            self.ready?.resume(); self.ready = nil
                            var decoder = AgentFrameDecoder()
                            for try await part in inbound {
                                guard self.generation == token else { throw CancellationError() }
                                if case .stdout(let buffer) = part {
                                    for frame in try decoder.append(Data(buffer.readableBytesView)) { self.receive(frame) }
                                }
                            }
                        }
                        throw AgentChatError("Bridge disconnected. Verify the host service is installed and running.")
                    } catch {
                        guard let self, self.generation == token else { return }
                        self.failed(error)
                    }
                }
            }
            let hello = try await request("hello")
            guard hello["version"].integer == 1, let id = hello["hostID"].string, !id.isEmpty else {
                throw AgentChatError("Unsupported host bridge version")
            }
            bridgeID = id
        } catch {
            try? await jumpClient?.close()
            await close()
            throw jumpValidator?.challenge ?? target.challenge ?? error
        }
    }

    func request(_ method: String, _ params: [String: AgentJSON] = [:]) async throws -> AgentJSON {
        guard let writer else { throw AgentChatError("Not connected; draft retained") }
        let id = UUID().uuidString
        var parameters = params
        if method != "hello" { parameters["hostID"] = .string(bridgeID) }
        var data = try JSONEncoder().encode(AgentJSON.object(["id": .string(id), "method": .string(method), "params": .object(parameters)]))
        guard data.count < AgentFrameDecoder.limit else { throw AgentChatError("Message is too large") }
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(40))
                guard !Task.isCancelled else { return }
                self?.complete(id, .failure(AgentChatError("Response timed out. Delivery is unknown; no message was resent.")))
            }
            Task { [weak self] in
                do { try await writer.write(ByteBuffer(bytes: data)) }
                catch { self?.complete(id, .failure(error)) }
            }
        }
    }

    private func receive(_ frame: AgentJSON) {
        if let id = frame["id"].string {
            if let error = frame["error"].string {
                complete(id, .failure(frame["rejected"].boolean ? AgentRequestRejected(message: error) : AgentChatError(error)))
            }
            else { complete(id, .success(frame["result"])) }
        } else if frame["method"].string == "changed" || frame["method"].string == "resync" {
            onChange?(frame["conversation"].string)
        }
    }
    private func complete(_ id: String, _ result: Result<AgentJSON, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func failed(_ error: Error) {
        ready?.resume(throwing: error); ready = nil; writer = nil
        for id in Array(pending.keys) { complete(id, .failure(error)) }
        onDisconnect?(error.localizedDescription)
    }
    func close() async {
        generation = UUID()
        onDisconnect = nil
        failed(AgentChatError("Connection closed; unresolved sends will be checked, not replayed."))
        task?.cancel(); task = nil
        let old = connection; connection = nil; bridgeID = ""
        await old?.close()
    }
}
