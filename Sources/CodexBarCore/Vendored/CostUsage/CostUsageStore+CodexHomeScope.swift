import Foundation

/// The Codex ledger keeps one scan inventory and lookback per database, so each Codex home
/// needs its own database. `~/.codex` keeps the original file; other homes in the default
/// cache directory get `cost-usage/codex-homes/<home key>/`. Callers that pass a different cache root
/// already own an isolated store and are left unchanged.
enum CodexHomeCostStoreScope {
    static let directoryName = "codex-homes"
    static let markerFilename = "codex-home-path"
    /// Home stores are derived data. Keep a small bound so stale or one-off homes cannot
    /// accumulate without limit.
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

    private static func prepareHomeCacheRoot(
        base: URL,
        sessionsRoot: URL,
        options: CostUsageScanner.Options) -> URL
    {
        // Inside `cost-usage/` so clearing the cost cache also clears every home store.
        let homesDirectory = CostUsageStore.databaseURL(cacheRoot: base).deletingLastPathComponent()
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        let root = homesDirectory.appendingPathComponent(Self.fingerprint(sessionsRoot.path), isDirectory: true)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: root.path) else { return root }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(sessionsRoot.path.utf8).write(to: root.appendingPathComponent(Self.markerFilename))
        self.adoptSharedStoreIfOwned(sharedCacheRoot: base, homeCacheRoot: root, options: options)
        self.pruneHomeStores(in: homesDirectory, keeping: root)
        return root
    }

    /// Before per-home stores, a custom-home user's history lived in the shared file. Move it into
    /// the new home store only when its saved Codex roots are exactly this home's roots. Any other
    /// home, `~/.codex` included, could not reuse those rows anyway: its root validation rejects them
    /// and it rebuilds. Moving keeps one copy and avoids a second large file; the shared path then
    /// starts fresh for whoever uses it next.
    static func adoptSharedStoreIfOwned(
        sharedCacheRoot: URL,
        homeCacheRoot: URL,
        options: CostUsageScanner.Options)
    {
        let fileManager = FileManager.default
        let shared = CostUsageStore.databaseURL(cacheRoot: sharedCacheRoot)
        let target = CostUsageStore.databaseURL(cacheRoot: homeCacheRoot)
        guard fileManager.fileExists(atPath: shared.path),
              !fileManager.fileExists(atPath: target.path),
              !CostUsageStore.isOpenInProcess(databaseURL: shared)
        else { return }
        let expectedRoots = Set(CostUsageScanner.codexRootsFingerprint(options: options).keys)
        let ownedAndCheckpointed: Bool = {
            let store = CostUsageStore(cacheRoot: sharedCacheRoot)
            let view = store.syncLoadCodexReadView(calendar: options.calendar, purpose: .status)
            // Always close; the checkpoint empties the WAL so the main file holds every row.
            let checkpointed = store.syncCheckpointAndClose()
            guard let roots = view.roots, view.lastScanUnixMs > 0, !expectedRoots.isEmpty else { return false }
            return checkpointed && Set(roots.keys) == expectedRoots
        }()
        guard ownedAndCheckpointed, !CostUsageStore.isOpenInProcess(databaseURL: shared) else { return }
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // One rename moves the complete database; the emptied WAL and its index follow.
            try fileManager.moveItem(at: shared, to: target)
            for (from, to) in zip(Self.sidecars(of: shared), Self.sidecars(of: target))
                where fileManager.fileExists(atPath: from.path)
            {
                try? fileManager.moveItem(at: from, to: to)
            }
        } catch {
            CostUsageStore.log.warning("Codex home store adoption skipped: \(error.localizedDescription)")
        }
    }

    private static func sidecars(of database: URL) -> [URL] {
        ["-wal", "-shm"].map { URL(fileURLWithPath: database.path + $0) }
    }

    /// Runs only when a new home store is created: drops stores whose Codex home is gone,
    /// then the least recently written stores beyond the bound. Stores with a live connection
    /// in this process are never removed.
    private static func pruneHomeStores(in directory: URL, keeping current: URL) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var retained: [(url: URL, modified: Date)] = []
        var openCount = 0
        for entry in entries where entry.standardizedFileURL.path != current.standardizedFileURL.path {
            let database = CostUsageStore.databaseURL(cacheRoot: entry)
            if CostUsageStore.isOpenInProcess(databaseURL: database) {
                openCount += 1
                continue
            }
            let marker = entry.appendingPathComponent(Self.markerFilename)
            if let data = try? Data(contentsOf: marker),
               let homeSessionsPath = String(data: data, encoding: .utf8),
               !fileManager.fileExists(atPath: URL(fileURLWithPath: homeSessionsPath).deletingLastPathComponent().path)
            {
                try? fileManager.removeItem(at: entry)
                continue
            }
            retained.append((entry, Self.lastWrite(database: database)))
        }
        let excess = retained.count + openCount + 1 - Self.maximumHomeStores
        guard excess > 0 else { return }
        for entry in retained.sorted(by: { $0.modified < $1.modified }).prefix(excess) {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    /// Under WAL, recent writes may only touch the `-wal` and `-shm` files.
    static func lastWrite(database: URL) -> Date {
        ([database] + self.sidecars(of: database))
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
