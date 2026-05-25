import Foundation

enum TmuxProtocolError: LocalizedError, Equatable {
    case commandFailed(String)
    case malformedControlLine(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            output.isEmpty ? "tmux command failed" : output
        case .malformedControlLine(let line):
            "Malformed tmux control line: \(line)"
        case .disconnected:
            "tmux control session disconnected"
        }
    }
}

enum TmuxControlEvent: Equatable {
    case output(paneId: String, bytes: Data)
    case extendedOutput(paneId: String, ageMilliseconds: Int, bytes: Data)
    case windowAdd(windowId: String, sessionId: String?)
    case windowClose(windowId: String)
    case windowRenamed(windowId: String, name: String)
    case windowPaneChanged(windowId: String, paneId: String)
    case layoutChange(windowId: String, layout: String)
    case sessionsChanged
    case sessionChanged(sessionId: String, name: String)
    case sessionWindowChanged(sessionId: String, windowId: String)
    case paneModeChanged(paneId: String)
    case pause(paneId: String)
    case continued(paneId: String)
    case exit
}

struct TmuxCommandBlock: Equatable {
    var commandNumber: Int
    var output: String
    var isError: Bool
}

enum TmuxProtocolMessage: Equatable {
    case commandStarted(commandNumber: Int)
    case commandFinished(TmuxCommandBlock)
    case event(TmuxControlEvent)
}

struct TmuxProtocolParser {
    private var pendingBytes = Data()
    private var activeCommandNumber: Int?
    private var activeCommandOutput: [String] = []

    mutating func append(_ data: Data) -> [TmuxProtocolMessage] {
        pendingBytes.append(data)
        var messages: [TmuxProtocolMessage] = []

        while let newlineIndex = pendingBytes.firstIndex(of: 0x0a) {
            var lineBytes = pendingBytes[..<newlineIndex]
            pendingBytes.removeSubrange(...newlineIndex)

            if lineBytes.last == 0x0d {
                lineBytes.removeLast()
            }

            let line = String(decoding: lineBytes, as: UTF8.self)
            if let message = parseLine(line) {
                messages.append(message)
            }
        }

        return messages
    }

    mutating func parseLine(_ rawLine: String) -> TmuxProtocolMessage? {
        let line = Self.normalizedControlLine(rawLine)

        if line.hasPrefix("%begin ") {
            guard let commandNumber = Self.commandNumber(in: line) else {
                return nil
            }
            activeCommandNumber = commandNumber
            activeCommandOutput = []
            return .commandStarted(commandNumber: commandNumber)
        }

        if activeCommandNumber != nil, line.hasPrefix("%end ") || line.hasPrefix("%error ") {
            guard let commandNumber = Self.commandNumber(in: line) else {
                return nil
            }
            let output = activeCommandOutput.joined(separator: "\n")
            activeCommandNumber = nil
            activeCommandOutput = []
            return .commandFinished(TmuxCommandBlock(
                commandNumber: commandNumber,
                output: output,
                isError: line.hasPrefix("%error ")
            ))
        }

        if activeCommandNumber != nil {
            activeCommandOutput.append(line)
            return nil
        }

        guard !line.isEmpty else { return nil }

        return parseEvent(line).map(TmuxProtocolMessage.event)
    }

