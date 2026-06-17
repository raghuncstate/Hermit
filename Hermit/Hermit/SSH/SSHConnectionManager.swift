import Foundation
import Citadel
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import os

private let logger = Logger(subsystem: "com.zeromissionllc.hermit", category: "SSH")
private let portForwardLogger = Logger(subsystem: "com.zeromissionllc.hermit", category: "PortForward")

final class LocalPortForwarder {
    private let forward: LocalPortForward
    private var listenChannel: Channel?

    init(forward: LocalPortForward) {
        self.forward = forward
    }

    func start(using sshClient: SSHClient) async throws {
        guard listenChannel == nil else { return }

        let bootstrap = ServerBootstrap(group: sshClient.eventLoop)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [forward] inboundChannel in
                inboundChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                    let promise = inboundChannel.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        try await Self.openForward(
                            forward,
                            inboundChannel: inboundChannel,
                            using: sshClient
                        )
                    }
                    return promise.futureResult
                }
            }

        listenChannel = try await bootstrap
            .bind(host: forward.localHost, port: forward.localPort)
            .get()

        portForwardLogger.info(
            "Listening on \(self.forward.localHost):\(self.forward.localPort) and forwarding to \(self.forward.remoteHost):\(self.forward.remotePort)"
        )
    }

    func stop() async {
        guard let listenChannel else { return }
        self.listenChannel = nil
        try? await listenChannel.close().get()
    }

    private static func openForward(
        _ forward: LocalPortForward,
        inboundChannel: Channel,
        using sshClient: SSHClient
    ) async throws {
        let originatorAddress = try inboundChannel.remoteAddress ?? SocketAddress(
            ipAddress: forward.localHost,
            port: forward.localPort
        )

        _ = try await sshClient.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: forward.remoteHost,
                targetPort: forward.remotePort,
                originatorAddress: originatorAddress
            )
        ) { outboundChannel in
            let (localGlue, remoteGlue) = PortForwardGlueHandler.matchedPair()
            return outboundChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                outboundChannel.pipeline.addHandlers([
                    remoteGlue,
                    PortForwardErrorHandler()
                ])
            }.flatMap {
                inboundChannel.pipeline.addHandlers([
                    localGlue,
                    PortForwardErrorHandler()
                ])
            }
        }
    }
}

private final class PortForwardErrorHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        portForwardLogger.error("Port forward channel error: \(error.localizedDescription)")
        context.close(promise: nil)
    }
}

