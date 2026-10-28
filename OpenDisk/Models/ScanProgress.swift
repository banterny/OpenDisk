import Foundation

/// What a running scan is doing right now; drives the status bar's wording
/// during the stretch before any item has been counted.
/// (Ported from upstream 999fae2.)
enum ScanPhase: Equatable, Sendable {
    /// Consulting the previous scan's cache and FSEvents journal to find
    /// what changed — no filesystem items are being counted yet.
    case checkingChanges
    /// Splicing the changed folders the journal reported into the cached
    /// tree. Counted in steps (one per folder), not bytes, since the bytes
    /// were mostly counted by the scan that built the cache.
    /// (Ported from upstream d13954d.)
    case applyingChanges
    /// Reading the filesystem.
    case scanning
}

/// A point-in-time snapshot of a running scan.
struct ScanProgress: Equatable, Sendable {
    let scannedBytes: Int64
    let itemsScanned: Int
    var phase: ScanPhase = .scanning
    /// Progress through `.applyingChanges`; both zero in any other phase.
    var stepsCompleted = 0
    var stepsTotal = 0
}
