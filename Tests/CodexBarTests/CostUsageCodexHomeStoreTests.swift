import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexHomeStoreTests {
    @Test
    func `alternating codex homes keep their own coverage totals and pending work`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let homeA = env.root.appendingPathComponent("home-a", isDirectory: true)
        let homeB = env.root.appendingPathComponent("home-b", isDirectory: true)
        for index in 0..<3 {
            try Self.writeSession(home: homeA, env: env, day: day, name: "a-\(index).jsonl", tokens: 100 + index)
            try Self.writeSession(home: homeB, env: env, day: day, name: "b-\(index).jsonl", tokens: 10 + index)
        }

        try await Self.withProductionDefaults(env: env) {
            var unbounded = CostUsageScanner.Options(
                cacheRoot: env.cacheRoot,
                codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
            unbounded.refreshMinIntervalSeconds = 0
            var bounded = unbounded
            bounded.maxCodexSessionFileBytes = 1
            bounded.maxCodexScanBytesPerRefresh = 1

            let establishedA = try await Self.establish(home: homeA, now: day, options: unbounded)
            #expect(establishedA.historyCoverageIsEstablished)
            #expect(establishedA.sessionTokens == 303)

            let pendingB = try await Self.snapshot(home: homeB, now: day.addingTimeInterval(1), options: bounded)
            #expect(!pendingB.historyCoverageIsEstablished)
            let fetcher = CostUsageFetcher(cacheRoot: env.cacheRoot)
            let statusB = await fetcher.codexScanCatchUpStatus(codexHomePath: homeB.path, historyDays: 1, now: day)
            #expect(statusB.pending)

            // A first scan after lost state is never established, so this needs A's retained scan state.
            let againA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(2), options: unbounded)
            #expect(againA.historyCoverageIsEstablished)
            #expect(againA.sessionTokens == establishedA.sessionTokens)
            #expect(againA.last30DaysTokens == establishedA.last30DaysTokens)

            let statusBAfterA = await fetcher.codexScanCatchUpStatus(
                codexHomePath: homeB.path,
                historyDays: 1,
                now: day)
            #expect(statusBAfterA.pending)
            #expect(statusBAfterA.progressKey == statusB.progressKey)

            let finishedB = try await Self.establish(home: homeB, now: day.addingTimeInterval(3), options: unbounded)
            #expect(finishedB.historyCoverageIsEstablished)
            #expect(finishedB.sessionTokens == 33)
            let finalA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(4), options: unbounded)
            #expect(finalA.historyCoverageIsEstablished)
            #expect(finalA.sessionTokens == establishedA.sessionTokens)
        }
    }

    @Test
    func `default codex home keeps the shared database file`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeSession(home: env.codexHomeRoot, env: env, day: day, name: "default.jsonl", tokens: 42)

        try await Self.withProductionDefaults(env: env) {
            var options = CostUsageScanner.Options(
                cacheRoot: env.cacheRoot,
                codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
            options.refreshMinIntervalSeconds = 0
            let snapshot = try await Self.snapshot(home: env.codexHomeRoot, now: day, options: options)
            #expect(snapshot.sessionTokens == 42)

            let costUsageDirectory = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot).deletingLastPathComponent()
            #expect(FileManager.default.fileExists(atPath: CostUsageStore.databaseURL(cacheRoot: env.cacheRoot).path))
            #expect(!FileManager.default.fileExists(
                atPath: costUsageDirectory.appendingPathComponent(CodexHomeCostStoreScope.directoryName).path))
            options.codexSessionsRoot = env.codexSessionsRoot
            #expect(CodexHomeCostStoreScope.cacheRoot(options: options) == env.cacheRoot)
        }
    }

    @Test
    func `explicit cache roots keep caller owned codex stores`() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explicit-\(UUID().uuidString)")
        let options = CostUsageScanner.Options(
            codexSessionsRoot: root.appendingPathComponent("home/sessions"),
            cacheRoot: root.appendingPathComponent("cache"))
        #expect(CodexHomeCostStoreScope.cacheRoot(options: options) == options.cacheRoot)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func `explicit production cache root is scoped like the default`() throws {
        let production = CodexHomeCostStoreScope.productionCacheRoot()
        #expect(CodexHomeCostStoreScope.isDefaultCacheRoot(production, defaultCacheRoot: nil))
        #expect(CodexHomeCostStoreScope.isDefaultCacheRoot(
            production.appendingPathComponent("x/..", isDirectory: true),
            defaultCacheRoot: nil))
        #expect(!CodexHomeCostStoreScope.isDefaultCacheRoot(
            production.appendingPathComponent("cost-usage/accounts/live", isDirectory: true),
            defaultCacheRoot: nil))

        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        try Self.withProductionDefaults(env: env) {
            // The spend dashboard passes its root explicitly; a differently spelled default is still default.
            let options = CostUsageScanner.Options(
                codexSessionsRoot: env.root.appendingPathComponent("home-a/sessions"),
                cacheRoot: env.cacheRoot.appendingPathComponent("x/..", isDirectory: true))
            let root = try #require(CodexHomeCostStoreScope.cacheRoot(options: options))
            #expect(root.deletingLastPathComponent().lastPathComponent == CodexHomeCostStoreScope.directoryName)
        }
    }

    @Test
    func `custom home copies the shared store it already owns`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let homeA = env.root.appendingPathComponent("home-a", isDirectory: true)
        for index in 0..<3 {
            try Self.writeSession(home: homeA, env: env, day: day, name: "a-\(index).jsonl", tokens: 100 + index)
        }
        let unbounded = Self.unboundedOptions(env: env)

        // Without the defaults hook this cache root is caller-owned, so A writes the shared file as before.
        let before = try await Self.establish(home: homeA, now: day, options: unbounded)
        #expect(before.historyCoverageIsEstablished)
        CostUsageStoreAccess.releaseSharedStoresForTesting(cacheRoot: env.cacheRoot)
        let shared = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot)
        let sharedInode = try Self.inode(shared)
        let sharedBytes = try Data(contentsOf: shared)

        try await Self.withProductionDefaults(env: env) {
            // A first scan of an empty store is never established, so coverage must come from the copy.
            let after = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(1), options: unbounded)
            #expect(after.historyCoverageIsEstablished)
            #expect(after.sessionTokens == before.sessionTokens)
            #expect(after.last30DaysTokens == before.last30DaysTokens)
            let homeOptions = Self.options(unbounded, home: homeA)
            let homeRoot = try #require(CodexHomeCostStoreScope.cacheRoot(options: homeOptions))
            #expect(homeRoot != env.cacheRoot)
            #expect(try Self.inode(CostUsageStore.databaseURL(cacheRoot: homeRoot)) != sharedInode)
            #expect(try Self.inode(shared) == sharedInode)
            #expect(try Data(contentsOf: shared) == sharedBytes)
        }
    }

    @Test
    func `custom home leaves a shared store owned by the default home`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let homeA = env.root.appendingPathComponent("home-a", isDirectory: true)
        try Self.writeSession(home: env.codexHomeRoot, env: env, day: day, name: "default.jsonl", tokens: 42)
        try Self.writeSession(home: homeA, env: env, day: day, name: "a.jsonl", tokens: 7)
        let options = Self.unboundedOptions(env: env)

        try await Self.withProductionDefaults(env: env) {
            let defaultSnapshot = try await Self.establish(home: env.codexHomeRoot, now: day, options: options)
            #expect(defaultSnapshot.sessionTokens == 42)
            CostUsageStoreAccess.releaseSharedStoresForTesting(cacheRoot: env.cacheRoot)
            let shared = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot)
            let sharedInode = try Self.inode(shared)

            let homeOptions = Self.options(options, home: homeA)
            let probeRoot = env.root.appendingPathComponent("probe", isDirectory: true)
            #expect(CodexHomeCostStoreScope.adoptSharedStoreIfOwned(
                sharedCacheRoot: env.cacheRoot,
                homeCacheRoot: probeRoot,
                options: homeOptions) == .notApplicable)
            #expect(!FileManager.default.fileExists(atPath: CostUsageStore.databaseURL(cacheRoot: probeRoot).path))

            let snapshotA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(1), options: options)
            #expect(snapshotA.sessionTokens == 7)
            #expect(try Self.inode(shared) == sharedInode)
            let againDefault = try await Self.snapshot(
                home: env.codexHomeRoot,
                now: day.addingTimeInterval(2),
                options: options)
            #expect(againDefault.historyCoverageIsEstablished)
            #expect(againDefault.sessionTokens == 42)
        }
    }

    @Test
    func `busy ownership check never uses the shared store`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let (homeA, day, before, homeOptions) = try await Self.establishSharedHomeA(env: env)
        let unbounded = Self.unboundedOptions(env: env)
        let shared = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot)

        try await Self.withProductionDefaults(env: env) {
            // An exclusive-mode writer locks every other connection out, as a busy store would.
            var holder: OpaquePointer?
            #expect(sqlite3_open_v2(shared.path, &holder, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            #expect(sqlite3_exec(holder, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
            let homeRoot = CodexHomeCostStoreScope.homeCacheRoot(
                base: env.cacheRoot,
                sessionsRoot: homeOptions.codexSessionsRoot!.standardizedFileURL)
            let probeRoot = env.root.appendingPathComponent("probe", isDirectory: true)
            #expect(CodexHomeCostStoreScope.adoptSharedStoreIfOwned(
                sharedCacheRoot: env.cacheRoot,
                homeCacheRoot: probeRoot,
                options: homeOptions) == .unknown)
            // Unknown ownership routes to the home store, never the shared file.
            #expect(CodexHomeCostStoreScope.cacheRoot(options: homeOptions) == homeRoot)
            sqlite3_exec(holder, "COMMIT", nil, nil, nil)
            sqlite3_close_v2(holder)

            let after = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(1), options: unbounded)
            #expect(after.historyCoverageIsEstablished)
            #expect(after.sessionTokens == before.sessionTokens)
        }
    }

    @Test
    func `unreadable shared store is unknown ownership and never the shared root`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let (_, _, _, homeOptions) = try await Self.establishSharedHomeA(env: env)
        let shared = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot)

        try await Self.withProductionDefaults(env: env) {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shared.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: shared.path) }
            let probeRoot = env.root.appendingPathComponent("probe", isDirectory: true)
            #expect(CodexHomeCostStoreScope.adoptSharedStoreIfOwned(
                sharedCacheRoot: env.cacheRoot,
                homeCacheRoot: probeRoot,
                options: homeOptions) == .unknown)
            #expect(CodexHomeCostStoreScope.cacheRoot(options: homeOptions) != env.cacheRoot)
        }
    }

    @Test
    func `failed copy uses the shared store and is retried on the next access`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let (homeA, day, before, homeOptions) = try await Self.establishSharedHomeA(env: env)
        let unbounded = Self.unboundedOptions(env: env)

        try await Self.withProductionDefaults(env: env) {
            let homeRoot = CodexHomeCostStoreScope.homeCacheRoot(
                base: env.cacheRoot,
                sessionsRoot: homeOptions.codexSessionsRoot!.standardizedFileURL)
            let databaseDirectory = CostUsageStore.databaseURL(cacheRoot: homeRoot).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
            // A read-only folder makes the copy fail, like a full disk would.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: databaseDirectory.path)
            let failed = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(1), options: unbounded)
            #expect(failed.historyCoverageIsEstablished)
            #expect(failed.sessionTokens == before.sessionTokens)
            #expect(CodexHomeCostStoreScope.cacheRoot(options: homeOptions) == env.cacheRoot)

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: databaseDirectory.path)
            #expect(CodexHomeCostStoreScope.cacheRoot(options: homeOptions) == homeRoot)
            #expect(try FileManager.default.contentsOfDirectory(atPath: databaseDirectory.path)
                .allSatisfy { !$0.hasSuffix(".adopting") })
            let after = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(1), options: unbounded)
            #expect(after.historyCoverageIsEstablished)
            #expect(after.sessionTokens == before.sessionTokens)
        }
    }

    @Test
    func `pruning removes only stores of homes missing past the grace period`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let homes = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot).deletingLastPathComponent()
            .appendingPathComponent(CodexHomeCostStoreScope.directoryName, isDirectory: true)
        func seed(_ name: String, homeExists: Bool, age: TimeInterval, walAge: TimeInterval? = nil) throws {
            let home = env.root.appendingPathComponent("home-\(name)", isDirectory: true)
            if homeExists {
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            }
            let store = homes.appendingPathComponent(name)
            let database = CostUsageStore.databaseURL(cacheRoot: store)
            try FileManager.default.createDirectory(
                at: database.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data().write(to: database)
            try Data(home.appendingPathComponent("sessions").path.utf8)
                .write(to: store.appendingPathComponent(CodexHomeCostStoreScope.markerFilename))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)],
                ofItemAtPath: database.path)
            if let walAge {
                let wal = URL(fileURLWithPath: database.path + "-wal")
                try Data().write(to: wal)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: -walAge)],
                    ofItemAtPath: wal.path)
            }
        }
        let grace = CodexHomeCostStoreScope.missingHomeGracePeriod
        try seed("missingOld", homeExists: false, age: grace + 3600)
        // Another process may still use a store whose home just disappeared.
        try seed("missingRecent", homeExists: false, age: grace - 3600)
        try seed("missingRecentWal", homeExists: false, age: grace + 3600, walAge: 60)
        for index in 0..<12 {
            try seed("existing-\(index)", homeExists: true, age: 365 * 24 * 3600)
        }

        try Self.withProductionDefaults(env: env) {
            let options = CostUsageScanner.Options(
                codexSessionsRoot: env.root.appendingPathComponent("new-home/sessions"),
                cacheRoot: env.cacheRoot)
            let root = try #require(CodexHomeCostStoreScope.cacheRoot(options: options))
            let remaining = try Set(FileManager.default.contentsOfDirectory(atPath: homes.path))
            #expect(remaining.contains(root.lastPathComponent))
            #expect(!remaining.contains("missingOld"))
            #expect(remaining.contains("missingRecent"))
            #expect(remaining.contains("missingRecentWal"))
            for index in 0..<12 {
                #expect(remaining.contains("existing-\(index)"))
            }
        }
    }
}

