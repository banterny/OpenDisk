import Foundation
import Testing
@testable import OpenDisk

@Suite("ScanMetrics")
struct ScanMetricsTests {

    @Test("incremental-update steps count up, never past the total, and reset")
    func stepsClampAndReset() {
        let metrics = ScanMetrics()
        metrics.add(bytes: 4_096, items: 3)
        metrics.beginSteps(total: 2)
        metrics.completeStep()
        #expect(metrics.snapshot().stepsCompleted == 1)
        #expect(metrics.snapshot().stepsTotal == 2)

        metrics.completeStep()
        metrics.completeStep()
        #expect(metrics.snapshot().stepsCompleted == 2)

        // A full traversal after an abandoned update starts from zero, so
        // the folders the update re-read are not counted twice.
        metrics.reset()
        let cleared = metrics.snapshot()
        #expect(cleared.scannedBytes == 0)
        #expect(cleared.itemsScanned == 0)
        #expect(cleared.stepsCompleted == 0)
        #expect(cleared.stepsTotal == 0)

        metrics.reset(bytes: 1_000, items: 7)
        #expect(metrics.snapshot().scannedBytes == 1_000)
        #expect(metrics.snapshot().itemsScanned == 7)
    }
}
