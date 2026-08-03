import Foundation
import Testing
@testable import OpenDisk

@Suite("FileTree serialization")
struct FileTreeSerializationTests {

    @Test("binary roundtrip preserves structure, sizes and names")
    func serializationRoundtrip() throws {
        var tree = FileTree(rootName: "/Volumes/T")
        let docs = tree.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "report — épreuve.pdf", parent: docs, size: 50_000, isDirectory: false)
        let nested = tree.addNode(name: "nested", parent: docs, size: 0, isDirectory: true)
        tree.addNode(name: "deep.bin", parent: nested, size: 123, isDirectory: false)
        tree.addNode(name: "movie.mov", parent: FileTree.rootID, size: 2_000_000, isDirectory: false)

        let decoded = try #require(FileTree(serializedData: tree.serializedData()))
        #expect(decoded.nodeCount == tree.nodeCount)

        var expected = tree
        var roundtripped = decoded
        expected.rollUpDirectorySizes()
        roundtripped.rollUpDirectorySizes()
        #expect(roundtripped.size(of: FileTree.rootID) == expected.size(of: FileTree.rootID))

        let decodedDocs = try #require(roundtripped.child(of: FileTree.rootID, named: "Documents"))
        #expect(roundtripped.isDirectory(decodedDocs))
        #expect(roundtripped.child(of: decodedDocs, named: "report — épreuve.pdf") != nil)
        #expect(roundtripped.nodeID(atComponents: "Documents/nested/deep.bin".split(separator: "/")) != nil)
        #expect(roundtripped.path(of: decodedDocs) == "/Volumes/T/Documents")
    }

    @Test("malformed blobs are rejected, not crashed on")
    func malformedDataRejected() {
        #expect(FileTree(serializedData: Data()) == nil)
        #expect(FileTree(serializedData: Data([1, 2, 3, 4, 5])) == nil)

        var tree = FileTree(rootName: "/")
        tree.addNode(name: "a", parent: FileTree.rootID, size: 1, isDirectory: false)
        var blob = tree.serializedData()
        blob.removeLast(8)  // Truncated name blob.
        #expect(FileTree(serializedData: blob) == nil)
    }
}

@Suite("FileTree")
struct FileTreeTests {

    /// Builds:  /  ├─ Users/ ├─ a.txt(100)
    ///              │   ├─ alice/ ─ big.bin(4096)
    ///              │   └─ b.txt(50)
    private func makeSampleTree() -> FileTree {
        var tree = FileTree(rootName: "/")
        let users = tree.addNode(name: "Users", parent: FileTree.rootID, size: 0, isDirectory: true)
        let alice = tree.addNode(name: "alice", parent: users, size: 0, isDirectory: true)
        tree.addNode(name: "big.bin", parent: alice, size: 4_096, isDirectory: false)
        tree.addNode(name: "b.txt", parent: users, size: 50, isDirectory: false)
        tree.addNode(name: "a.txt", parent: FileTree.rootID, size: 100, isDirectory: false)
        return tree
    }

    @Test("rolls file sizes up into every ancestor directory")
    func rollUpAggregatesSizes() {
        var tree = makeSampleTree()
        tree.rollUpDirectorySizes()

        #expect(tree.size(of: FileTree.rootID) == 4_246)
        let users = tree.child(of: FileTree.rootID, named: "Users")!
        #expect(tree.size(of: users) == 4_146)
        let alice = tree.child(of: users, named: "alice")!
        #expect(tree.size(of: alice) == 4_096)
    }

    @Test("resolves nodes by path components and rebuilds paths")
    func pathResolutionRoundTrips() throws {
        let tree = makeSampleTree()
        let path = "Users/alice/big.bin"
        let node = tree.nodeID(atComponents: path.split(separator: "/"))
        let big = try #require(node)
        #expect(tree.name(of: big) == "big.bin")
        #expect(tree.path(of: big) == "/Users/alice/big.bin")
        #expect(tree.nodeID(atComponents: "Users/nobody".split(separator: "/")) == nil)
    }

    @Test("childCount tracks direct children only")
    func childCounts() {
        let tree = makeSampleTree()
        #expect(tree.childCount(of: FileTree.rootID) == 2)
        let users = tree.child(of: FileTree.rootID, named: "Users")!
        #expect(tree.childCount(of: users) == 2)
    }

    @Test("removeChild detaches a subtree from totals")
    func removeChildExcludesSubtree() {
        var tree = makeSampleTree()
        tree.removeChild(named: "Users", of: FileTree.rootID)
        tree.rollUpDirectorySizes()

        #expect(tree.size(of: FileTree.rootID) == 100)
        #expect(tree.child(of: FileTree.rootID, named: "Users") == nil)
        #expect(tree.childCount(of: FileTree.rootID) == 1)
    }