    private func parseEvent(_ line: String) -> TmuxControlEvent? {
        if line == "%exit" {
            return .exit
        }

        if line == "%sessions-changed" {
            return .sessionsChanged
        }

        if line.hasPrefix("%output ") {
            let rest = line.dropFirst("%output ".count)
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let paneId = String(rest[..<space])
            let payload = String(rest[rest.index(after: space)...])
            return .output(paneId: paneId, bytes: Self.decodeOutputBytes(payload))
        }

        if line.hasPrefix("%extended-output ") {
            let pieces = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard pieces.count == 5, pieces[3] == ":" else { return nil }
            return .extendedOutput(
                paneId: String(pieces[1]),
                ageMilliseconds: Int(pieces[2]) ?? 0,
                bytes: Self.decodeOutputBytes(String(pieces[4]))
            )
        }

        if line.hasPrefix("%window-add ") {
            let pieces = line.split(separator: " ", maxSplits: 2)
            guard pieces.count >= 2 else { return nil }
            return .windowAdd(
                windowId: String(pieces[1]),
                sessionId: pieces.count > 2 ? String(pieces[2]) : nil
            )
        }

        if line.hasPrefix("%unlinked-window-add ") {
            let pieces = line.split(separator: " ", maxSplits: 2)
            guard pieces.count >= 2 else { return nil }
            return .windowAdd(
                windowId: String(pieces[1]),
                sessionId: pieces.count > 2 ? String(pieces[2]) : nil
            )
        }

        if line.hasPrefix("%window-close ") || line.hasPrefix("%unlinked-window-close ") {
            let pieces = line.split(separator: " ", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return .windowClose(windowId: String(pieces[1]))
        }

        if line.hasPrefix("%window-renamed ") || line.hasPrefix("%unlinked-window-renamed ") {
            let pieces = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count >= 3 else { return nil }
            return .windowRenamed(windowId: String(pieces[1]), name: String(pieces[2]))
        }

        if line.hasPrefix("%window-pane-changed ") {
            let pieces = line.split(separator: " ", maxSplits: 2)
            guard pieces.count == 3 else { return nil }
            return .windowPaneChanged(windowId: String(pieces[1]), paneId: String(pieces[2]))
        }

        if line.hasPrefix("%layout-change ") {
            let pieces = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count >= 3 else { return nil }
            return .layoutChange(windowId: String(pieces[1]), layout: String(pieces[2]))
        }

        if line.hasPrefix("%session-changed ") || line.hasPrefix("%session-renamed ") {
            let pieces = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count >= 3 else { return nil }
            return .sessionChanged(sessionId: String(pieces[1]), name: String(pieces[2]))
        }

        if line.hasPrefix("%session-window-changed ") {
            let pieces = line.split(separator: " ", maxSplits: 2)
            guard pieces.count == 3 else { return nil }
            return .sessionWindowChanged(sessionId: String(pieces[1]), windowId: String(pieces[2]))
        }

        if line.hasPrefix("%pane-mode-changed ") {
            let pieces = line.split(separator: " ", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return .paneModeChanged(paneId: String(pieces[1]))
        }

        if line.hasPrefix("%pause ") {
            let pieces = line.split(separator: " ", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return .pause(paneId: String(pieces[1]))
        }

        if line.hasPrefix("%continue ") {
            let pieces = line.split(separator: " ", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return .continued(paneId: String(pieces[1]))
        }

        return nil
    }

    static func decodeOutputBytes(_ escaped: String) -> Data {
        let scalars = Array(escaped.unicodeScalars)
        var bytes: [UInt8] = []
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let secondIndex = scalars.index(index, offsetBy: 2, limitedBy: scalars.endIndex)
            let thirdIndex = scalars.index(index, offsetBy: 3, limitedBy: scalars.endIndex)
            if scalar == "\\".unicodeScalars.first,
               let secondIndex,
               let thirdIndex,
               thirdIndex < scalars.endIndex {
                let first = scalars[scalars.index(after: index)]
                let second = scalars[secondIndex]
                let third = scalars[thirdIndex]
                let octal = String(String.UnicodeScalarView([first, second, third]))
                if let value = UInt8(octal, radix: 8) {
                    bytes.append(value)
                    index = scalars.index(index, offsetBy: 4)
                    continue
                }
            }

            for byte in String(scalar).utf8 {
                bytes.append(byte)
            }
            index = scalars.index(after: index)
        }

        return Data(bytes)
    }

    private static func normalizedControlLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{1B}P1000p", with: "")
            .replacingOccurrences(of: "\u{1B}\\", with: "")
    }

    private static func commandNumber(in line: String) -> Int? {
        let pieces = line.split(separator: " ", maxSplits: 3)
        guard pieces.count >= 3 else { return nil }
        return Int(pieces[2])
    }
}
