import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexArchivedRolloutMirrorPagedMigrationTests {
    @Test
    func `paged refresh does not count a cached plain rollout and its archive mirror twice`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let name = "rollout-2026-08-30T12-00-00-0199f0a0-0000-7000-8000-000000000001.jsonl"
        let contents = CodexArchivedRolloutMirrorTests.rollout(stamp: env.isoString(for: day))
        let plain = try env.writeCodexSessionFile(day: day, filename: name, contents: contents)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.maxCodexScanBytesPerRefresh = 0

        func total() -> Int? {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options).summary?.totalTokens
        }

        #expect(total() == 330)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(cache.files.keys.map(Self.pathKey) == [Self.pathKey(plain.path)])

        // A bounded refresh leaves catch-up pending. Keep more inventory than the exact-completion
        // limit so saving this fixture cannot mark the cache complete and erase the paged state.
        cache.codexScanCatchUpPending = true
        cache.codexScanTotalFiles = 600
        cache.codexScanInventoryPaths = (0..<600).map { "/tmp/paged-migration-\($0).jsonl" }
        _ = CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending == true)

        // Codex archives the rollout and removes the plain file before the next refresh.
        try FileManager.default.removeItem(at: plain)
        try CodexArchivedRolloutMirrorTests.writeArchive(
            env: env,
            day: day,
            name: name,
            contents: Data(contents.utf8),
            modified: day)
        let mirror = try CodexArchivedRolloutMirror.sync(
            sourceRoots: [env.codexSessionsRoot, env.codexArchivedSessionsRoot],
            cacheRoot: env.cacheRoot,
            modifiedSince: nil)
        #expect(mirror.materialized == 1)

        // A time-limited pass pages discovery and skips missing-file cleanup.
        options.maxCodexScanDurationPerRefresh = 60
        #expect(total() == 330)

        cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(
            for: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let expectedMirror = mirrorRoot.appendingPathComponent("2026/08/30/\(name)").standardizedFileURL.path
        #expect(cache.files.keys.map(Self.pathKey) == [expectedMirror])
        #expect(cache.days["2026-08-30"]?["gpt-5.4"] == [300, 0, 30])
    }

    private static func pathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
