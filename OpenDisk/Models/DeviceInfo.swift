import Foundation

/// A scannable device shown in the sidebar: the boot volume group or an
/// external volume.
struct DeviceInfo: Identifiable, Hashable, Sendable {
    /// The scan path is unique per device and stable across refreshes, so
    /// sidebar selection survives device-list rebuilds.
    var id: String { path }

    let name: String
    /// SF Symbol name for the sidebar row.
    let icon: String
    /// Path scanned when the device is selected.
    let path: String
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { totalBytes - availableBytes }

    var formattedTotalStorage: String {
        ByteFormatter.formatDecimalNoFraction(totalBytes)
    }

    var formattedUsedStorage: String {
        ByteFormatter.formatDecimalNoFraction(usedBytes)
    }
}

/// Capacity of the volume containing a path, as the system reports it
/// (`available` already excludes space the system keeps in reserve).
/// (Ported from upstream d628684.)
struct VolumeCapacity: Hashable, Sendable {
    let total: Int64
    /// What the user can actually put on the disk: free blocks *plus*
    /// purgeable space (local Time Machine snapshots, caches macOS evicts on
    /// demand). This is the figure Finder shows as "available", and the one
    /// the status bar must match — reporting bare free blocks made a disk
    /// look tens of GB fuller than Finder said it was.
    let available: Int64
    /// Blocks free right now, purgeable space not included.
    let free: Int64

    /// `availableForImportantUsage` is the system's own free-plus-purgeable
    /// figure. It is absent on volumes that don't support it, and can read
    /// *lower* than `free` — in both cases `free` stands. Clamped to `total`
    /// so `used` can never go negative on a volume reporting nonsense.
    /// (Ported from upstream ab1644a.)
    init(total: Int64, free: Int64, availableForImportantUsage: Int64? = nil) {
        self.total = total
        self.free = free
        self.available = min(total, max(free, availableForImportantUsage ?? 0))
    }

    var used: Int64 { total - available }
    var purgeable: Int64 { available - free }
}
