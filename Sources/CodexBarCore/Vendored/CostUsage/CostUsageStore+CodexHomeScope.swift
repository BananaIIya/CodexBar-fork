import Foundation

/// The Codex ledger keeps one scan inventory and lookback per database, so each Codex home
/// needs its own database. `~/.codex` keeps the original file; other homes in the default
/// cache directory get `cost-usage/codex-homes/<home key>/`. Callers that pass a different cache root
/// already own an isolated store and are left unchanged.
enum CodexHomeCostStoreScope {
    static let directoryName = "codex-homes"
    static let markerFilename = "codex-home-path"
    /// Home stores are derived data. This soft bound keeps stale or one-off homes from
    /// accumulating; see `pruneHomeStores` for why recent stores may exceed it.
    static let maximumHomeStores = 8

    struct Defaults: Sendable {
        var cacheRoot: URL?
        var codexSessionsRoot: URL
    }

    static func cacheRoot(options: CostUsageScanner.Options) -> URL? {
        let defaults = self.defaults()
        guard self.isDefaultCacheRoot(options.cacheRoot, defaultCacheRoot: defaults.cacheRoot),
              let sessionsRoot = CostUsageScanner.codexSessionsRoots(options: options).first?.standardizedFileURL,
              sessionsRoot.path != defaults.codexSessionsRoot.standardizedFileURL.path
        else { return options.cacheRoot }
        let base = options.cacheRoot ?? defaults.cacheRoot ?? Self.productionCacheRoot()
        return self.prepareHomeCacheRoot(base: base, sessionsRoot: sessionsRoot, options: options)
    }

    /// The spend dashboard passes the production root explicitly, so compare paths, not optionals.
    static func isDefaultCacheRoot(_ cacheRoot: URL?, defaultCacheRoot: URL?) -> Bool {
        let resolve = { (root: URL?) in (root ?? Self.productionCacheRoot()).standardizedFileURL.path }
        return resolve(cacheRoot) == resolve(defaultCacheRoot)
    }