    @Test("merge combines same-named directories recursively")
    func mergeCombinesFirmlinkStyleTrees() {
        // System-style tree: /usr/bin/ls
        var system = FileTree(rootName: "/")
        let sysUsr = system.addNode(name: "usr", parent: FileTree.rootID, size: 0, isDirectory: true)
        let sysBin = system.addNode(name: "bin", parent: sysUsr, size: 0, isDirectory: true)
        system.addNode(name: "ls", parent: sysBin, size: 200, isDirectory: false)

        // Data-style tree: /usr/local/tool + /Users/alice/file
        var data = FileTree(rootName: "/")
        let dataUsr = data.addNode(name: "usr", parent: FileTree.rootID, size: 0, isDirectory: true)
        let local = data.addNode(name: "local", parent: dataUsr, size: 0, isDirectory: true)
        data.addNode(name: "tool", parent: local, size: 300, isDirectory: false)
        let users = data.addNode(name: "Users", parent: FileTree.rootID, size: 0, isDirectory: true)
        data.addNode(name: "file", parent: users, size: 700, isDirectory: false)

        system.merge(data)
        system.rollUpDirectorySizes()

        #expect(system.size(of: FileTree.rootID) == 1_200)
        // "usr" merged, not duplicated.
        #expect(system.children(of: FileTree.rootID).count == 2)
        let mergedUsr = system.child(of: FileTree.rootID, named: "usr")!
        #expect(system.size(of: mergedUsr) == 500)
        #expect(system.child(of: mergedUsr, named: "bin") != nil)
        #expect(system.child(of: mergedUsr, named: "local") != nil)
    }

    @Test("merge into a nested target grafts a volume in place")
    func mergeIntoNestedNode() {
        var base = FileTree(rootName: "/")
        let sys = base.addNode(name: "System", parent: FileTree.rootID, size: 0, isDirectory: true)
        let volumes = base.addNode(name: "Volumes", parent: sys, size: 0, isDirectory: true)
        let vm = base.addNode(name: "VM", parent: volumes, size: 0, isDirectory: true)

        var vmTree = FileTree(rootName: "/System/Volumes/VM")
        vmTree.addNode(name: "swapfile0", parent: FileTree.rootID, size: 1_024, isDirectory: false)

        base.merge(vmTree, into: vm)
        base.rollUpDirectorySizes()

        #expect(base.size(of: vm) == 1_024)
        #expect(base.size(of: FileTree.rootID) == 1_024)
    }

    @Test("unlinked and mutually-cyclic nodes neither hang nor count")
    func malformedLinksDoNotLoop() {
        var tree = FileTree(rootName: "/")
        let a = tree.appendUnlinked(name: "a", size: 0, isDirectory: true)
        let b = tree.appendUnlinked(name: "b", size: 0, isDirectory: true)
        let file = tree.appendUnlinked(name: "f", size: 10, isDirectory: false)
        tree.link(file, under: FileTree.rootID)
        // A mutual parent cycle detached from the root, as corrupt catalog
        // data could produce: roll-up must terminate and ignore it.
        tree.link(a, under: b)
        tree.link(b, under: a)
        tree.rollUpDirectorySizes()
        #expect(tree.size(of: FileTree.rootID) == 10)
    }
}

@Suite("FileTree hardening")
struct FileTreeHardeningTests {

    /// A serialized tree whose sibling chain forms a cycle. The deserializer
    /// validates index *ranges*, not acyclicity, so a corrupted or truncated
    /// cache file can produce one — and every walk over it must terminate.
    /// See SECURITY-REVIEW.md, finding M1.
    private func treeWithSiblingCycle() throws -> FileTree {
        var tree = FileTree(rootName: "/")
        let a = tree.addNode(name: "a", parent: FileTree.rootID, size: 1, isDirectory: false)
        let b = tree.addNode(name: "b", parent: FileTree.rootID, size: 2, isDirectory: false)

        // Rewrite the serialized nextSibling array so a -> b -> a.
        var data = tree.serializedData()
        let count = tree.nodeCount
        // Layout: magic(4) + count(4) + sizes(8n) + parents(4n) + firstChildren(4n)
        //         + nextSiblings(4n) + ...
        let nextSiblingsOffset = 8 + 8 * count + 4 * count + 4 * count
        func write(_ value: Int32, atNodeIndex index: Int) {
            withUnsafeBytes(of: value) { raw in
                let start = nextSiblingsOffset + 4 * index
                data.replaceSubrange(start..<(start + 4), with: raw)
            }
        }
        write(b, atNodeIndex: Int(a))
        write(a, atNodeIndex: Int(b))
        return try #require(FileTree(serializedData: data))
    }

