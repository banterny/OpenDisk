import Darwin
import Foundation

/// On-disk cache of finished scan trees, keyed by scan root, together
/// with the FSEvents event ID captured when the scan started. A later
/// scan of the same root can replay the volume's FSEvents journal from
/// that ID and re-read only the directories that changed since.
enum ScanCache {

    /// What is known about the scan a cached tree came from.
    /// (Ported from upstream d987b27.)
    struct Header: Sendable {
        /// FSEvents ID from just before the cached scan began.
        let eventID: UInt64
        /// Wall-clock time the cached scan began. A file born after this
        /// cannot have been counted in the cached tree, which is what lets
        /// an incremental update accept new hard-linked files (see
        /// `IncrementalUpdater.HardLinkPolicy`).
        let capturedAt: Date
        /// How long the last *full* traversal of this root took, carried
        /// forward unchanged across incremental updates. Sizes the journal
        /// replay's time budget from a measurement instead of a guess; 0
        /// when unknown.
        let fullScanSeconds: TimeInterval
    }

    struct Entry {
        /// The cached tree, with directory sizes NOT rolled up (ready for
        /// splicing and a fresh roll-up).
        let tree: FileTree
        let header: Header
    }

    // v2: trees now carry hard-link records in a new serialization layout
    // ("DMT3"). (Ported from upstream f08d30e.)
    // v3: the header gains the capture time and the measured full-scan
    // duration. (Ported from upstream d987b27.)
    // Older files are rejected by the version check at load and the root is
    // simply rescanned — a stale cache must never be misparsed.
    private static let formatVersion: UInt32 = 3

    // MARK: - Public API

    static func load(forRoot rootPath: String) -> Entry? {
        // Mapping keeps the decode reading straight from the page cache
        // instead of copying the whole file up front.
        guard let url = cacheFileURL(forRoot: rootPath),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let parsed = parseHeader(data, forRoot: rootPath),
              // The tree decodes from a no-copy slice of the mapped file.
              let tree = FileTree(serializedData: data[parsed.treeStart...]) else {
            return nil
        }
        return Entry(tree: tree, header: parsed.header)
    }

    /// The cached scan's header and the cache file's size, validated for
    /// this exact root — without decoding the tree (the expensive part of
    /// `load`). Lets a journal replay start while the tree deserializes in
    /// parallel; the byte count is a fallback proxy for how big the cached
    /// scan was, for a header with no measured scan duration.
    /// (Ported from upstream 999fae2.)
    static func peek(forRoot rootPath: String) -> (header: Header, fileBytes: Int)? {
        guard let url = cacheFileURL(forRoot: rootPath),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let parsed = parseHeader(data, forRoot: rootPath) else { return nil }
        return (parsed.header, data.count)
    }

    /// Parses and validates the fixed header: the cache must describe this
    /// exact root on this exact volume — a re-formatted or different disk
    /// mounted at the same place must not resurrect a stale tree.
    /// (Extracted from `load`, upstream 999fae2.)
    private static func parseHeader(
        _ data: Data, forRoot rootPath: String
    ) -> (header: Header, treeStart: Data.Index)? {
        var offset = data.startIndex
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.endIndex else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset - data.startIndex, as: T.self)
            }
        }

        guard read(UInt32.self) == formatVersion,
              let eventID = read(UInt64.self),
              let capturedAt = read(Double.self),
              let fullScanSeconds = read(Double.self),
              let savedDevice = read(UInt64.self),
              let pathLength = read(UInt32.self),
              offset + Int(pathLength) <= data.endIndex else { return nil }

        let savedPath = String(decoding: data[offset..<(offset + Int(pathLength))], as: UTF8.self)
        offset += Int(pathLength)

        guard savedPath == rootPath,
              let device = VolumeAttributes.deviceID(ofPath: rootPath),
              UInt64(bitPattern: Int64(device)) == savedDevice else {
            return nil
        }
        // Both doubles come off disk and feed arithmetic (a timeout, a
        // date comparison). A NaN or infinity from a damaged file must not
        // get that far — treat the cache as unusable instead.
        guard capturedAt.isFinite, fullScanSeconds.isFinite, fullScanSeconds >= 0 else {
            return nil
        }
        let header = Header(
            eventID: eventID,
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            fullScanSeconds: fullScanSeconds
        )
        return (header, offset)
    }

    /// Blocking (~hundreds of ms for multi-million-node trees): call from
    /// a background queue.
    static func save(tree: FileTree, forRoot rootPath: String, header cacheHeader: Header) {
        guard let url = cacheFileURL(forRoot: rootPath),
              let device = VolumeAttributes.deviceID(ofPath: rootPath) else { return }

        var header = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { header.append(contentsOf: $0) }
        }
        append(formatVersion)
        append(cacheHeader.eventID)
        append(cacheHeader.capturedAt.timeIntervalSince1970)
        append(cacheHeader.fullScanSeconds)
        append(UInt64(bitPattern: Int64(device)))
        let pathBytes = Data(rootPath.utf8)
        append(UInt32(pathBytes.count))
        header.append(pathBytes)

        // Header and tree blob are written sequentially (to a temp file
        // swapped in whole) so the big blob is never copied into a second
        // combined Data just to prepend a few bytes.
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { return }
        guard let handle = try? FileHandle(forWritingTo: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        do {
            try handle.write(contentsOf: header)
            // Compact first: an FSEvents-spliced tree carries the unlinked
            // remains of everything it replaced, and persisting those makes
            // the cache grow with every rescan. See SECURITY-REVIEW.md, M2.
            try handle.write(contentsOf: tree.compacted().serializedData())
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            prune(directory: directory, keeping: url)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    // MARK: - Eviction

    /// Caches accumulate one file per scanned root, and a multi-million-node
    /// tree serializes to hundreds of MB — scanning several disks would grow
    /// Caches without bound. Keep the newest few within a byte budget (the
    /// file just written always survives) and sweep stale temp files.
    private static let maxCacheFiles = 8
    private static let maxCacheBytes: Int64 = 4 << 30   // 4 GB

    private static func prune(directory: URL, keeping justWritten: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }

        var caches: [(url: URL, modified: Date, size: Int64)] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: keys)
            let modified = values?.contentModificationDate ?? .distantPast
            // A crash between create and replace can strand temp files;
            // sweep any old enough that no save can still be writing them.
            if url.pathExtension == "tmp" {
                if modified < Date(timeIntervalSinceNow: -3600) {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            guard url.pathExtension == "dmscan" else { continue }
            caches.append((url, modified, Int64(values?.fileSize ?? 0)))
        }

        caches.sort { $0.modified > $1.modified }   // newest first
        var kept = 0
        var bytes: Int64 = 0
        for entry in caches {
            kept += 1
            bytes += entry.size
            if (kept > maxCacheFiles || bytes > maxCacheBytes),
               entry.url != justWritten {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Location

    private static func cacheFileURL(forRoot rootPath: String) -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "OpenDisk"
        return caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("ScanCache", isDirectory: true)
            .appendingPathComponent("\(stableHash(rootPath)).dmscan")
    }

    /// FNV-1a: stable across launches (unlike `Hasher`) and collision-safe
    /// enough for a handful of scan roots; the root path stored inside the
    /// file is the authoritative check.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
