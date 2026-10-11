import Foundation
import Synchronization
import Testing
@testable import OpenDisk

/// Integration tests for the changes that let an incremental update stand in
/// for a full scan more often: re-measuring large files the journal never
/// mentioned, and accepting hard-linked files born after the cached scan.
/// Run against a real temporary tree, like `HardLinkIncrementalTests` (link
/// identity, birth times and block counts all come from the filesystem).
///
/// Ported from upstream d987b27, where these were added to
/// `HardLinkIncrementalTests`. They live in their own file here so that
/// suite's helpers did not have to change: this fork never edits an existing
/// test to accommodate a change. The last test is fork-specific.
@Suite("Incremental updates reuse the cache", .serialized)
struct IncrementalCacheReuseTests {
    private let fileManager = FileManager.default

    private func withTemporaryTree(_ body: (URL) throws -> Void) throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("IncrementalCacheReuseTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try body(root)
    }

    private func makeDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func scan(_ root: URL) -> FileTree {
        TraversalScanner.scan(
            path: root.path, rootName: root.path,
            metrics: ScanMetrics(), isCancelled: { false }
        )
    }

    private func total(_ tree: FileTree) -> Int64 {
        var rolled = tree
        rolled.rollUpDirectorySizes()
        return rolled.size(of: FileTree.rootID)
    }

    /// `capturedAt: nil` calls `apply` *without* the argument, so the
    /// parameter's own default is what gets exercised.
    private func applyChanges(
        changedDirectories: [URL] = [],
        to tree: FileTree,
        root: URL,
        capturedAt: Date? = nil
    ) throws -> (applied: Bool, tree: FileTree) {
        let device = try #require(VolumeAttributes.deviceID(ofPath: root.path))
        let live = Mutex(tree)
        let changes = FSEventsChangeJournal.Changes(
            changedDirectories: changedDirectories.map(\.path), subtreesToRescan: []
        )
        let applied: Bool
        if let capturedAt {
            applied = IncrementalUpdater.apply(
                changes, to: live, rootPath: root.path, allowedDevices: [device],
                newInodesSince: capturedAt,
                metrics: ScanMetrics(), isCancelled: { false }
            )
        } else {
            applied = IncrementalUpdater.apply(
                changes, to: live, rootPath: root.path, allowedDevices: [device],
                metrics: ScanMetrics(), isCancelled: { false }
            )
        }
        return (applied, live.withLock { $0 })
    }

    @Test("a large file that grows in place without a change event is re-measured")
    func largeFileGrowthWithoutEventIsCaught() throws {
        try withTemporaryTree { root in
            let disk = root.appendingPathComponent("vm.raw")
            try writeFile(disk, bytes: 70 << 20)
            let initial = scan(root)

            let handle = try FileHandle(forWritingTo: disk)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x5A, count: 30 << 20))
            try handle.close()

            // No changed directories at all: the journal said nothing.
            let (applied, updated) = try applyChanges(to: initial, root: root)
            #expect(applied)
            let rescanned = scan(root)
            #expect(total(updated) == total(rescanned))
            #expect(total(updated) >= 100 << 20)
        }
    }

    @Test("an old single-link file that gains a link still falls back even with a capture time")
    func oldFileGainingLinkStillBails() throws {
        try withTemporaryTree { root in
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try makeDirectory(sub)
            let original = root.appendingPathComponent("original.bin")
            try writeFile(original, bytes: 40_000)
            // Put clear water between the file's birth and the capture time.
            Thread.sleep(forTimeInterval: 0.02)
            let capturedAt = Date()

            let initial = scan(root)
            try fileManager.linkItem(at: original, to: sub.appendingPathComponent("late-link.bin"))

            let (applied, _) = try applyChanges(
                changedDirectories: [sub], to: initial, root: root, capturedAt: capturedAt
            )
            #expect(!applied)
        }
    }

    @Test("hard-linked files created after the capture are applied and counted once")
    func newHardLinkedFilesAreApplied() throws {
        try withTemporaryTree { root in
            let first = root.appendingPathComponent("first", isDirectory: true)
            let second = root.appendingPathComponent("second", isDirectory: true)
            try makeDirectory(first)
            try makeDirectory(second)
            let capturedAt = Date()
            let initial = scan(root)
            Thread.sleep(forTimeInterval: 0.02)

            let journal = first.appendingPathComponent("journal.bin")
            try writeFile(journal, bytes: 60_000)
            try fileManager.linkItem(at: journal, to: first.appendingPathComponent("journal-link.bin"))
            try fileManager.linkItem(at: journal, to: second.appendingPathComponent("journal-copy.bin"))

            let (applied, updated) = try applyChanges(
                changedDirectories: [first, second], to: initial, root: root, capturedAt: capturedAt
            )
            #expect(applied)
            let rescanned = scan(root)
            #expect(total(updated) == total(rescanned))
            #expect(total(updated) < 120_000)
        }
    }

    /// Fork-specific. The relaxation above must be something a caller opts
    /// into by supplying a capture time it can vouch for; a caller that
    /// supplies none has to get the original strict rule.
    @Test("with no capture time, a new hard-linked file still forces a full scan")
    func defaultCaptureTimeKeepsTheStrictRule() throws {
        try withTemporaryTree { root in
            let first = root.appendingPathComponent("first", isDirectory: true)
            try makeDirectory(first)
            let initial = scan(root)
            Thread.sleep(forTimeInterval: 0.02)

            let journal = first.appendingPathComponent("journal.bin")
            try writeFile(journal, bytes: 60_000)
            try fileManager.linkItem(at: journal, to: first.appendingPathComponent("journal-link.bin"))

            let (applied, _) = try applyChanges(changedDirectories: [first], to: initial, root: root)
            #expect(!applied)
        }
    }
}
