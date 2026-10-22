import Citadel
import Foundation
import NIOCore
import NIOSSH
import os

private let tmuxLogger = Logger(subsystem: "com.zeromissionllc.hermit", category: "TmuxControl")

actor TmuxControlClient: TmuxCommandClient {
    struct Timeouts {
        var startup: Duration = .seconds(15)
        var command: Duration = .seconds(8)
        var detach: Duration = .milliseconds(750)
    }

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
    private let timeouts: Timeouts
    private var shutdownTask: Task<Void, Never>?
    private var exitWaiter: CheckedContinuation<Void, Never>?
    private var didExit = false
    private(set) var receivedExitAcknowledgement = false

    init(connection: SSHClientConnection, timeouts: Timeouts = Timeouts()) {
        self.connection = connection
        self.timeouts = timeouts
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
        try Task.checkCancellation()
        guard !didFinish else { throw TmuxProtocolError.disconnected }
        guard lifecycleTask == nil else { return }

        let command = TmuxLaunchCommand.controlMode(sessionName: sessionName, socketName: socketName, tmuxCommand: tmuxCommand)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                startupTimeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeouts.startup)
                    } catch {
                        return
                    }
                    guard startContinuation != nil else { return }
                    beginShutdown(error: TmuxProtocolError.startupTimedOut)
                }
                lifecycleTask = Task { [sshClient] in
                    do {
                        try await sshClient.withExec(command) { inbound, outbound in
                            guard !self.didFinish else { return }
                            self.writer = outbound
                            for try await output in inbound {
                                switch output {
                                case .stdout(var buffer), .stderr(var buffer):
                                    let data = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
                                    self.receive(data)
                                }
                            }
                        }
                        self.transportEnded(error: TmuxProtocolError.disconnected)
                    } catch {
                        self.transportEnded(error: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.disconnect() }
        }
    }

    func send(_ command: String) async throws -> String {
        try Task.checkCancellation()
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
                    beginShutdown(error: error)
                }
            }
        }
    }

    func disconnect() async {
        await beginShutdown(error: TmuxProtocolError.disconnected).value
    }

    private func transportEnded(error: Error) {
        didExit = true
        exitWaiter?.resume()
        exitWaiter = nil
        beginShutdown(error: error)
    }

    private func receive(_ data: Data) {
        for message in parser.append(data) {
            handle(message)
        }
    }

    private func handle(_ message: TmuxProtocolMessage) {
        if case .event(.exit) = message {
            receivedExitAcknowledgement = true
            didExit = true
            exitWaiter?.resume()
            exitWaiter = nil
        }
        guard !didFinish else { return }
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
                    beginShutdown(error: TmuxProtocolError.commandFailed(block.output))
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
                beginShutdown(error: TmuxProtocolError.disconnected)
            }
        }
    }

    private func armCommandTimeout() {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        guard !waitingForBegin.isEmpty || !pendingCommands.isEmpty else { return }
        commandTimeoutTask = Task {
            do { try await Task.sleep(for: timeouts.command) } catch { return }
            beginShutdown(error: TmuxProtocolError.commandTimedOut)
        }
    }

    @discardableResult
    private func beginShutdown(error: Error) -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        didFinish = true
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        let lastWrite = writeTask
        writeTask = nil
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

        // Every exit path owns this same teardown. Keep reading until the detach
        // acknowledgement or deadline; never target another client/session/PID.
        let task = Task {
            if let writer, !didExit {
                var detachWrite: Task<Void, Never>?
                var deadline: Task<Void, Never>?
                await withCheckedContinuation { continuation in
                    exitWaiter = continuation
                    deadline = Task {
                        do { try await Task.sleep(for: timeouts.detach) } catch { return }
                        endDetachWait()
                    }
                    detachWrite = Task {
                        await lastWrite?.value
                        guard !Task.isCancelled, !didExit else { return }
                        do {
                            // An empty control line detaches only this client.
                            try await writer.write(ByteBuffer(string: "\n"))
                        } catch {
                            endDetachWait()
                        }
                    }
                }
                deadline?.cancel()
                detachWrite?.cancel()
            }
            await connection.close()
            lifecycleTask?.cancel()
            lastWrite?.cancel()
            writer = nil
            // Do not await this task from the reader itself (transportEnded).
            await lifecycleTask?.value
            lifecycleTask = nil
        }
        shutdownTask = task
        return task
    }

    private func endDetachWait() {
        exitWaiter?.resume()
        exitWaiter = nil
    }
}
