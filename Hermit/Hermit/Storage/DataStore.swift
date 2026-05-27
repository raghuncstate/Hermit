import Foundation

@Observable
final class DataStore {
    var hosts: [Host] = []
    var sessions: [Session] = []
    var tmuxShortcuts: [TmuxShortcut] = []
    var iCloudAvailable: Bool { iCloudURL != nil }

    private let localFileURL: URL
    private let iCloudURL: URL?
    private var metadataQuery: NSMetadataQuery?

    private static let reverseTunnelMacHostID = UUID(uuidString: "EED9DA12-53C1-489C-B761-3013BDD43355")!
    private static let obsoleteVPNMacHostID = UUID(uuidString: "83540C4C-2633-4C44-936C-EED9AE6F7EDB")!

    private var fileURL: URL {
        iCloudURL ?? localFileURL
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.localFileURL = docs.appendingPathComponent("hermit-data.json")

        // Never use iCloud in the simulator — prevents clobbering production data
        #if !targetEnvironment(simulator)
        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.zeromissionllc.hermit") {
            let iCloudDocsURL = containerURL.appendingPathComponent("Documents")
            try? FileManager.default.createDirectory(at: iCloudDocsURL, withIntermediateDirectories: true)
            self.iCloudURL = iCloudDocsURL.appendingPathComponent("hermit-data.json")
        } else {
            self.iCloudURL = nil
        }
        #else
        self.iCloudURL = nil
        #endif

