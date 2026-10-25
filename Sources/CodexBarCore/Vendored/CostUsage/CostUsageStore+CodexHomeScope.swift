import Foundation

/// The Codex ledger keeps one scan inventory and lookback per database, so each Codex home
/// needs its own database. `~/.codex` keeps the original file; other homes in the default
/// cache directory get `cost-usage/codex-homes/<home key>/`. Callers that pass an explicit cache root
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
        guard options.cacheRoot == defaults.cacheRoot,
              let sessionsRoot = CostUsageScanner.codexSessionsRoots(options: options).first?.standardizedFileURL,
              sessionsRoot.path != defaults.codexSessionsRoot.standardizedFileURL.path
        else { return options.cacheRoot }
        let base = options.cacheRoot ?? Self.defaultCacheRoot()
        return self.prepareHomeCacheRoot(base: base, sessionsRoot: sessionsRoot)
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

    private static func defaultCacheRoot() -> URL {
        CostUsageStore.databaseURL(cacheRoot: nil).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func prepareHomeCacheRoot(base: URL, sessionsRoot: URL) -> URL {
        // Inside `cost-usage/` so clearing the cost cache also clears every home store.
        let homesDirectory = CostUsageStore.databaseURL(cacheRoot: base).deletingLastPathComponent()
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        let root = homesDirectory.appendingPathComponent(Self.fingerprint(sessionsRoot.path), isDirectory: true)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: root.path) else { return root }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(sessionsRoot.path.utf8).write(to: root.appendingPathComponent(Self.markerFilename))
        self.pruneHomeStores(in: homesDirectory, keeping: root)
        return root
    }

    /// Runs only when a new home store is created: drops stores whose Codex home is gone,
    /// then the least recently written stores beyond the bound.
    private static func pruneHomeStores(in directory: URL, keeping current: URL) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        var retained: [(url: URL, modified: Date)] = []
        for entry in entries where entry.standardizedFileURL.path != current.standardizedFileURL.path {
            let marker = entry.appendingPathComponent(Self.markerFilename)
            if let data = try? Data(contentsOf: marker),
               let homeSessionsPath = String(data: data, encoding: .utf8),
               !fileManager.fileExists(atPath: URL(fileURLWithPath: homeSessionsPath).deletingLastPathComponent().path)
            {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let database = CostUsageStore.databaseURL(cacheRoot: entry)
            let modified = (try? fileManager.attributesOfItem(atPath: database.path)[.modificationDate] as? Date)
                ?? .distantPast
            retained.append((entry, modified))
        }
        let excess = retained.count + 1 - Self.maximumHomeStores
        guard excess > 0 else { return }
        for entry in retained.sorted(by: { $0.modified < $1.modified }).prefix(excess) {
            try? fileManager.removeItem(at: entry.url)
        }
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