    @Test("a sibling-chain cycle does not hang the size roll-up", .timeLimit(.minutes(1)))
    func siblingCycleTerminates() throws {
        var tree = try treeWithSiblingCycle()
        tree.rollUpDirectorySizes()   // hung forever before the bound was added
        #expect(tree.nodeCount == 3)
    }

    @Test("a sibling-chain cycle does not hang subtree adoption", .timeLimit(.minutes(1)))
    func siblingCycleAdoptionTerminates() throws {
        let corrupt = try treeWithSiblingCycle()
        var destination = FileTree(rootName: "/dest")
        // Adopt the node whose *child chain* is cyclic — the root here.
        // Adopting one of its children would walk that child's (empty) chain
        // and never reach the cycle at all.
        destination.adoptSubtree(
            from: corrupt, otherNode: FileTree.rootID, under: FileTree.rootID
        )
        #expect(destination.nodeCount > 1)
    }

    /// An unlinked node has no route to the root, so it has no path. Returning
    /// a partial one would name a *different, existing* directory, and these
    /// paths flow into the Collector. See SECURITY-REVIEW.md, finding L1.
    @Test("path(of:) returns nil rather than a plausible wrong path")
    func pathOfDetachedNodeIsNil() {
        var tree = FileTree(rootName: "/Volumes/T")
        let linked = tree.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        let detached = tree.appendUnlinked(name: "orphan", size: 5, isDirectory: false)

        #expect(tree.path(of: linked) == "/Volumes/T/Documents")
        #expect(tree.path(of: detached) == nil)
    }

    /// Incremental updates orphan whole subtrees; serialization writes every
    /// node, so without compaction the cache grows on every rescan.
    /// See SECURITY-REVIEW.md, finding M2.
    @Test("compaction drops orphaned nodes but preserves the live tree")
    func compactionDropsGarbage() throws {
        var tree = FileTree(rootName: "/Volumes/T")
        let docs = tree.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "keep.bin", parent: docs, size: 100, isDirectory: false)
        let stale = tree.addNode(name: "Stale", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "gone-a.bin", parent: stale, size: 7, isDirectory: false)
        tree.addNode(name: "gone-b.bin", parent: stale, size: 9, isDirectory: false)

        // What an FSEvents splice does: unlink the subtree, leave it in place.
        tree.removeChild(named: "Stale", of: FileTree.rootID)
        #expect(tree.nodeCount == 6)   // orphans still occupy the arrays

        let compacted = tree.compacted()
        #expect(compacted.nodeCount == 3)   // root + Documents + keep.bin

        var expected = tree, actual = compacted
        expected.rollUpDirectorySizes()
        actual.rollUpDirectorySizes()
        #expect(actual.size(of: FileTree.rootID) == expected.size(of: FileTree.rootID))

        let compactedDocs = try #require(actual.child(of: FileTree.rootID, named: "Documents"))
        #expect(actual.path(of: compactedDocs) == "/Volumes/T/Documents")
        #expect(actual.child(of: FileTree.rootID, named: "Stale") == nil)
    }

    @Test("compaction preserves sibling display order")
    func compactionPreservesOrder() {
        var tree = FileTree(rootName: "/")
        for name in ["a", "b", "c", "d"] {
            tree.addNode(name: name, parent: FileTree.rootID, size: 1, isDirectory: false)
        }
        let before = tree.children(of: FileTree.rootID).map { tree.name(of: $0) }
        let compacted = tree.compacted()
        let after = compacted.children(of: FileTree.rootID).map { compacted.name(of: $0) }
        #expect(before == after)
    }

    @Test("a compacted tree survives a serialization roundtrip")
    func compactedRoundtrips() throws {
        var tree = FileTree(rootName: "/Volumes/T")
        let dir = tree.addNode(name: "d", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "f.bin", parent: dir, size: 42, isDirectory: false)
        tree.removeChild(named: "d", of: FileTree.rootID)
        tree.addNode(name: "live.bin", parent: FileTree.rootID, size: 8, isDirectory: false)

        let compacted = tree.compacted()
        var decoded = try #require(FileTree(serializedData: compacted.serializedData()))
        decoded.rollUpDirectorySizes()
        #expect(decoded.nodeCount == 2)
        #expect(decoded.size(of: FileTree.rootID) == 8)
    }
}