        migrateLocalToiCloudIfNeeded()
        load()
        createFileIfNeeded()
        startWatchingForChanges()
    }

    deinit {
        metadataQuery?.stop()
    }

    // MARK: - Persistence

    func load() {
        let url = fileURL

        // If iCloud file isn't downloaded yet, trigger download and wait for the
        // metadata query to notify us when it arrives — do NOT create an empty file
        if let iCloudURL, !FileManager.default.fileExists(atPath: iCloudURL.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: iCloudURL)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            var data: Data?
            var readError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: url, options: [], error: &readError) { coordURL in
                data = try? Data(contentsOf: coordURL)
            }
            if let readError { throw readError }
            guard let data else { return }

            let backup = try JSONDecoder.hermit.decode(BackupData.self, from: data)
            let profileMigration = migrateReverseTunnelProfile(
                hosts: backup.hosts.map { migrateHost($0) },
                sessions: backup.sessions,
                shortcuts: backup.tmuxShortcuts
            )
            let knownHostIDs = Set(profileMigration.hosts.map(\.id))

            let filteredShortcuts = profileMigration.shortcuts.filter { shortcut in
                knownHostIDs.contains(shortcut.hostID)
            }

            self.hosts = profileMigration.hosts
            self.sessions = profileMigration.sessions
            self.tmuxShortcuts = filteredShortcuts

            if profileMigration.didChange || filteredShortcuts.count != profileMigration.shortcuts.count {
                save()
            }
        } catch {
            print("Failed to load data: \(error)")
        }
    }

    func save() {
        // Never overwrite iCloud with empty data — protects against saving before
        // the iCloud file has downloaded
        if iCloudURL != nil && hosts.isEmpty && sessions.isEmpty {
            print("Refusing to save empty data to iCloud")
            return
        }

        do {
            let backup = BackupData(
                version: 1,
                exportedAt: Date(),
                hosts: hosts,
                sessions: sessions,
                tmuxShortcuts: tmuxShortcuts
            )
            let data = try JSONEncoder.hermit.encode(backup)
            let url = fileURL

            var writeError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &writeError) { coordURL in
                try? data.write(to: coordURL, options: .atomic)
            }
            if let writeError {
                print("Failed to save data: \(writeError)")
            }
        } catch {
            print("Failed to save data: \(error)")
        }
    }

    // MARK: - Host CRUD

    func addHost(_ host: Host) {
        hosts.append(host)
        save()
    }

    func deleteHost(_ host: Host) {
        sessions.removeAll { $0.hostID == host.id }
        tmuxShortcuts.removeAll { $0.hostID == host.id }
        hosts.removeAll { $0.id == host.id }
        save()
    }

    func host(for session: Session) -> Host? {
        hosts.first { $0.id == session.hostID }
    }

    // MARK: - Session CRUD

    func addSession(_ session: Session) {
        sessions.append(session)
        save()
    }

    func deleteSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    func sessions(for host: Host) -> [Session] {
        sessions.filter { $0.hostID == host.id }
    }

    // MARK: - tmux Shortcuts

    func host(for shortcut: TmuxShortcut) -> Host? {
        hosts.first { $0.id == shortcut.hostID }
    }

    func favoriteTmuxShortcuts(limit: Int = 12) -> [TmuxShortcut] {
        Array(
            tmuxShortcuts
                .filter(\.isFavorite)
                .sorted(by: compareShortcutsByRecentUse)
                .prefix(limit)
        )
    }

    func frequentTmuxShortcuts(limit: Int = 8) -> [TmuxShortcut] {
        Array(
            tmuxShortcuts
                .filter { !$0.isFavorite && $0.visitCount > 0 }
                .sorted { lhs, rhs in
                    if lhs.visitCount != rhs.visitCount {
                        return lhs.visitCount > rhs.visitCount
                    }
                    return lhs.lastVisitedAt > rhs.lastVisitedAt
                }
                .prefix(limit)
        )
    }

    func isFavorite(_ shortcut: TmuxShortcut) -> Bool {
        guard let index = tmuxShortcuts.firstIndex(where: { $0.matches(shortcut) }) else {
            return false
        }
        return tmuxShortcuts[index].isFavorite
    }

    func toggleFavorite(_ shortcut: TmuxShortcut) {
        upsert(shortcut) { existing in
            existing.isFavorite.toggle()
            existing.lastVisitedAt = Date()
        }
        save()
    }

    func recordVisit(_ shortcut: TmuxShortcut) {
        upsert(shortcut) { existing in
            existing.visitCount += 1
            existing.lastVisitedAt = Date()
        }
        pruneTmuxShortcuts()
        save()
    }

    private func upsert(_ shortcut: TmuxShortcut, update: (inout TmuxShortcut) -> Void) {
        var updated = shortcut
        if let index = tmuxShortcuts.firstIndex(where: { $0.matches(shortcut) }) {
            updated = tmuxShortcuts[index]
            updated.updateMetadata(from: shortcut)
            update(&updated)
            tmuxShortcuts[index] = updated
        } else {
            update(&updated)
            tmuxShortcuts.append(updated)
        }
    }

    private func pruneTmuxShortcuts() {
        let favoriteIDs = Set(tmuxShortcuts.filter(\.isFavorite).map(\.id))
        let recentIDs = Set(tmuxShortcuts.sorted(by: compareShortcutsByRecentUse).prefix(40).map(\.id))
        tmuxShortcuts.removeAll { !favoriteIDs.contains($0.id) && !recentIDs.contains($0.id) }
    }

    private func compareShortcutsByRecentUse(_ lhs: TmuxShortcut, _ rhs: TmuxShortcut) -> Bool {
        if lhs.lastVisitedAt != rhs.lastVisitedAt {
            return lhs.lastVisitedAt > rhs.lastVisitedAt
        }
        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
    }

    private func migrateHost(_ host: Host) -> Host {
        var host = host
        // Always sync ribbon configs to current defaults
        // During active development, this ensures all hosts pick up button changes
        host.ribbonConfigs = RibbonConfig.presets
        return host
    }

    private func migrateReverseTunnelProfile(
        hosts: [Host],
        sessions: [Session],
        shortcuts: [TmuxShortcut]
    ) -> (hosts: [Host], sessions: [Session], shortcuts: [TmuxShortcut], didChange: Bool) {
        guard let sourceHost = hosts.first(where: isKnownMacProfile) else {
            return (hosts, sessions, shortcuts, false)
        }

        let obsoleteHostIDs = Set(
            hosts
                .filter(isKnownMacProfile)
                .map(\.id)
        ).subtracting([Self.reverseTunnelMacHostID])

        let tunnelHost = reverseTunnelMacHost(from: sourceHost)
        var didChange = !obsoleteHostIDs.isEmpty

        var migratedHosts = hosts.filter { host in
            !isKnownMacProfile(host) || host.id == Self.reverseTunnelMacHostID
        }

        if let index = migratedHosts.firstIndex(where: { $0.id == Self.reverseTunnelMacHostID }) {
            if !isSameReverseTunnelHost(migratedHosts[index], tunnelHost) {
                migratedHosts[index] = tunnelHost
                didChange = true
            }
        } else {
            migratedHosts.append(tunnelHost)
            didChange = true
        }

        var migratedSessions = sessions
        for index in migratedSessions.indices where obsoleteHostIDs.contains(migratedSessions[index].hostID) {
            migratedSessions[index].hostID = Self.reverseTunnelMacHostID
            didChange = true
        }

        var migratedShortcuts = shortcuts
        for index in migratedShortcuts.indices {
            if obsoleteHostIDs.contains(migratedShortcuts[index].hostID) {
                migratedShortcuts[index].hostID = Self.reverseTunnelMacHostID
                didChange = true
            }
            if migratedShortcuts[index].hostID == Self.reverseTunnelMacHostID,
               migratedShortcuts[index].hostDisplayName != tunnelHost.displayName {
                migratedShortcuts[index].hostDisplayName = tunnelHost.displayName
                didChange = true
            }
        }

        let dedupedShortcuts = deduplicatedTmuxShortcuts(migratedShortcuts)
        if dedupedShortcuts.didChange {
            migratedShortcuts = dedupedShortcuts.shortcuts
            didChange = true
        }

        return (migratedHosts, migratedSessions, migratedShortcuts, didChange)
    }

    private func deduplicatedTmuxShortcuts(_ shortcuts: [TmuxShortcut]) -> (shortcuts: [TmuxShortcut], didChange: Bool) {
        var deduped: [TmuxShortcut] = []
        var didChange = false

        for shortcut in shortcuts {
            if let index = deduped.firstIndex(where: { $0.matches(shortcut) }) {
                deduped[index].mergeMetadata(from: shortcut)
                didChange = true
            } else {
                deduped.append(shortcut)
            }
        }

        return (deduped, didChange)
    }

    private func isKnownMacProfile(_ host: Host) -> Bool {
        if host.id == Self.reverseTunnelMacHostID || host.id == Self.obsoleteVPNMacHostID {
            return true
        }

        if host.displayName == "This Mac" || host.displayName == "This Mac VPN" {
            return true
        }

        return host.username == "raghu" &&
            (host.hostname == "192.168.86.195" || host.hostname == "10.221.12.198")
    }

    private func reverseTunnelMacHost(from sourceHost: Host) -> Host {
        Host(
            id: Self.reverseTunnelMacHostID,
            displayName: "This Mac via raghudt",
            hostname: "127.0.0.1",
            port: 22220,
            username: sourceHost.username,
            privateKeyRef: sourceHost.privateKeyRef,
            jumpHost: SSHJumpHost(
                hostname: "10.110.49.244",
                port: 22,
                username: "raghupathyk",
                privateKeyRef: sourceHost.privateKeyRef
            ),
            defaultTmuxSessionName: sourceHost.defaultTmuxSessionName,
            ribbonConfigs: sourceHost.ribbonConfigs,
            createdAt: sourceHost.createdAt
        )
    }

    private func isSameReverseTunnelHost(_ lhs: Host, _ rhs: Host) -> Bool {
        lhs.displayName == rhs.displayName &&
            lhs.hostname == rhs.hostname &&
            lhs.port == rhs.port &&
            lhs.username == rhs.username &&
            lhs.privateKeyRef == rhs.privateKeyRef &&
            lhs.jumpHost == rhs.jumpHost &&
            lhs.defaultTmuxSessionName == rhs.defaultTmuxSessionName
    }

    private func createFileIfNeeded() {
        // Only create a seed file for local-only storage (no iCloud).
        // When iCloud is available, we wait for the download instead.
        guard iCloudURL == nil else { return }
        if !FileManager.default.fileExists(atPath: localFileURL.path) {
            save()
        }
    }

    // MARK: - iCloud Sync

    private func migrateLocalToiCloudIfNeeded() {
        guard let iCloudURL else { return }

        // If local file exists but iCloud file doesn't, migrate
        if FileManager.default.fileExists(atPath: localFileURL.path),
           !FileManager.default.fileExists(atPath: iCloudURL.path) {
            do {
                let data = try Data(contentsOf: localFileURL)
                try data.write(to: iCloudURL, options: .atomic)
                try FileManager.default.removeItem(at: localFileURL)
            } catch {
                print("Failed to migrate to iCloud: \(error)")
            }
        }
    }

    private func startWatchingForChanges() {
        guard iCloudURL != nil else { return }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "hermit-data.json")

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.load()
        }

        query.start()
        metadataQuery = query
    }
}