extension CostUsageCodexHomeStoreTests {
    /// Treats the test cache root and `env.codexHomeRoot` as the production default cache and `~/.codex`.
    private static func withProductionDefaults<T>(
        env: CostUsageTestEnvironment,
        operation: () async throws -> T) async rethrows -> T
    {
        var hooks = CostUsageStoreTestHooks.current
        hooks.codexHomeStoreDefaults = .init(cacheRoot: env.cacheRoot, codexSessionsRoot: env.codexSessionsRoot)
        return try await CostUsageStoreTestHooks.$current.withValue(hooks, operation: operation)
    }

    private static func withProductionDefaults<T>(
        env: CostUsageTestEnvironment,
        operation: () throws -> T) rethrows -> T
    {
        var hooks = CostUsageStoreTestHooks.current
        hooks.codexHomeStoreDefaults = .init(cacheRoot: env.cacheRoot, codexSessionsRoot: env.codexSessionsRoot)
        return try CostUsageStoreTestHooks.$current.withValue(hooks, operation: operation)
    }

    private static func options(_ options: CostUsageScanner.Options, home: URL) -> CostUsageScanner.Options {
        var options = options
        options.codexSessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
        return options
    }

    private static func unboundedOptions(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    /// Home A establishes coverage in the shared file, as it did before per-home stores.
    private static func establishSharedHomeA(env: CostUsageTestEnvironment) async throws
        -> (home: URL, day: Date, snapshot: CostUsageTokenSnapshot, options: CostUsageScanner.Options)
    {
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let homeA = env.root.appendingPathComponent("home-a", isDirectory: true)
        try Self.writeSession(home: homeA, env: env, day: day, name: "a.jsonl", tokens: 64)
        let options = Self.unboundedOptions(env: env)
        let before = try await Self.establish(home: homeA, now: day, options: options)
        #expect(before.historyCoverageIsEstablished)
        CostUsageStoreAccess.releaseSharedStoresForTesting(cacheRoot: env.cacheRoot)
        return (homeA, day, before, Self.options(options, home: homeA))
    }

    private static func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    /// The first full scan records the lookback; the next one confirms coverage.
    private static func establish(
        home: URL,
        now: Date,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        var snapshot = try await Self.snapshot(home: home, now: now, options: options)
        for _ in 0..<2 where !snapshot.historyCoverageIsEstablished {
            snapshot = try await Self.snapshot(home: home, now: now, options: options)
        }
        return snapshot
    }

    private static func snapshot(
        home: URL,
        now: Date,
        options: CostUsageScanner.Options) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            codexHomePath: home.path,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            bypassScannerDebounce: true,
            scannerOptions: options)
    }

    private static func writeSession(
        home: URL,
        env: CostUsageTestEnvironment,
        day: Date,
        name: String,
        tokens: Int) throws
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let directory = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = "openai/gpt-5.4"
        try env.jsonl([
            ["type": "turn_context", "timestamp": env.isoString(for: day), "payload": ["model": model]],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": model,
                        "last_token_usage": ["input_tokens": tokens, "cached_input_tokens": 0, "output_tokens": 0],
                    ],
                ],
            ],
        ]).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
