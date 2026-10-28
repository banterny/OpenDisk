import Foundation
import Synchronization

/// Shared scan counters, updated once per directory (never per file), so a
/// single fast lock stays effectively uncontended even with dozens of
/// workers hammering the filesystem.
final class ScanMetrics: Sendable {

    private struct Counters {
        var scannedBytes: Int64 = 0
        var itemsScanned: Int64 = 0
        var unreadableDirectories = 0
        var phase: ScanPhase = .scanning
        var stepsCompleted = 0
        var stepsTotal = 0
    }

    private let state = Mutex(Counters())

    /// Marks what the scan is doing; surfaced through `snapshot()` so the
    /// status bar can explain a stretch with no items counted yet.
    /// (Ported from upstream 999fae2.)
    func setPhase(_ phase: ScanPhase) {
        state.withLock { $0.phase = phase }
    }

    /// Directories the scan failed to open so far.
    var unreadableDirectories: Int {
        state.withLock { $0.unreadableDirectories }
    }

    /// Records one directory the scan could not open.
    func addUnreadable() {
        state.withLock { $0.unreadableDirectories += 1 }
    }

    /// Starts a stepped stretch of work (the incremental update), so the
    /// status bar can show "n of total" where a byte count would mean
    /// nothing. (Ported from upstream d13954d.)
    func beginSteps(total: Int) {
        state.withLock {
            $0.stepsCompleted = 0
            $0.stepsTotal = total
        }
    }

    /// One step done; never runs past the total.
    func completeStep() {
        state.withLock { $0.stepsCompleted = min($0.stepsCompleted + 1, $0.stepsTotal) }
    }

    /// Restarts the counters, optionally at a known figure. Called before a
    /// full traversal that follows an abandoned incremental update — whose
    /// re-read folders were already counted, and would otherwise be counted
    /// twice — and after a successful one, to show the size of the whole
    /// updated tree rather than only the folders re-read.
    /// (Ported from upstream d13954d.)
    func reset(bytes: Int64 = 0, items: Int = 0) {
        state.withLock {
            $0.scannedBytes = bytes
            $0.itemsScanned = Int64(items)
            $0.stepsCompleted = 0
            $0.stepsTotal = 0
        }
    }

    /// Records one directory's worth of results.
    func add(bytes: Int64, items: Int) {
        state.withLock {
            $0.scannedBytes += bytes
            $0.itemsScanned += Int64(items)
        }
    }

    func snapshot() -> ScanProgress {
        state.withLock {
            ScanProgress(
                scannedBytes: $0.scannedBytes,
                itemsScanned: Int($0.itemsScanned),
                phase: $0.phase,
                stepsCompleted: $0.stepsCompleted,
                stepsTotal: $0.stepsTotal
            )
        }
    }
}