private final class PortForwardGlueHandler {
    private var partner: PortForwardGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (PortForwardGlueHandler, PortForwardGlueHandler) {
        let first = PortForwardGlueHandler()
        let second = PortForwardGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension PortForwardGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

struct SSHClientConnection {
    let client: SSHClient
    let jumpClient: SSHClient?
    let localPortForwarders: [LocalPortForwarder]

    func close() async {
        for forwarder in localPortForwarders {
            await forwarder.stop()
        }
        try? await client.close()
        try? await jumpClient?.close()
    }
}

@Observable
final class SSHConnectionManager {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    var state: ConnectionState = .disconnected
    var onDataReceived: ((String) -> Void)?
    var terminalCols: Int = 80
    var terminalRows: Int = 24

    private var connection: SSHClientConnection?
    private var stdinWriter: TTYStdinWriter?
    private var connectionTask: Task<Void, Never>?

    func connect(host: Host, tmuxSessionName: String?) async {
        state = .connecting

        do {
            logger.info("Connecting to \(host.hostname):\(host.port) as \(host.username)")
            let connection = try await Self.connectClient(for: host)
            let sshClient = connection.client
            self.connection = connection
            state = .connected

            let command: String
            if let tmux = tmuxSessionName {
                command = TmuxLaunchCommand.interactive(
                    sessionName: tmux,
                    socketName: host.tmuxSocketName,
                    tmuxCommand: host.tmuxCommand
                )
            } else {
                command = ""
            }

            try await sshClient.withPTY(
                .init(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: terminalCols,
                    terminalRowHeight: terminalRows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([:])
                )
            ) { [weak self] inbound, outbound in
                self?.stdinWriter = outbound

                // Send tmux attach command if specified
                if !command.isEmpty {
                    var buf = ByteBufferAllocator().buffer(capacity: command.utf8.count + 1)
                    buf.writeString(command + "\n")
                    try await outbound.write(buf)
                }

                for try await event in inbound {
                    switch event {
                    case .stdout(let buffer):
                        if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            await MainActor.run {
                                self?.onDataReceived?(str)
                            }
                        }
                    case .stderr(let buffer):
                        if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) {
                            await MainActor.run {
                                self?.onDataReceived?(str)
                            }
                        }
                    }
                }
            }
        } catch {
            logger.error("SSH connection failed: \(error)")
            await MainActor.run {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        guard let writer = stdinWriter else { return }
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func send(data: String) {
        let hex = data.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.info("send() data='\(data)' hex=[\(hex)]")
        guard let writer = stdinWriter else {
            logger.warning("send() called but stdinWriter is nil")
            return
        }
        Task {
            var buf = ByteBufferAllocator().buffer(capacity: data.utf8.count)
            buf.writeString(data)
            try? await writer.write(buf)
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        stdinWriter = nil
        Task {
            await connection?.close()
            connection = nil
        }
        state = .disconnected
    }

    static func connectClient(for host: Host) async throws -> SSHClientConnection {
        let authMethod = try authenticationMethod(for: host)
        logger.info("Auth method built successfully")

        let targetSettings = SSHClientSettings(
            host: host.hostname,
            port: host.port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .acceptAnything()
        )

        guard let jumpHost = host.jumpHost else {
            let sshClient = try await SSHClient.connect(to: targetSettings)
            let localForwarders = try await startLocalPortForwards(host.localPortForwards, using: sshClient)
            return SSHClientConnection(client: sshClient, jumpClient: nil, localPortForwarders: localForwarders)
        }

        logger.info("Connecting through jump host \(jumpHost.hostname):\(jumpHost.port) as \(jumpHost.username)")
        let jumpPrivateKeyRef = jumpHost.privateKeyRef.isEmpty ? host.privateKeyRef : jumpHost.privateKeyRef
        let jumpAuthMethod = try authenticationMethod(username: jumpHost.username, privateKeyRef: jumpPrivateKeyRef)
        let jumpSettings = SSHClientSettings(
            host: jumpHost.hostname,
            port: jumpHost.port,
            authenticationMethod: { jumpAuthMethod },
            hostKeyValidator: .acceptAnything()
        )
        let jumpClient = try await SSHClient.connect(to: jumpSettings)

        do {
            let targetClient = try await jumpClient.jump(to: targetSettings)
            let localForwarders = try await startLocalPortForwards(host.localPortForwards, using: targetClient)
            return SSHClientConnection(client: targetClient, jumpClient: jumpClient, localPortForwarders: localForwarders)
        } catch {
            try? await jumpClient.close()
            throw error
        }
    }

    private static func startLocalPortForwards(
        _ forwards: [LocalPortForward],
        using sshClient: SSHClient
    ) async throws -> [LocalPortForwarder] {
        var started: [LocalPortForwarder] = []
        do {
            for portForward in forwards {
                let forwarder = LocalPortForwarder(forward: portForward)
                try await forwarder.start(using: sshClient)
                started.append(forwarder)
            }
            return started
        } catch {
            for forwarder in started {
                await forwarder.stop()
            }
            throw error
        }
    }

    static func authenticationMethod(for host: Host) throws -> SSHAuthenticationMethod {
        try authenticationMethod(username: host.username, privateKeyRef: host.privateKeyRef)
    }

    static func authenticationMethod(username: String, privateKeyRef: String) throws -> SSHAuthenticationMethod {
        if privateKeyRef.isEmpty {
            throw SSHError.noKey
        }

        // Try Keychain first, fall back to dev key file in Documents
        let keyData: Data
        do {
            keyData = try KeychainManager.load(key: privateKeyRef)
        } catch {
            // Dev fallback: check for key file in app Documents
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let devKeyURL = docs.appendingPathComponent("dev-ssh-key")
            guard FileManager.default.fileExists(atPath: devKeyURL.path) else {
                throw SSHError.noKey
            }
            keyData = try Data(contentsOf: devKeyURL)
        }

        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw SSHError.invalidKey
        }

        // Try to parse as ed25519 OpenSSH key
        if keyString.contains("OPENSSH") {
            let rawKey = try parseOpenSSHEd25519(keyString)
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
            return .ed25519(username: username, privateKey: privateKey)
        }

        // Fall back to RSA
        let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyString)
        return .rsa(username: username, privateKey: privateKey)
    }

    private static func parseOpenSSHEd25519(_ pemString: String) throws -> Data {
        // OpenSSH private key format for ed25519:
        // Strip header/footer, base64 decode, then extract the 32-byte private key
        let lines = pemString.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64String = lines.joined()
        guard let decoded = Data(base64Encoded: base64String) else {
            throw SSHError.invalidKey
        }

        // OpenSSH format: magic, ciphername, kdfname, kdfoptions, number of keys,
        // public key, private key section
        // For unencrypted ed25519, the private key (seed) is 32 bytes
        // located after the public key in the private section
        // The private section contains: checkint, checkint, keytype, pubkey(32), privkey(64), comment
        // The privkey(64) = seed(32) + pubkey(32)

        let magic = "openssh-key-v1\0"
        guard decoded.count > magic.utf8.count,
              String(data: decoded.prefix(magic.utf8.count), encoding: .utf8) == magic else {
            throw SSHError.invalidKey
        }

        // Find the ed25519 private key seed (32 bytes) in the decoded data
        // Search for the key type string "ssh-ed25519" in the private section
        // The seed follows: keytype_len(4) + keytype + pubkey_len(4) + pubkey(32) + privkey_len(4) + privkey(64)
        // We want bytes 0-31 of the 64-byte privkey (that's the seed)

        // Simpler approach: scan for the second occurrence of "ssh-ed25519" (in private section)
        let keyTypeBytes: [UInt8] = Array("ssh-ed25519".utf8)
        let bytes = Array(decoded)
        var positions: [Int] = []
        for i in 0..<(bytes.count - keyTypeBytes.count) {
            if Array(bytes[i..<(i + keyTypeBytes.count)]) == keyTypeBytes {
                positions.append(i)
            }
        }

        guard positions.count >= 2 else {
            throw SSHError.invalidKey
        }

        // Second occurrence is in the private section
        let privSectionKeyTypeStart = positions[1]
        // From the raw string start: "ssh-ed25519"(11 bytes)
        // Then 4 bytes pubkey length + 32 bytes pubkey
        // Then 4 bytes privkey length + 64 bytes privkey (first 32 = seed)
        let offset = privSectionKeyTypeStart + keyTypeBytes.count + 4 + 32 + 4
        guard offset + 32 <= bytes.count else {
            throw SSHError.invalidKey
        }

        return Data(bytes[offset..<(offset + 32)])
    }
}

enum SSHError: LocalizedError {
    case noKey
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .noKey: "No SSH key configured for this host"
        case .invalidKey: "Could not parse SSH private key"
        }
    }
}
