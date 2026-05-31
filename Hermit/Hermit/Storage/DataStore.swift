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
    private static let hedgehogHostID = UUID(uuidString: "7D4C3575-55A4-46ED-B543-B7B1D40B0E14")!
    private static let reverseTunnelMacTmuxSocketName: String? = nil
    private static let reverseTunnelMacSessionName = "0"

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
            let migratedHosts = backup.hosts.map { migrateHost($0) }
            let hostsDidChange = zip(backup.hosts, migratedHosts).contains { original, migrated in
                original.displayName != migrated.displayName ||
                    original.hostname != migrated.hostname ||
                    original.port != migrated.port ||
                    original.username != migrated.username ||
                    original.privateKeyRef != migrated.privateKeyRef ||
                    original.jumpHost != migrated.jumpHost ||
                    original.localPortForwards != migrated.localPortForwards ||
                    original.defaultTmuxSessionName != migrated.defaultTmuxSessionName ||
                    original.tmuxSocketName != migrated.tmuxSocketName
            }
            let profileMigration = migrateReverseTunnelProfile(
                hosts: migratedHosts,
                sessions: backup.sessions,
                shortcuts: backup.tmuxShortcuts
            )
            let hedgehogMigration = migrateHedgehogProfile(hosts: profileMigration.hosts)
            let knownHostIDs = Set(hedgehogMigration.hosts.map(\.id))
            let raghudtHostIDs = Set(hedgehogMigration.hosts.filter(isKnownRaghudtProfile).map(\.id))

            let filteredShortcuts = profileMigration.shortcuts.filter { shortcut in
                knownHostIDs.contains(shortcut.hostID) &&
                    !isObsoleteShortcut(shortcut, raghudtHostIDs: raghudtHostIDs)
            }

            self.hosts = hedgehogMigration.hosts
            self.sessions = profileMigration.sessions
            self.tmuxShortcuts = filteredShortcuts

            if hostsDidChange ||
                profileMigration.didChange ||
                hedgehogMigration.didChange ||
                filteredShortcuts.count != profileMigration.shortcuts.count {
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

    func favoriteTmuxShortcuts(limit: Int = 12, kind: TmuxShortcutKind? = nil) -> [TmuxShortcut] {
        Array(
            tmuxShortcuts
                .filter { shortcut in
                    shortcut.isFavorite && (kind.map { shortcut.kind == $0 } ?? true)
                }
                .sorted(by: compareShortcutsByRecentUse)
                .prefix(limit)
        )
    }

    func frequentTmuxShortcuts(limit: Int = 8, kind: TmuxShortcutKind? = nil) -> [TmuxShortcut] {
        Array(
            tmuxShortcuts
                .filter { shortcut in
                    !shortcut.isFavorite &&
                        shortcut.visitCount > 0 &&
                        (kind.map { shortcut.kind == $0 } ?? true)
                }
                .sorted { lhs, rhs in
                    if lhs.visitCount != rhs.visitCount {
                        return lhs.visitCount > rhs.visitCount
                    }
                    return lhs.lastVisitedAt > rhs.lastVisitedAt
                }
                .prefix(limit)
        )
    }

    func removeTmuxShortcut(_ shortcut: TmuxShortcut) {
        let originalCount = tmuxShortcuts.count
        tmuxShortcuts.removeAll { $0.matches(shortcut) }
        if tmuxShortcuts.count != originalCount {
            save()
        }
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

    func reconcileTmuxShortcuts(
        for host: Host,
        sessions: [TmuxSession],
        windowsBySession: [String: [TmuxWindow]],
        panesByWindow: [String: [TmuxPane]]
    ) {
        var reconciled: [TmuxShortcut] = []
        var didChange = false

        for shortcut in tmuxShortcuts {
            guard shortcut.hostID == host.id else {
                reconciled.append(shortcut)
                continue
            }

            guard !isObsoleteShortcut(shortcut, raghudtHostIDs: []) else {
                didChange = true
                continue
            }

            guard let session = sessions.first(where: shortcut.matches(session:)),
                  let windows = windowsBySession[session.id],
                  let window = windows.first(where: shortcut.matches(window:)) else {
                didChange = true
                continue
            }

            var updated = shortcut
            switch shortcut.kind {
            case .window:
                updated.updateMetadata(from: TmuxShortcut(
                    kind: .window,
                    host: host,
                    session: session,
                    window: window
                ))
            case .pane:
                guard let panes = panesByWindow[window.id], !panes.isEmpty else {
                    reconciled.append(shortcut)
                    continue
                }
                guard let pane = panes.first(where: shortcut.matches(pane:)) else {
                    didChange = true
                    continue
                }
                updated.updateMetadata(from: TmuxShortcut(
                    kind: .pane,
                    host: host,
                    session: session,
                    window: window,
                    pane: pane
                ))
            }

            if updated != shortcut {
                didChange = true
            }
            reconciled.append(updated)
        }

        let deduped = deduplicatedTmuxShortcuts(reconciled)
        if deduped.didChange {
            didChange = true
        }

        if didChange {
            tmuxShortcuts = deduped.shortcuts
            save()
        }
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
        tmuxShortcuts.removeAll {
            isObsoleteShortcut($0, raghudtHostIDs: []) ||
                (!favoriteIDs.contains($0.id) && !recentIDs.contains($0.id))
        }
    }

    private func compareShortcutsByRecentUse(_ lhs: TmuxShortcut, _ rhs: TmuxShortcut) -> Bool {
        if lhs.lastVisitedAt != rhs.lastVisitedAt {
            return lhs.lastVisitedAt > rhs.lastVisitedAt
        }
        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
    }

    private func migrateHost(_ host: Host) -> Host {
        var host = host
        if isKnownRaghudtProfile(host), host.defaultTmuxSessionName == "mobile" {
            host.defaultTmuxSessionName = "0"
        }
        if host.id == Self.reverseTunnelMacHostID || host.displayName == "This Mac via raghudt" {
            host.defaultTmuxSessionName = Self.reverseTunnelMacSessionName
            host.tmuxSocketName = Self.reverseTunnelMacTmuxSocketName
        }
        if isKnownHedgehogProfile(host) {
            host = hedgehogHost(from: host)
        }
        // Always sync ribbon configs to current defaults
        // During active development, this ensures all hosts pick up button changes
        host.ribbonConfigs = RibbonConfig.presets
        return host
    }

    private func migrateHedgehogProfile(hosts: [Host]) -> (hosts: [Host], didChange: Bool) {
        let canonicalHost = hedgehogHost(from: hosts.first(where: isKnownHedgehogProfile))
        var migratedHosts = hosts

        if let index = migratedHosts.firstIndex(where: isKnownHedgehogProfile) {
            if !isSameHedgehogHost(migratedHosts[index], canonicalHost) {
                migratedHosts[index] = canonicalHost
                return (migratedHosts, true)
            }
            return (migratedHosts, false)
        }

        migratedHosts.append(canonicalHost)
        return (migratedHosts, true)
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

    private func isKnownRaghudtProfile(_ host: Host) -> Bool {
        host.hostname == "raghudt" ||
            host.hostname == "10.110.49.244" ||
            host.displayName.localizedCaseInsensitiveCompare("raghudt") == .orderedSame
    }

    private func isKnownHedgehogProfile(_ host: Host) -> Bool {
        host.id == Self.hedgehogHostID ||
            (
                host.username == "raghu" &&
                host.hostname == "hedgehog6209.ddns.net" &&
                host.port == 10000
            ) ||
            host.displayName.localizedCaseInsensitiveCompare("Hedgehog") == .orderedSame
    }

    private func isObsoleteShortcut(_ shortcut: TmuxShortcut, raghudtHostIDs: Set<UUID>) -> Bool {
        if raghudtHostIDs.contains(shortcut.hostID), shortcut.sessionName == "mobile" {
            return true
        }

        guard shortcut.hostID == Self.reverseTunnelMacHostID ||
            shortcut.hostDisplayName == "This Mac via raghudt" else {
            return false
        }

        return shortcut.sessionName == "hermit-mobile" || shortcut.sessionName == "mobile"
    }

    private func reverseTunnelMacHost(from sourceHost: Host) -> Host {
        return Host(
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
            defaultTmuxSessionName: Self.reverseTunnelMacSessionName,
            tmuxSocketName: Self.reverseTunnelMacTmuxSocketName,
            ribbonConfigs: sourceHost.ribbonConfigs,
            createdAt: sourceHost.createdAt
        )
    }

    private func hedgehogHost(from sourceHost: Host? = nil) -> Host {
        let sourcePrivateKeyRef = sourceHost?.privateKeyRef.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let privateKeyRef = sourcePrivateKeyRef.isEmpty ? "dev-ssh-key" : sourcePrivateKeyRef

        return Host(
            id: sourceHost?.id ?? Self.hedgehogHostID,
            displayName: "Hedgehog",
            hostname: "hedgehog6209.ddns.net",
            port: 10000,
            username: "raghu",
            privateKeyRef: privateKeyRef,
            localPortForwards: [
                LocalPortForward(
                    localHost: "127.0.0.1",
                    localPort: 3000,
                    remoteHost: "127.0.0.1",
                    remotePort: 3000
                )
            ],
            defaultTmuxSessionName: sourceHost?.defaultTmuxSessionName ?? "0",
            tmuxSocketName: sourceHost?.tmuxSocketName,
            ribbonConfigs: sourceHost?.ribbonConfigs ?? RibbonConfig.presets,
            createdAt: sourceHost?.createdAt ?? Date()
        )
    }

    private func isSameReverseTunnelHost(_ lhs: Host, _ rhs: Host) -> Bool {
        lhs.displayName == rhs.displayName &&
            lhs.hostname == rhs.hostname &&
            lhs.port == rhs.port &&
            lhs.username == rhs.username &&
            lhs.privateKeyRef == rhs.privateKeyRef &&
            lhs.jumpHost == rhs.jumpHost &&
            lhs.localPortForwards == rhs.localPortForwards &&
            lhs.defaultTmuxSessionName == rhs.defaultTmuxSessionName &&
            lhs.tmuxSocketName == rhs.tmuxSocketName
    }

    private func isSameHedgehogHost(_ lhs: Host, _ rhs: Host) -> Bool {
        lhs.displayName == rhs.displayName &&
            lhs.hostname == rhs.hostname &&
            lhs.port == rhs.port &&
            lhs.username == rhs.username &&
            lhs.privateKeyRef == rhs.privateKeyRef &&
            lhs.jumpHost == rhs.jumpHost &&
            lhs.localPortForwards == rhs.localPortForwards &&
            lhs.defaultTmuxSessionName == rhs.defaultTmuxSessionName &&
            lhs.tmuxSocketName == rhs.tmuxSocketName
    }

    private func createFileIfNeeded() {
        // Only create a seed file for local-only storage (no iCloud).
        // When iCloud is available, we wait for the download instead.
        guard iCloudURL == nil else { return }
        if !FileManager.default.fileExists(atPath: localFileURL.path) {
            hosts = migrateHedgehogProfile(hosts: hosts).hosts
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
        windowName
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

    func matches(session: TmuxSession) -> Bool {
        (!sessionID.isEmpty && sessionID == session.id) || sessionName == session.name
    }

    func matches(window: TmuxWindow) -> Bool {
        let sameWindowID = !windowID.isEmpty && windowID == window.id
        let sameWindowFallback = windowName == window.name && windowIndex == window.index
        return sameWindowID || sameWindowFallback || windowName == window.name
    }

    func matches(pane: TmuxPane) -> Bool {
        let samePaneID = paneID != nil && paneID == pane.id
        let samePaneFallback = paneIndex != nil && paneIndex == pane.index
        return samePaneID || samePaneFallback
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
