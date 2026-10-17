import XCTest
@testable import Hermit

private actor TerminalTestClient: TmuxCommandClient {
    nonisolated let events: AsyncStream<TmuxControlEvent>
    private let continuation: AsyncStream<TmuxControlEvent>.Continuation
    var commands: [String] = []
    var closeCount = 0
    var blockInput = false
    var failInput = false
    var blockClose = false
    var blockDisplay = false
    private var inputWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<TmuxControlEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func configure(input: Bool = false, fail: Bool = false, close: Bool = false) {
        blockInput = input; failInput = fail; blockClose = close
    }

    func releaseInput() { blockInput = false; inputWaiter?.resume(); inputWaiter = nil }
    func releaseClose() { blockClose = false; closeWaiter?.resume(); closeWaiter = nil }
    func holdDisplay() { blockDisplay = true }

    func send(_ command: String) async throws -> String {
        commands.append(command)
        if blockDisplay && command.hasPrefix("refresh-client -C") {
            await withCheckedContinuation { inputWaiter = $0 }
        }
        if command.hasPrefix("send-keys") {
            if blockInput { await withCheckedContinuation { inputWaiter = $0 } }
            if failInput { throw TmuxProtocolError.disconnected }
        }
        if command.hasPrefix("list-sessions") { return "$1|test|1|1" }
        if command.hasPrefix("list-windows") { return "@1|0|keys|1|layout" }
        if command.hasPrefix("list-panes") { return "%1|0|codex|1|80|24|codex" }
        if command.hasPrefix("capture-pane") { return "PROMPT> \n                      STATUS" }
        return ""
    }

    func disconnect() async {
        closeCount += 1
        continuation.finish()
        if blockClose { await withCheckedContinuation { closeWaiter = $0 } }
        releaseInput()
    }
}

private actor TerminalTestFactory {
    var clients: [TerminalTestClient] = []
    var blockOpen = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() { blockOpen = true }
    func release() { blockOpen = false; waiter?.resume(); waiter = nil }
    func open() async -> TerminalTestClient {
        let client = TerminalTestClient()
        clients.append(client)
        if blockOpen { await withCheckedContinuation { waiter = $0 } }
        return client
    }
}

@MainActor
final class TmuxForegroundTests: XCTestCase {
    private let pane = TmuxPane(id: "%1", index: 0, title: "codex", isActive: true, width: 80, height: 24, currentCommand: "codex")
    private let window = TmuxWindow(id: "@1", sessionId: "$1", index: 0, name: "keys", isActive: true, layout: "layout")