struct BackupData: Codable {
    var version: Int
    var exportedAt: Date
    var hosts: [Host]
    var sessions: [Session]
    var tmuxShortcuts: [TmuxShortcut]

    init(
        version: Int,
        exportedAt: Date,
        hosts: [Host],
        sessions: [Session],
        tmuxShortcuts: [TmuxShortcut] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.hosts = hosts
        self.sessions = sessions
        self.tmuxShortcuts = tmuxShortcuts
    }

    enum CodingKeys: String, CodingKey {
        case version, exportedAt, hosts, sessions, tmuxShortcuts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        hosts = try c.decode([Host].self, forKey: .hosts)
        sessions = try c.decode([Session].self, forKey: .sessions)
        tmuxShortcuts = (try? c.decode([TmuxShortcut].self, forKey: .tmuxShortcuts)) ?? []
    }
}

enum TmuxShortcutKind: String, Codable, Hashable {
    case window
    case pane
}

struct TmuxShortcut: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: TmuxShortcutKind
    var hostID: UUID
    var hostDisplayName: String
    var sessionID: String
    var sessionName: String
    var windowID: String
    var windowIndex: Int
    var windowName: String
    var paneID: String?
    var paneIndex: Int?
    var paneCommand: String?
    var isFavorite: Bool
    var visitCount: Int
    var lastVisitedAt: Date

    init(
        id: UUID = UUID(),
        kind: TmuxShortcutKind,
        host: Host,
        session: TmuxSession,
        window: TmuxWindow,
        pane: TmuxPane? = nil,
        isFavorite: Bool = false,
        visitCount: Int = 0,
        lastVisitedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.hostID = host.id
        self.hostDisplayName = host.displayName
        self.sessionID = session.id
        self.sessionName = session.name
        self.windowID = window.id
        self.windowIndex = window.index
        self.windowName = window.name
        self.paneID = pane?.id
        self.paneIndex = pane?.index
        self.paneCommand = pane?.currentCommand
        self.isFavorite = isFavorite
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }

    var displayTitle: String {
        switch kind {
        case .window:
            return windowName
        case .pane:
            if let paneCommand, !paneCommand.isEmpty {
                return paneCommand
            }
            if let paneIndex {
                return "Pane \(paneIndex)"
            }
            return windowName
        }
    }

    var displaySubtitle: String {
        let target: String
        switch kind {
        case .window:
            target = "\(sessionName) / #\(windowIndex)"
        case .pane:
            target = "\(sessionName) / \(windowName) / #\(paneIndex ?? 0)"
        }
        return "\(hostDisplayName) - \(target)"
    }

    var systemImage: String {
        kind == .window ? "rectangle.split.3x1" : "terminal"
    }

    func matches(_ other: TmuxShortcut) -> Bool {
        guard kind == other.kind,
              hostID == other.hostID,
              sessionName == other.sessionName else {
            return false
        }

        let sameWindowID = !windowID.isEmpty && windowID == other.windowID
        let sameWindowFallback = windowName == other.windowName && windowIndex == other.windowIndex
        guard sameWindowID || sameWindowFallback else { return false }

        switch kind {
        case .window:
            return true
        case .pane:
            let samePaneID = paneID != nil && paneID == other.paneID
            let samePaneFallback = paneIndex != nil && paneIndex == other.paneIndex
            return samePaneID || samePaneFallback
        }
    }

    mutating func updateMetadata(from shortcut: TmuxShortcut) {
        hostDisplayName = shortcut.hostDisplayName
        sessionID = shortcut.sessionID
        sessionName = shortcut.sessionName
        windowID = shortcut.windowID
        windowIndex = shortcut.windowIndex
        windowName = shortcut.windowName
        paneID = shortcut.paneID
        paneIndex = shortcut.paneIndex
        paneCommand = shortcut.paneCommand
    }

    mutating func mergeMetadata(from shortcut: TmuxShortcut) {
        if shortcut.lastVisitedAt >= lastVisitedAt {
            updateMetadata(from: shortcut)
        }
        isFavorite = isFavorite || shortcut.isFavorite
        visitCount = max(visitCount, shortcut.visitCount)
        if shortcut.lastVisitedAt > lastVisitedAt {
            lastVisitedAt = shortcut.lastVisitedAt
        }
    }
}

extension JSONEncoder {
    static let hermit: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let hermit: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
