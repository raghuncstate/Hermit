import Foundation

enum AgentJSON: Codable, Equatable, Sendable {
    case object([String: AgentJSON]), array([AgentJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: AgentJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([AgentJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> AgentJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int? { if case .number(let v) = self, v.isFinite, v >= 0, v < Double(Int.max) { return Int(v) }; return nil }
    var boolean: Bool { if case .bool(let v) = self { return v }; return false }
    var array: [AgentJSON] { if case .array(let v) = self { return v }; return [] }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct AgentChatError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AgentRequestRejected: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AgentFrameDecoder {
    static let limit = 1_048_576
    private var pending = Data()

    mutating func append(_ bytes: Data) throws -> [AgentJSON] {
        var frames: [AgentJSON] = []
        // Process each SSH chunk incrementally; a peer cannot grow the buffer unboundedly.
        for byte in bytes {
            if byte == 10 {
                if !pending.isEmpty { frames.append(try JSONDecoder().decode(AgentJSON.self, from: pending)) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < Self.limit else { throw AgentChatError("Bridge frame exceeds 1 MiB") }
                pending.append(byte)
            }
        }
        return frames
    }
}

struct AgentConversation: Codable, Identifiable, Hashable {
    var profileID: UUID
    var route: String
    var bridgeID: String
    var conversationID: String
    var title: String
    var provider: String
    var cwd: String
    var status: String
    var writable: Bool
    var updated: Double
    var id: String { [profileID.uuidString, route, bridgeID, conversationID].joined(separator: "|") }
}

struct AgentMessage: Codable, Identifiable, Equatable {
    var id: String
    var role: String
    var text: String
    var status: String
    var seq: Int
}

struct AgentQuestion: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
}

struct AgentHistory: Codable, Equatable {
    var messages: [AgentMessage] = []
    var before: Int?
    var partial = false
    var status: String?
    var requestID: String?
    var question: AgentQuestion?
    var hasNewer: Bool?

    mutating func merge(_ incoming: AgentHistory, older: Bool) {
        if !older {
            status = incoming.status; requestID = incoming.requestID; question = incoming.question
            if hasNewer == true { return }
        }
        let empty = messages.isEmpty
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for item in incoming.messages { byID[item.id] = item }
        messages = byID.values.sorted { $0.seq == $1.seq ? $0.id < $1.id : $0.seq < $1.seq }
        if older || empty { before = incoming.before }
        // Keep a bounded page window, never silently discard the direction being read.
        var bytes = messages.reduce(0) { $0 + $1.text.utf8.count }
        while messages.count > 1500 || bytes > 4 * 1024 * 1024 {
            if older {
                bytes -= messages.removeLast().text.utf8.count
                hasNewer = true
            } else {
                bytes -= messages.removeFirst().text.utf8.count
                before = messages.first?.seq
            }
        }
        partial = partial || incoming.partial
    }
}

struct AgentOutboxItem: Codable {
    var requestID: String
    var text: String
    var state: String
}

struct AgentCreationRequest: Codable {
    var id: String
    var bridgeID: String
    var provider: String
    var title: String
    var cwd: String
}

struct AgentChatArchive: Codable {
    var version = 1
    var conversations: [AgentConversation] = []
    var histories: [String: AgentHistory] = [:]
    var drafts: [String: String] = [:]
    var favorites: [String] = []
    var outbox: [String: AgentOutboxItem] = [:]
    var pins: [String: String] = [:]
    var creations: [String: AgentCreationRequest]?
}

// Only a current capture can authorize an automatic send. UI text changes cannot.
struct AgentVoiceGate {
    private(set) var captureID: UUID?
    private(set) var target: String?
    private var consumed = false

    mutating func begin(target: String) -> UUID {
        let id = UUID(); captureID = id; self.target = target; consumed = false; return id
    }
    mutating func finish(capture: UUID, target: String, text: String, final: Bool) -> String? {
        guard captureID == capture, self.target == target, !consumed, final,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        consumed = true
        return text
    }
    mutating func cancel() { captureID = nil; target = nil; consumed = true }
}

enum AgentSpeechText {
    static func reply(_ text: String) -> String {
        // Authentication material and raw code stay on screen, not on a loudspeaker.
        let sensitive = ["password", "token", "secret", "verification", "device code", "login", "log in", "sign in", "authentication", "private key"]
        if sensitive.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return "The reply contains account or security information. Please review it on screen." }
        guard let parsed = try? AttributedString(markdown: text) else { return "The reply is available on screen." }
        var parts: [String] = []
        for run in parsed.runs {
            let codeBlock = run.presentationIntent?.components.contains { if case .codeBlock = $0.kind { return true }; return false } ?? false
            if codeBlock || run.inlinePresentationIntent?.contains(.code) == true || run.link != nil { continue }
            parts.append(String(parsed[run.range].characters))
        }
        var result = parts.joined(separator: " ")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(result.startIndex..., in: result)
            for match in detector.matches(in: result, range: range).reversed() {
                if let range = Range(match.range, in: result) { result.removeSubrange(range) }
            }
        }
        let code = try? NSRegularExpression(pattern: "\\b[A-Z0-9]{4,8}[- ][A-Z0-9]{4,8}\\b")
        if code?.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil { return "The reply includes a code. Please review it on screen." }
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The reply is available on screen." }
        return String(result.prefix(5000)) + (result.count > 5000 ? " The rest is in the conversation." : "")
    }
}