    private func model(_ factory: TerminalTestFactory) -> TmuxWorkspaceModel {
        TmuxWorkspaceModel(host: Host(displayName: "Test", hostname: "127.0.0.1", username: "test")) { _ in
            await factory.open()
        }
    }

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for test synchronization", file: file, line: line)
    }

    func testConcurrentConnectAndReconnectUseOneAttempt() async {
        let factory = TerminalTestFactory()
        await factory.hold()
        let model = model(factory)
        let first = Task { await model.connectIfNeeded() }
        await waitUntil { await factory.clients.count == 1 }
        let others = (0..<8).map { _ in Task { await model.reconnect() } }
        await factory.release()
        await first.value
        for task in others { await task.value }
        let count = await factory.clients.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.status, .connected)
        await model.disconnect()
    }

    func testBackgroundDuringOpenCannotPublishOldClient() async {
        let factory = TerminalTestFactory()
        await factory.hold()
        let model = model(factory)
        let opening = Task { await model.connectIfNeeded() }
        await waitUntil { await factory.clients.count == 1 }
        model.suspend()
        XCTAssertFalse(model.canSendInput)
        let resuming = Task { await model.activate() }
        await factory.release()
        await opening.value
        await resuming.value
        let clients = await factory.clients
        XCTAssertEqual(clients.count, 2)
        let closed = await clients[0].closeCount
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(model.status, .connected)
        await model.disconnect()
    }

    func testDelayedBackgroundCloseDoesNotCloseForegroundReplacement() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        let old = await factory.clients[0]
        await old.configure(close: true)
        model.suspend()
        model.suspend()
        XCTAssertEqual(model.status, .disconnected)
        await waitUntil { await old.closeCount == 1 }
        let resuming = Task { await model.activate() }
        await old.releaseClose()
        await resuming.value
        let clients = await factory.clients
        XCTAssertEqual(clients.count, 2)
        let closed = await clients[1].closeCount
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(model.canSendInput)
        await model.disconnect()
    }

    func testBackgroundReadsAndTypingCannotReopenSSH() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        model.suspend()
        await model.refreshSessions()
        await model.captureLive(pane)
        let delivered = await model.sendInputText("do not send", to: pane)
        XCTAssertFalse(delivered)
        let clients = await factory.clients
        XCTAssertEqual(clients.count, 1)
        let input = await clients[0].commands.filter { $0.hasPrefix("send-keys") }
        XCTAssertTrue(input.isEmpty)
        await model.disconnect()
    }

    func testTypingNeverAppendsSyntheticTextToScreenFooter() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        await model.captureLive(pane)
        let frame = model.snapshotsByPane[pane.id]?.rawText
        let delivered = await model.sendInputText("Enter", to: pane)
        XCTAssertTrue(delivered)
        XCTAssertEqual(model.snapshotsByPane[pane.id]?.rawText, frame)
        let client = await factory.clients[0]
        let input = await client.commands.filter { $0.hasPrefix("send-keys") }
        XCTAssertEqual(input, ["send-keys -l -t '%1' -- 'Enter'"])
        await model.disconnect()
    }

    func testLostAcknowledgmentIsNotReplayedAndStopsQueuedInput() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        let client = await factory.clients[0]
        await client.configure(input: true, fail: true)
        let first = Task { await model.sendInputText("once", to: pane) }
        await waitUntil { await client.commands.contains { $0.hasPrefix("send-keys") } }
        let next = Task { await model.sendEnter(to: pane) }
        await client.releaseInput()
        let firstResult = await first.value
        let nextResult = await next.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(nextResult)
        XCTAssertNotNil(model.inputErrorMessage)
        await model.activate()
        XCTAssertFalse(model.canSendInput)
        let clients = await factory.clients
        XCTAssertEqual(clients.count, 2)
        let input = await client.commands.filter { $0.hasPrefix("send-keys") }
        XCTAssertEqual(input, ["send-keys -l -t '%1' -- 'once'"])
        let replacementInput = await clients[1].commands.filter { $0.hasPrefix("send-keys") }
        XCTAssertTrue(replacementInput.isEmpty)
        model.acknowledgeInputError()
        XCTAssertTrue(model.canSendInput)
        await model.disconnect()
    }

    func testEditsAndEnterStayOrdered() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        let client = await factory.clients[0]
        await client.configure(input: true)
        let edit = Task { await model.sendInputDelta(backspaceCount: 2, insertedText: "abc", enter: true, to: pane) }
        await waitUntil { await client.commands.contains { $0.hasPrefix("send-keys") } }
        let next = Task { await model.sendInputText("next", to: pane) }
        await client.releaseInput()
        let firstResult = await edit.value
        let nextResult = await next.value
        XCTAssertTrue(firstResult && nextResult)
        let input = await client.commands.filter { $0.hasPrefix("send-keys") }
        XCTAssertEqual(input, ["send-keys -N 2 -t '%1' BSpace", "send-keys -l -t '%1' -- 'abc'", "send-keys -t '%1' Enter", "send-keys -l -t '%1' -- 'next'"])
        await model.disconnect()
    }

    func testReconnectReappliesSameDisplaySize() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        await model.refreshWindow(window)
        await model.resizeForDisplay(pane, cols: 80, rows: 24, in: window)
        model.suspend()
        await model.activate()
        await model.resizeForDisplay(pane, cols: 80, rows: 24, in: window)
        let clients = await factory.clients
        XCTAssertEqual(clients.count, 2)
        for client in clients {
            let commands = await client.commands
            XCTAssertTrue(commands.contains("refresh-client -C 80x24"))
        }
        await model.disconnect()
    }

    func testDelayedKeyboardTaskCannotWriteIntoReplacementConnection() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        let generation = model.connectionGeneration
        model.suspend()
        await model.activate()
        let delivered = await model.sendInputDelta(backspaceCount: 0, insertedText: "old key", enter: false,
                                                  to: pane, expectedGeneration: generation)
        XCTAssertFalse(delivered)
        XCTAssertNotNil(model.inputErrorMessage)
        for client in await factory.clients {
            let commands = await client.commands
            XCTAssertFalse(commands.contains { $0.hasPrefix("send-keys") })
        }
        await model.disconnect()
    }

    func testDedicatedShiftLeftUsesExactKeyAndConsumesShiftToggle() async {
        let factory = TerminalTestFactory()
        let model = model(factory)
        await model.connectIfNeeded()
        var modifiers = TmuxKeyModifiers(shift: true)
        let key = modifiers.consume(TmuxMacro(label: "Shift Left", key: "S-Left"))
        let delivered = await model.send(key, to: pane)
        XCTAssertTrue(delivered)
        XCTAssertFalse(modifiers.shift)
        let client = await factory.clients[0]
        let commands = await client.commands
        XCTAssertTrue(commands.contains("send-keys -t '%1' S-Left"))
        await model.disconnect()
    }

    func testCancelledKeyboardResizeCannotOverwriteNewLayout() async {
        let client = TerminalTestClient()
        await client.holdDisplay()
        let resize = Task { try await client.resizeDisplay(windowId: "@1", cols: 80, rows: 24) }
        await waitUntil { await client.commands.contains("refresh-client -C 80x24") }
        resize.cancel()
        await client.releaseInput()
        do {
            try await resize.value
            XCTFail("Cancelled resize should stop before changing the pane")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let commands = await client.commands
        XCTAssertEqual(commands, ["refresh-client -C 80x24"])
        await client.disconnect()
    }
}
