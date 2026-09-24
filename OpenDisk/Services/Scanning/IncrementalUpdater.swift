import Darwin
import Foundation
import Synchronization

/// Splices FSEvents-reported changes into a cached scan tree: changed
/// directories are re-listed shallowly (files replaced, surviving
/// subdirectories re-linked, vanished ones unlinked, new ones scanned as
/// fresh subtrees), and coalesced "must scan subdirs" paths are rescanned
/// whole.
///
/// The tree is expected with directory sizes not rolled up; the caller
/// rolls up once after splicing.
enum IncrementalUpdater {

    /// Applies `changes` to `tree`. Returns false when the update cannot
    /// be applied cleanly (callers fall back to a full scan) — including
    /// when a re-read directory holds a hard link the cached tree never
    /// knew, whose bytes cannot be placed without a full recount.
    /// (Hard-link consistency ported from upstream f08d30e.)
    static func apply(
        _ changes: FSEventsChangeJournal.Changes,
        to tree: borrowing Mutex<FileTree>,
        rootPath: String,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let reader = BulkDirectoryReader()
        let knownHardLinks = tree.withLock { $0.hardLinkKeys }

        for directoryPath in changes.changedDirectories {
            if isCancelled() { return false }
            let consistent = updateDirectory(
                at: directoryPath, rootPath: rootPath,
                tree: tree, reader: reader, allowedDevices: allowedDevices,
                knownHardLinks: knownHardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        for subtreePath in changes.subtreesToRescan {
            if isCancelled() { return false }
            let consistent = rescanSubtree(
                at: subtreePath, rootPath: rootPath,
                tree: tree, allowedDevices: allowedDevices,
                knownHardLinks: knownHardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        guard !isCancelled() else { return false }
        // Splicing adds re-read files at full size and can delete the node
        // that carried a link's bytes: re-derive per-node shares now, once,
        // before the caller rolls up.
        tree.withLock { $0.normalizeHardLinks() }
        return true
    }

    // MARK: - Splicing

    /// Resolves a changed path to its directory node, or nil when the
    /// path must not or cannot be spliced.
    ///
    /// Never touches a mount root other than the scan root: FSEvents on
    /// "/" also reports paths under /Volumes aliases and snapshot mounts,
    /// which can share the boot volume's device ID — reading into one
    /// would drag another whole volume into this tree.
    ///
    /// A directory created after the cached scan has no node yet — its
    /// nearest cached ancestor also got an event and adopts it there
    /// (changed paths are processed parents-first).
    private static func resolveTarget(
        at path: String, rootPath: String, in tree: borrowing Mutex<FileTree>
    ) -> FileTree.NodeID? {
        guard path == rootPath || !VolumeAttributes.isVolumeRoot(path) else { return nil }
        return tree.withLock { current in
            guard let id = current.nodeID(forPath: path, rootPath: rootPath),
                  current.isDirectory(id) else { return nil }
            return id
        }
    }

    /// Shallow reconciliation of one changed directory: files are
    /// replaced from a fresh listing; subdirectories that survived keep
    /// their whole subtrees; new subdirectories are scanned fresh.
    ///
    /// Returns false when the fresh listing holds a hard link the cached
    /// tree never recorded: its bytes may already be counted on a node this
    /// splice is about to replace, or on none at all, and only a full scan
    /// can place them. (Ported from upstream f08d30e.)
    private static func updateDirectory(
        at path: String,
        rootPath: String,
        tree: borrowing Mutex<FileTree>,
        reader: BulkDirectoryReader,
        allowedDevices: Set<dev_t>,
        knownHardLinks: Set<FileTree.HardLinkKey>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }

        guard case .contents(let contents, let device) = reader.read(
            directoryAt: path, allowedDevices: allowedDevices
        ) else {
            // Vanished or unreadable now: drop its contents.
            tree.withLock { $0.removeAllChildren(of: node) }
            return true
        }

        for file in contents.files where file.linkCount > 1 && file.fileID > 0 {
            let key = FileTree.HardLinkKey(device: device, fileID: file.fileID)
            if !knownHardLinks.contains(key) { return false }
        }

        var newSubdirectories: [(name: String, id: FileTree.NodeID)] = []
        var updatedBytes: Int64 = 0

        tree.withLock { current in
            // Survivors keep their subtrees; everything else re-enters.
            var survivingDirectories: [String: FileTree.NodeID] = [:]
            for child in current.children(of: node) where current.isDirectory(child) {
                survivingDirectories[current.name(of: child)] = child
            }
            current.removeAllChildren(of: node)

            for file in contents.files {
                let id = current.addNode(
                    name: file.name, parent: node, size: file.size, isDirectory: false
                )
                if file.linkCount > 1, file.fileID > 0 {
                    current.recordHardLink(
                        id,
                        key: FileTree.HardLinkKey(device: device, fileID: file.fileID),
                        allocatedSize: file.size
                    )
                }
                updatedBytes += file.size
            }
            for name in contents.subdirectoryNames {
                if let existing = survivingDirectories[name] {
                    current.link(existing, under: node)
                } else {
                    let id = current.addNode(
                        name: name, parent: node, size: 0, isDirectory: true
                    )
                    newSubdirectories.append((name, id))
                }
            }
            for name in contents.mountPointNames {
                current.addNode(name: name, parent: node, size: 0, isDirectory: true)
            }
        }

        metrics.add(
            bytes: updatedBytes,
            items: contents.files.count + contents.subdirectoryNames.count
        )

        // Brand-new directories get full subtree scans, spliced in.
        let prefix = path.directoryPrefix
        for (name, id) in newSubdirectories {
            if isCancelled() { return true }
            let consistent = adoptScannedSubtree(
                ofPath: prefix + name, under: id, tree: tree,
                allowedDevices: allowedDevices, knownHardLinks: knownHardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }
        return true
    }

    /// Rescans a whole subtree (FSEvents coalesced its events) and
    /// replaces the node's contents with the fresh scan.
    private static func rescanSubtree(
        at path: String,
        rootPath: String,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        knownHardLinks: Set<FileTree.HardLinkKey>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }
        tree.withLock { $0.removeAllChildren(of: node) }
        return adoptScannedSubtree(
            ofPath: path, under: node, tree: tree,
            allowedDevices: allowedDevices, knownHardLinks: knownHardLinks,
            metrics: metrics, isCancelled: isCancelled
        )
    }

    private static func adoptScannedSubtree(
        ofPath path: String,
        under node: FileTree.NodeID,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        knownHardLinks: Set<FileTree.HardLinkKey>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let scanned = TraversalScanner.scan(
            path: path, rootName: path, allowedDevices: allowedDevices,
            metrics: metrics, isCancelled: isCancelled
        )
        // A fresh subtree scan dedups links against its own sightings only:
        // any inode it found that the cached tree never knew may already be
        // counted elsewhere in the surviving tree. Refuse the splice rather
        // than risk double-counting. (Ported from upstream f08d30e.)
        guard scanned.hardLinkKeys.isSubset(of: knownHardLinks) else { return false }
        tree.withLock { current in
            for child in scanned.children(of: FileTree.rootID) {
                current.adoptSubtree(from: scanned, otherNode: child, under: node)
            }
        }
        return true
    }
}
