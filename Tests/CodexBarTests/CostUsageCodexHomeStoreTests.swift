import Foundation
import Testing
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

            let establishedA = try await Self.snapshot(home: homeA, now: day, options: unbounded)
            #expect(establishedA.historyCoverageIsEstablished)
            #expect(establishedA.sessionTokens == 303)

            let pendingB = try await Self.snapshot(home: homeB, now: day.addingTimeInterval(1), options: bounded)
            #expect(!pendingB.historyCoverageIsEstablished)
            let fetcher = CostUsageFetcher(cacheRoot: env.cacheRoot)
            let statusB = await fetcher.codexScanCatchUpStatus(codexHomePath: homeB.path, historyDays: 1, now: day)
            #expect(statusB.pending)

            // A bounded read cannot rebuild A, so it must come from A's own retained scan state.
            let againA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(2), options: bounded)
            #expect(againA.historyCoverageIsEstablished)
            #expect(againA.sessionTokens == establishedA.sessionTokens)
            #expect(againA.last30DaysTokens == establishedA.last30DaysTokens)

            let statusBAfterA = await fetcher.codexScanCatchUpStatus(
                codexHomePath: homeB.path,
                historyDays: 1,
                now: day)
            #expect(statusBAfterA.pending)
            #expect(statusBAfterA.progressKey == statusB.progressKey)

            let finishedB = try await Self.snapshot(home: homeB, now: day.addingTimeInterval(3), options: unbounded)
            #expect(finishedB.historyCoverageIsEstablished)
            #expect(finishedB.sessionTokens == 33)
            let finalA = try await Self.snapshot(home: homeA, now: day.addingTimeInterval(4), options: bounded)
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
    func `new home stores prune missing homes and stay bounded`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let homes = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot).deletingLastPathComponent()
            .appendingPathComponent(CodexHomeCostStoreScope.directoryName, isDirectory: true)
        func seed(_ name: String, home: URL, age: TimeInterval) throws {
            let database = CostUsageStore.databaseURL(cacheRoot: homes.appendingPathComponent(name))
            try FileManager.default.createDirectory(
                at: database.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data().write(to: database)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)],
                ofItemAtPath: database.path)
            try Data(home.appendingPathComponent("sessions").path.utf8).write(
                to: homes.appendingPathComponent(name).appendingPathComponent(CodexHomeCostStoreScope.markerFilename))
        }
        try seed("missing", home: env.root.appendingPathComponent("gone"), age: 1)
        for index in 0..<CodexHomeCostStoreScope.maximumHomeStores {
            let home = env.root.appendingPathComponent("home-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try seed("existing-\(index)", home: home, age: TimeInterval(100 - index))
        }

        try Self.withProductionDefaults(env: env) {
            let options = CostUsageScanner.Options(
                codexSessionsRoot: env.root.appendingPathComponent("new-home/sessions"),
                cacheRoot: env.cacheRoot)
            let root = try #require(CodexHomeCostStoreScope.cacheRoot(options: options))
            let remaining = try Set(FileManager.default.contentsOfDirectory(atPath: homes.path))
            #expect(remaining.count == CodexHomeCostStoreScope.maximumHomeStores)
            #expect(remaining.contains(root.lastPathComponent))
            #expect(!remaining.contains("missing"))
            #expect(!remaining.contains("existing-0"))
            #expect(remaining.contains("existing-1"))
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
