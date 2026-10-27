import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexArchivedRolloutMirrorLinuxTests {
    @Test
    func `a changed archive replaces an existing private mirror`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-archive-linux-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let archive = source.appendingPathComponent(
            "rollout-2026-10-01T12-00-00-0199f0a0-0000-7000-8000-000000000099.jsonl.zst")
        let first = Data("original transcript\n".utf8)
        let second = Data("updated transcript with more content\n".utf8)
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        try Self.rawFrame(first).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
        let initial = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [source], cacheRoot: cache).roots.first?.archives.first)
        #expect(try CodexArchivedRolloutMirror.decode(initial, maxNewBytes: .max).isComplete)
        #expect(try Data(contentsOf: initial.mirrorURL) == first)

        try Self.rawFrame(second).write(to: archive)
        try FileManager.default.setAttributes(
            [.modificationDate: modified.addingTimeInterval(60)], ofItemAtPath: archive.path)
        let changed = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [source], cacheRoot: cache).roots.first?.archives.first)
        #expect(!changed.mirrorIsCurrent)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: changed.mirrorURL.path)
        #expect(try CodexArchivedRolloutMirror.decode(changed, maxNewBytes: .max).isComplete)
        #expect(try Data(contentsOf: changed.mirrorURL) == second)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: changed.mirrorURL.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        let publishedDate = try #require(
            FileManager.default.attributesOfItem(atPath: changed.mirrorURL.path)[.modificationDate] as? Date)
        #expect(abs(publishedDate.timeIntervalSince(modified.addingTimeInterval(60))) < 0.01)
        #expect(try Data(contentsOf: archive) == Self.rawFrame(second))
    }

    @Test
    func `a failed publication preserves the destination and source archive`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-archive-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let archive = source.appendingPathComponent(
            "rollout-2026-10-01T12-00-00-0199f0a0-0000-7000-8000-000000000098.jsonl.zst")
        let compressed = Self.rawFrame(Data("transcript\n".utf8))
        try compressed.write(to: archive)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: archive.path)
        let entry = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [source], cacheRoot: cache).roots.first?.archives.first)
        // A nonempty directory at the destination prevents a file rename.
        try FileManager.default.createDirectory(at: entry.mirrorURL, withIntermediateDirectories: true)
        let marker = entry.mirrorURL.appendingPathComponent("keep")
        try Data("existing destination\n".utf8).write(to: marker)

        #expect(throws: (any Error).self) {
            try CodexArchivedRolloutMirror.decode(entry, maxNewBytes: .max)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "existing destination\n")
        #expect(try Data(contentsOf: archive) == compressed)
    }

    /// Stored zstd block, following the PR's existing macOS archive tests.
    private static func rawFrame(_ payload: Data) -> Data {
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0xE0])
        withUnsafeBytes(of: UInt64(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        let header = UInt32(payload.count) << 3 | 1
        frame.append(contentsOf: [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)])
        frame.append(payload)
        return frame
    }
}
