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
    ///
    /// `capturedAt` is when the cached scan began. It lets the update accept
    /// a hard link the cache never knew *provided the file was created after
    /// that moment* (see `HardLinkPolicy`). The default, `.distantFuture`,
    /// means "no file can be newer than the cache", which reduces the policy
    /// to the original strict rule — so a caller that cannot vouch for a
    /// capture time gets the conservative behaviour without asking for it.
    /// (Ported from upstream d987b27.)
    static func apply(
        _ changes: FSEventsChangeJournal.Changes,
        to tree: borrowing Mutex<FileTree>,
        rootPath: String,
        allowedDevices: Set<dev_t>,
        newInodesSince capturedAt: Date = .distantFuture,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let reader = BulkDirectoryReader()
        let hardLinks = HardLinkPolicy(
            known: tree.withLock { $0.hardLinkKeys }, capturedAt: capturedAt
        )

        for directoryPath in changes.changedDirectories {
            if isCancelled() { return false }
            let consistent = updateDirectory(
                at: directoryPath, rootPath: rootPath,
                tree: tree, reader: reader, allowedDevices: allowedDevices,
                hardLinks: hardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        for subtreePath in changes.subtreesToRescan {
            if isCancelled() { return false }
            let consistent = rescanSubtree(
                at: subtreePath, rootPath: rootPath,
                tree: tree, allowedDevices: allowedDevices,
                hardLinks: hardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        guard !isCancelled() else { return false }
        // Before normalizing: a re-measured hard link updates its record,
        // and normalization is what turns records back into node shares.
        refreshLargeFileSizes(in: tree)
        // Splicing adds re-read files at full size and can delete the node
        // that carried a link's bytes: re-derive per-node shares now, once,
        // before the caller rolls up.
        tree.withLock { $0.normalizeHardLinks() }
        return true
    }

    // MARK: - Size drift

    /// Files below this are not re-measured: the point is the handful of
    /// very large files whose drift is visible in a disk-usage chart, and
    /// one `lstat` each for those is nothing next to the scan it replaces.
    private static let driftCheckMinimumBytes: Int64 = 64 << 20

    /// Re-measures every large file in the tree, whether or not the journal
    /// reported its directory.
    ///
    /// FSEvents records that a directory's *entries* changed. A file that
    /// grows in place — a VM disk image, a database, a log — keeps its name
    /// and its directory entry, so it can swell by gigabytes without the
    /// journal ever naming its folder, and an incremental update that trusted
    /// the journal alone would go on showing the size from the cached scan.
    /// (Ported from upstream d987b27.)
    private static func refreshLargeFileSizes(in tree: borrowing Mutex<FileTree>) {
        let candidates: [(id: FileTree.NodeID, path: String)] = tree.withLock { current in
            current.reachableFiles(allocatedAtLeast: driftCheckMinimumBytes).compactMap { id in
                // `path(of:)` is nil for a node whose parent chain does not
                // reach the root. Skip it: a truncated path names a
                // *different* real file, and its size would then be written
                // onto this node. See SECURITY-REVIEW.md, finding L1.
                current.path(of: id).map { (id, $0) }
            }
        }
        var updates: [(id: FileTree.NodeID, size: Int64)] = []
        for candidate in candidates {
            var info = stat()
            // lstat, and regular files only: never follow a symlink that
            // replaced the file, and leave a path that is now a directory
            // (or gone) to the journal-driven splice that already handled it.
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            updates.append((candidate.id, Int64(info.st_blocks) * 512))
        }
        tree.withLock { current in
            for update in updates {
                current.updateAllocatedSize(of: update.id, to: update.size)
            }
        }
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
        hardLinks: HardLinkPolicy,
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

        let prefix = path.directoryPrefix
        for file in contents.files where file.linkCount > 1 && file.fileID > 0 {
            let key = FileTree.HardLinkKey(device: device, fileID: file.fileID)
            guard hardLinks.allows(key, at: prefix + file.name) else { return false }
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
        for (name, id) in newSubdirectories {
            if isCancelled() { return true }
            let consistent = adoptScannedSubtree(
                ofPath: prefix + name, under: id, tree: tree,
                allowedDevices: allowedDevices, hardLinks: hardLinks,
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
        hardLinks: HardLinkPolicy,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }
        tree.withLock { $0.removeAllChildren(of: node) }
        return adoptScannedSubtree(
            ofPath: path, under: node, tree: tree,
            allowedDevices: allowedDevices, hardLinks: hardLinks,
            metrics: metrics, isCancelled: isCancelled
        )
    }

    private static func adoptScannedSubtree(
        ofPath path: String,
        under node: FileTree.NodeID,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        hardLinks: HardLinkPolicy,
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
        //
        // Each link is judged where it sits, so the policy can stat it. A
        // link whose path cannot be resolved (L1) is refused: without the
        // file there is no way to show it postdates the cache.
        for (id, key) in scanned.hardLinkedNodes {
            guard let linkPath = scanned.path(of: id),
                  hardLinks.allows(key, at: linkPath) else { return false }
        }
        tree.withLock { current in
            for child in scanned.children(of: FileTree.rootID) {
                current.adoptSubtree(from: scanned, otherNode: child, under: node)
            }
        }
        return true
    }

    // MARK: - Hard-link policy

    /// Decides whether a hard link found during an incremental update can be
    /// spliced in without a full recount.
    ///
    /// The danger is an inode the cached tree already counted *as an ordinary
    /// file* (it had one link then) that has since gained a second link: its
    /// bytes are on a node the cache does not know is a link, and adding the
    /// new sighting would count them twice.
    ///
    /// - An inode the cache recorded as a link is safe: normalization dedups it.
    /// - An inode *born after the cached scan began* is safe too: it did not
    ///   exist then, so no cached node can be holding its bytes. Every link
    ///   to it necessarily arrives through this update, is recorded, and is
    ///   deduplicated by `normalizeHardLinks()`.
    ///
    /// Without the second rule, a single new hard-linked file anywhere under
    /// the root forces a full rescan of the whole root, and tools that
    /// create hard links as a matter of course (package managers, for one)
    /// make that the common case. (Ported from upstream d987b27.)
    ///
    /// Birth time is the inode's, not the link's: a new *name* for an old
    /// file keeps the old birth time and is still refused. A wrong answer in
    /// either direction can only mis-size the chart; these values never
    /// reach the deletion path.
    private struct HardLinkPolicy {
        let known: Set<FileTree.HardLinkKey>
        let capturedAt: Date

        func allows(_ key: FileTree.HardLinkKey, at path: String) -> Bool {
            known.contains(key) || isCreated(afterCapture: path)
        }

        private func isCreated(afterCapture path: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            let birth = Double(info.st_birthtimespec.tv_sec)
                + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
            return birth > capturedAt.timeIntervalSince1970
        }
    }
}
