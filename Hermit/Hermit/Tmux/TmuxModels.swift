import Foundation

struct TmuxSession: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var attachedCount: Int
    var activity: Date?
    var windowCount: Int?

    var isAttached: Bool { attachedCount > 0 }
}

struct TmuxWindow: Codable, Hashable, Identifiable {
    var id: String
    var sessionId: String
    var index: Int
    var name: String
    var isActive: Bool
    var layout: String
}

struct TmuxPane: Codable, Hashable, Identifiable {
    var id: String
    var index: Int
    var title: String
    var isActive: Bool
    var width: Int
    var height: Int
    var currentCommand: String

    func prefersTerminalPager(windowName: String) -> Bool {
        let lowercasedText = "\(windowName) \(title) \(currentCommand)".lowercased()
        if lowercasedText.contains("claude") {
            return true
        }

        let commandLooksLikeClaudeCodeVersion = currentCommand.range(
            of: #"^\d+\.\d+\.\d+$"#,
            options: .regularExpression
        ) != nil
        return commandLooksLikeClaudeCodeVersion && title.hasPrefix("✳")
    }
}

enum TmuxConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}