    private static func defaults() -> Defaults {
        #if DEBUG
        if let override = CostUsageStoreTestHooks.current.codexHomeStoreDefaults {
            return override
        }
        #endif
        return Defaults(
            cacheRoot: nil,
            codexSessionsRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true))
    }

    static func productionCacheRoot() -> URL {
        CostUsageStore.databaseURL(cacheRoot: nil).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Where a home's store lives, without creating or adopting anything.
    static func homeCacheRoot(base: URL, sessionsRoot: URL) -> URL {
        // Inside `cost-usage/` so clearing the cost cache also clears every home store.
        CostUsageStore.databaseURL(cacheRoot: base).deletingLastPathComponent()
            .appendingPathComponent(self.directoryName, isDirectory: true)
            .appendingPathComponent(self.fingerprint(sessionsRoot.path), isDirectory: true)
    }

    private static func prepareHomeCacheRoot(
        base: URL,
        sessionsRoot: URL,
        options: CostUsageScanner.Options) -> URL
    {
        let root = self.homeCacheRoot(base: base, sessionsRoot: sessionsRoot)
        let homesDirectory = root.deletingLastPathComponent()
        let fileManager = FileManager.default
        // Key on the database, not the folder: a skipped or interrupted adoption leaves the folder
        // behind, and the next access must retry it before an empty home database is created.
        guard !fileManager.fileExists(atPath: CostUsageStore.databaseURL(cacheRoot: root).path) else { return root }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(Self.markerFilename)
        if !fileManager.fileExists(atPath: marker.path) {
            try? Data(sessionsRoot.path.utf8).write(to: marker)
        }
        switch self.adoptSharedStoreIfOwned(sharedCacheRoot: base, homeCacheRoot: root, options: options) {
        case .deferred:
            // The shared file holds this home's history but cannot move yet. Use it in place, as
            // before per-home stores, rather than start an empty home store; a later access retries.
            return base
        case .adopted, .notApplicable:
            self.pruneHomeStores(in: homesDirectory, keeping: root)
            return root
        }
    }

    enum Adoption: Equatable {
        case adopted
        /// No shared file, or it belongs to other roots.
        case notApplicable
        /// The shared file belongs to this home but is busy or could not be moved.
        case deferred
    }

    /// Before per-home stores, a custom-home user's history lived in the shared file. Move it into
    /// the new home store only when its saved Codex roots are exactly this home's roots. Any other
    /// home, `~/.codex` included, could not reuse those rows anyway: its root validation rejects them
    /// and it rebuilds. Moving keeps one copy and avoids a second large file; the shared path then
    /// starts fresh for whoever uses it next.
    @discardableResult
    static func adoptSharedStoreIfOwned(
        sharedCacheRoot: URL,
        homeCacheRoot: URL,
        options: CostUsageScanner.Options) -> Adoption
    {
        let fileManager = FileManager.default
        let shared = CostUsageStore.databaseURL(cacheRoot: sharedCacheRoot)
        let target = CostUsageStore.databaseURL(cacheRoot: homeCacheRoot)
        guard fileManager.fileExists(atPath: shared.path), !fileManager.fileExists(atPath: target.path)
        else { return .notApplicable }
        let expectedRoots = Set(CostUsageScanner.codexRootsFingerprint(options: options).keys)
        let isOwned = { (view: CostUsageStoreReadView) -> Bool in
            guard let roots = view.roots, view.lastScanUnixMs > 0, !expectedRoots.isEmpty else { return false }
            return Set(roots.keys) == expectedRoots
        }
        if CostUsageStore.isOpenInProcess(databaseURL: shared) {
            // Read through the warm shared store; never checkpoint or close a connection in use.
            let view = CostUsageStoreAccess.readView(
                cacheRoot: sharedCacheRoot,
                calendar: options.calendar,
                purpose: .status)
            return isOwned(view) ? .deferred : .notApplicable
        }
        // Scoped so this store is released before the in-process check below.
        let (owned, checkpointed): (Bool, Bool) = {
            let store = CostUsageStore(cacheRoot: sharedCacheRoot)
            let owned = isOwned(store.syncLoadCodexReadView(calendar: options.calendar, purpose: .status))
            // Always close; the checkpoint empties the WAL so the main file holds every row.
            return (owned, store.syncCheckpointAndClose())
        }()
        guard owned else { return .notApplicable }
        guard checkpointed, !CostUsageStore.isOpenInProcess(databaseURL: shared) else { return .deferred }
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // One rename moves the complete database; the emptied WAL and its index follow.
            try fileManager.moveItem(at: shared, to: target)
        } catch {
            CostUsageStore.log.warning("Codex home store adoption deferred: \(error.localizedDescription)")
            return .deferred
        }
        for (from, to) in zip(Self.sidecars(of: shared), Self.sidecars(of: target))
            where fileManager.fileExists(atPath: from.path)
        {
            try? fileManager.moveItem(at: from, to: to)
        }
        return .adopted
    }

    private static func sidecars(of database: URL) -> [URL] {
        ["-wal", "-shm"].map { URL(fileURLWithPath: database.path + $0) }
    }

    /// A store whose Codex home folder is gone is removed only after this long untouched, so a
    /// briefly unmounted or renamed home keeps its history.
    static let missingHomeGracePeriod: TimeInterval = 7 * 24 * 60 * 60
    /// Beyond `maximumHomeStores`, only stores untouched this long are removed.
    static let staleHomeStoreAge: TimeInterval = 30 * 24 * 60 * 60

    /// Runs when a home store is about to be created. The app and the CLI can each hold a home
    /// store open, and this process cannot see the other's connections, so age is the only signal
    /// that is safe across processes: a store in use is written on every refresh, which updates
    /// the newest mtime of its database, `-wal`, `-shm` and marker. Policy:
    /// - a store whose home folder is gone is removed once untouched for `missingHomeGracePeriod`;
    /// - beyond `maximumHomeStores`, the oldest stores are removed, but only those untouched for
    ///   `staleHomeStoreAge`. Recently touched stores are kept even if that exceeds the bound.
    /// Stores with a live connection in this process and the current store are never removed.
    private static func pruneHomeStores(in directory: URL, keeping current: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var candidates: [(url: URL, modified: Date)] = []
        var keptCount = 1
        for entry in entries where entry.standardizedFileURL.path != current.standardizedFileURL.path {
            let database = CostUsageStore.databaseURL(cacheRoot: entry)
            let modified = Self.lastWrite(database: database, marker: entry.appendingPathComponent(Self.markerFilename))
            let age = now.timeIntervalSince(modified)
            if CostUsageStore.isOpenInProcess(databaseURL: database) {
                keptCount += 1
                continue
            }
            if age > Self.missingHomeGracePeriod, Self.homeIsMissing(storeRoot: entry) {
                try? fileManager.removeItem(at: entry)
                continue
            }
            if age > Self.staleHomeStoreAge {
                candidates.append((entry, modified))
            } else {
                keptCount += 1
            }
        }
        let excess = keptCount + candidates.count - Self.maximumHomeStores
        guard excess > 0 else { return }
        for entry in candidates.sorted(by: { $0.modified < $1.modified }).prefix(excess) {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private static func homeIsMissing(storeRoot: URL) -> Bool {
        guard let data = try? Data(contentsOf: storeRoot.appendingPathComponent(markerFilename)),
              let homeSessionsPath = String(data: data, encoding: .utf8)
        else { return false }
        let home = URL(fileURLWithPath: homeSessionsPath).deletingLastPathComponent()
        return !FileManager.default.fileExists(atPath: home.path)
    }

    /// Under WAL, recent writes may only touch the `-wal` and `-shm` files.
    static func lastWrite(database: URL, marker: URL? = nil) -> Date {
        ([database] + self.sidecars(of: database) + [marker].compactMap(\.self))
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
            .max() ?? .distantPast
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
