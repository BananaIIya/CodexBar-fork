import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// The Codex ledger keeps one scan inventory and lookback per database, so each Codex home
/// needs its own database. `~/.codex` keeps the original file; other homes in the default
/// cache directory get `cost-usage/codex-homes/<home key>/`. Callers that pass a different cache root
/// already own an isolated store and are left unchanged.
enum CodexHomeCostStoreScope {
    static let directoryName = "codex-homes"
    static let markerFilename = "codex-home-path"

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
        // Provider-specific by design: only the Codex ledger keeps one scan inventory per database,
        // so only Codex homes need per-home stores, and `~/.codex` keeps the shared one.
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
        let fileManager = FileManager.default
        // Key on the database, not the folder: until the home store is first written, a later access
        // may still adopt the shared file.
        guard !fileManager.fileExists(atPath: CostUsageStore.databaseURL(cacheRoot: root).path) else { return root }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(Self.markerFilename)
        if !fileManager.fileExists(atPath: marker.path) {
            try? Data(sessionsRoot.path.utf8).write(to: marker)
        }
        // A custom home never uses the shared file, which `~/.codex` may own. If the copy is not made,
        // the home store starts empty and catches up from session files once.
        self.adoptSharedStoreIfOwned(sharedCacheRoot: base, homeCacheRoot: root, options: options)
        self.pruneMissingHomeStores(in: root.deletingLastPathComponent(), keeping: root)
        return root
    }

    enum Adoption: Equatable {
        case adopted
        /// No shared file, or it belongs to other roots.
        case notApplicable
        /// The shared file belongs to this home but could not be copied.
        case copyFailed
        /// Ownership could not be read (busy past the timeout, or the file would not open).
        case unknown
    }

    /// Before per-home stores, a custom-home user's history lived in the shared file. Copy it into the
    /// new home store when its saved Codex roots are exactly this home's roots. The shared file is only
    /// read, never moved, deleted or checkpointed, because the app and the CLI may both have it open;
    /// `~/.codex` keeps using it and its root validation rejects another home's rows and rebuilds.
    @discardableResult
    static func adoptSharedStoreIfOwned(
        sharedCacheRoot: URL,
        homeCacheRoot: URL,
        options: CostUsageScanner.Options) -> Adoption
    {
        let fileManager = FileManager.default
        let shared = CostUsageStore.databaseURL(cacheRoot: sharedCacheRoot)
        let target = CostUsageStore.databaseURL(cacheRoot: homeCacheRoot)
        let expectedRoots = Set(CostUsageScanner.codexRootsFingerprint(options: options).keys)
        guard !expectedRoots.isEmpty, fileManager.fileExists(atPath: shared.path),
              !fileManager.fileExists(atPath: target.path)
        else { return .notApplicable }
        // Read-write without create, so a WAL file without sidecars opens like any store connection
        // (a read-only open cannot create them). This connection only reads; its close is the same
        // passive checkpoint every store connection runs.
        var source: OpaquePointer?
        guard sqlite3_open_v2(shared.path, &source, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let source else {
            sqlite3_close_v2(source)
            return .unknown
        }
        defer { sqlite3_close_v2(source) }
        sqlite3_busy_timeout(source, Self.adoptionBusyTimeoutMilliseconds)
        _ = sqlite3_exec(source, "PRAGMA query_only=1", nil, nil, nil)
        // One read transaction covers the ownership check and the copy, so both see the same snapshot.
        guard sqlite3_exec(source, "BEGIN", nil, nil, nil) == SQLITE_OK else { return .unknown }
        defer { sqlite3_exec(source, "COMMIT", nil, nil, nil) }
        switch Self.storedRootsMatch(source, expectedRoots: expectedRoots) {
        case .none: return .unknown
        case .some(false): return .notApplicable
        case .some(true): break
        }
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).adopting")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            #if DEBUG
            if CostUsageStoreTestHooks.current.codexHomeAdoptionCopyFailure { throw CocoaError(.fileWriteUnknown) }
            #endif
            try fileManager.createDirectory(
                at: temporary.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Self.backup(source, to: temporary)
            // Fails instead of replacing if another process finished its copy first.
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            if fileManager.fileExists(atPath: target.path) { return .adopted }
            CostUsageStore.log.warning("Codex home store copy failed: \(error.localizedDescription)")
            return .copyFailed
        }
        return .adopted
    }

    static let adoptionBusyTimeoutMilliseconds: Int32 = 2000

    /// `nil` when the shared file is busy; another failure means it holds no usable ledger.
    private static func storedRootsMatch(_ database: OpaquePointer, expectedRoots: Set<String>) -> Bool? {
        var statement: OpaquePointer?
        var result = sqlite3_prepare_v2(database, "SELECT payload FROM scan_metadata WHERE id = 1", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        if result == SQLITE_OK {
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_ROW else { return Self.isBusy(result) ? nil : false }
        guard let bytes = sqlite3_column_blob(statement, 0),
              let metadata = try? JSONDecoder().decode(
                  CostUsageStoreMetadata.self,
                  from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))),
              metadata.lastScanUnixMs > 0,
              let roots = metadata.rootMtimes
        else { return false }
        return Set(roots.keys) == expectedRoots
    }

    private static func isBusy(_ result: Int32) -> Bool {
        result & 0xFF == SQLITE_BUSY || result & 0xFF == SQLITE_LOCKED
    }

    /// The online backup API copies a consistent snapshot while other processes read or write.
    private static func backup(_ source: OpaquePointer, to destination: URL) throws {
        var copy: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(destination.path, &copy, flags, nil) == SQLITE_OK, let copy else {
            sqlite3_close_v2(copy)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(copy) }
        guard let backup = sqlite3_backup_init(copy, "main", source, "main") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(step == SQLITE_DONE ? finish : step))
        }
    }

    /// A store whose Codex home folder is gone is removed only after this long untouched, so a
    /// briefly unmounted or renamed home keeps its history.
    static let missingHomeGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    /// Runs when a home store is created. Stores of existing homes are never removed automatically,
    /// so growth is bounded by the user's Codex homes; clearing the cost cache removes them all.
    /// A store whose home folder is gone is removed once untouched for `missingHomeGracePeriod`.
    static func pruneMissingHomeStores(in directory: URL, keeping current: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries where entry.standardizedFileURL.path != current.standardizedFileURL.path {
            let modified = Self.lastWrite(database: CostUsageStore.databaseURL(cacheRoot: entry))
            if now.timeIntervalSince(modified) > Self.missingHomeGracePeriod, Self.homeIsMissing(storeRoot: entry) {
                try? fileManager.removeItem(at: entry)
            }
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
    static func lastWrite(database: URL) -> Date {
        [database.path, database.path + "-wal", database.path + "-shm"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
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
