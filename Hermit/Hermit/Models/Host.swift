import Foundation

struct SSHJumpHost: Codable, Hashable {
    var hostname: String
    var port: Int
    var username: String
    var privateKeyRef: String

    init(
        hostname: String,
        port: Int = 22,
        username: String,
        privateKeyRef: String = ""
    ) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.privateKeyRef = privateKeyRef
    }
}

struct Host: Codable, Identifiable {
    var id: UUID
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var privateKeyRef: String
    var jumpHost: SSHJumpHost?
    var defaultTmuxSessionName: String
    var tmuxSocketName: String?
    var ribbonConfigs: [RibbonConfig]
    var createdAt: Date

    /// First ribbon config, for backward compatibility.
    var ribbonConfig: RibbonConfig {
        ribbonConfigs.first ?? .default
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: Int = 22,
        username: String,
        privateKeyRef: String = "",
        jumpHost: SSHJumpHost? = nil,
        defaultTmuxSessionName: String = "0",
        tmuxSocketName: String? = nil,
        ribbonConfigs: [RibbonConfig] = RibbonConfig.presets,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.privateKeyRef = privateKeyRef
        self.jumpHost = jumpHost
        self.defaultTmuxSessionName = defaultTmuxSessionName
        self.tmuxSocketName = Self.normalizedTmuxSocketName(tmuxSocketName)
        self.ribbonConfigs = ribbonConfigs
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, port, username, privateKeyRef, jumpHost
        case defaultTmuxSessionName, defaultTmuxSession, tmuxSocketName
        case ribbonConfigs, ribbonConfig, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        privateKeyRef = try c.decode(String.self, forKey: .privateKeyRef)
        jumpHost = try? c.decode(SSHJumpHost.self, forKey: .jumpHost)
        defaultTmuxSessionName =
            (try? c.decode(String.self, forKey: .defaultTmuxSessionName)) ??
            (try? c.decode(String.self, forKey: .defaultTmuxSession)) ??
            "0"
        tmuxSocketName = Self.normalizedTmuxSocketName(try? c.decode(String.self, forKey: .tmuxSocketName))
        createdAt = try c.decode(Date.self, forKey: .createdAt)

        // Migrate from single ribbonConfig to ribbonConfigs array
        if let configs = try? c.decode([RibbonConfig].self, forKey: .ribbonConfigs) {
            ribbonConfigs = configs
        } else if let single = try? c.decode(RibbonConfig.self, forKey: .ribbonConfig) {
            ribbonConfigs = [single, .planMode]
        } else {
            ribbonConfigs = RibbonConfig.presets
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(privateKeyRef, forKey: .privateKeyRef)
        try c.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try c.encode(defaultTmuxSessionName, forKey: .defaultTmuxSessionName)
        try c.encodeIfPresent(tmuxSocketName, forKey: .tmuxSocketName)
        try c.encode(ribbonConfigs, forKey: .ribbonConfigs)
        try c.encode(createdAt, forKey: .createdAt)
    }

    private static func normalizedTmuxSocketName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Host: Hashable {
    static func == (lhs: Host, rhs: Host) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
