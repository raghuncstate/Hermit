import Citadel
import Foundation
import NIOCore
import NIOSSH
import os

private let tmuxLogger = Logger(subsystem: "com.zeromissionllc.hermit", category: "TmuxControl")

actor TmuxControlClient: TmuxCommandClient {
    nonisolated let events: AsyncStream<TmuxControlEvent>

    private let eventContinuation: AsyncStream<TmuxControlEvent>.Continuation
    private let connection: SSHClientConnection
    private var sshClient: SSHClient { connection.client }
    private var writer: TTYStdinWriter?
    private var parser = TmuxProtocolParser()
    private var lifecycleTask: Task<Void, Never>?
    private var waitingForBegin: [CheckedContinuation<String, Error>] = []
    private var pendingCommands: [Int: CheckedContinuation<String, Error>] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var commandTimeoutTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var didFinish = false

    init(connection: SSHClientConnection) {
        self.connection = connection
        let stream = AsyncStream<TmuxControlEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    static func connect(host: Host, sessionName: String) async throws -> TmuxControlClient {
        let connection = try await SSHConnectionManager.connectClient(for: host)
        let client = TmuxControlClient(connection: connection)
        do {
            try await client.start(sessionName: sessionName, socketName: host.tmuxSocketName, tmuxCommand: host.tmuxCommand)
            return client
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func start(sessionName: String, socketName: String?, tmuxCommand: String?) async throws {
        guard lifecycleTask == nil else { return }

        let command = TmuxLaunchCommand.controlMode(sessionName: sessionName, socketName: socketName, tmuxCommand: tmuxCommand)
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            startupTimeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard startContinuation != nil else { return }
                finish(error: TmuxProtocolError.startupTimedOut)
            }
            lifecycleTask = Task { [sshClient] in
                do {
                    try await sshClient.withPTY(
                        .init(
                            wantReply: true,
                            term: "xterm-256color",
                            terminalCharacterWidth: 80,
                            terminalRowHeight: 24,
                            terminalPixelWidth: 0,
                            terminalPixelHeight: 0,
                            terminalModes: .init([:])
                        )
                    ) { inbound, outbound in
                        var commandBuffer = ByteBufferAllocator().buffer(capacity: command.utf8.count + 1)
                        commandBuffer.writeString(command)
                        commandBuffer.writeString("\n")
                        try await outbound.write(commandBuffer)
                        self.setWriter(outbound)

                        for try await output in inbound {
                            switch output {
                            case .stdout(var buffer), .stderr(var buffer):
                                let data = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
                                self.receive(data)
                            }
                        }
                    }
                    self.finish(error: TmuxProtocolError.disconnected)
                } catch {
                    self.finish(error: error)
                }
            }
        }
    }

    func send(_ command: String) async throws -> String {
        guard !didFinish, let writer else {
            throw TmuxProtocolError.disconnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            waitingForBegin.append(continuation)
            if commandTimeoutTask == nil { armCommandTimeout() }
            let previousWrite = writeTask
            writeTask = Task {
                await previousWrite?.value
                guard !didFinish else { return }
                do {
                    var buffer = ByteBufferAllocator().buffer(capacity: command.utf8.count + 1)
                    buffer.writeString(command)
                    buffer.writeString("\n")
                    try await writer.write(buffer)
                } catch {
                    finish(error: error)
                    await connection.close()
                }
            }
        }
    }

    func disconnect() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        finish(error: TmuxProtocolError.disconnected)
        await connection.close()
    }

    private func setWriter(_ writer: TTYStdinWriter) {
        self.writer = writer
    }

    private func receive(_ data: Data) {
        for message in parser.append(data) {
            handle(message)
        }
    }

    private func handle(_ message: TmuxProtocolMessage) {
        switch message {
        case .commandStarted(let commandNumber):
            guard !waitingForBegin.isEmpty else { return }
            pendingCommands[commandNumber] = waitingForBegin.removeFirst()
        case .commandFinished(let block):
            // tmux emits an initial attach block before replies to client commands.
            if let continuation = startContinuation {
                startContinuation = nil
                startupTimeoutTask?.cancel()
                startupTimeoutTask = nil
                if block.isError {
                    continuation.resume(throwing: TmuxProtocolError.commandFailed(block.output))
                } else {
                    continuation.resume()
                    Task {
                        do {
                            _ = try await send("refresh-client -f pause-after=5")
                        } catch {
                            tmuxLogger.debug("Unable to enable tmux flow control: \(error.localizedDescription)")
                        }
                    }
                }
                return
            }
            guard let continuation = pendingCommands.removeValue(forKey: block.commandNumber) else {
                return
            }
            if block.isError {
                continuation.resume(throwing: TmuxProtocolError.commandFailed(block.output))
            } else {
                continuation.resume(returning: block.output)
            }
            armCommandTimeout()
        case .event(let event):
            eventContinuation.yield(event)
            if event == .exit {
                finish(error: TmuxProtocolError.disconnected)
            }
        }
    }

    private func armCommandTimeout() {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        guard !waitingForBegin.isEmpty || !pendingCommands.isEmpty else { return }
        commandTimeoutTask = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            finish(error: TmuxProtocolError.commandTimedOut)
            await connection.close()
        }
    }

    private func finish(error: Error) {
        guard !didFinish else { return }
        didFinish = true
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        writeTask?.cancel()
        writeTask = nil

        writer = nil
        startContinuation?.resume(throwing: error)
        startContinuation = nil

        for continuation in waitingForBegin {
            continuation.resume(throwing: error)
        }
        waitingForBegin.removeAll()

        for continuation in pendingCommands.values {
            continuation.resume(throwing: error)
        }
        pendingCommands.removeAll()
        eventContinuation.finish()
    }
}
