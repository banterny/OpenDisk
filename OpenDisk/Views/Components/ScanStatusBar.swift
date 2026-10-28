import SwiftUI

/// Thin bar under the file list: what a running scan is doing, and how
/// long the last one took once it finishes.
///
/// The redesign moved the folder's size and item count to the window
/// subtitle and dropped the volume-capacity readout (the sidebar shows each
/// disk's capacity), so the bar now carries scan status only. Upstream's
/// version takes a `leading` view slot that every caller fills with
/// `EmptyView` after d2958b7; the fork leaves the slot out. (Ported from
/// upstream 3a6951d, d13954d and ab868c6.)
struct ScanStatusBar: View {
    let isScanning: Bool
    /// What the scan is doing; words the stretch before any item has been
    /// counted (cache + change-journal work reads as a stall otherwise).
    /// (Ported from upstream 999fae2.)
    var phase: ScanPhase = .scanning
    /// Progress through an incremental update (`.applyingChanges`).
    var stepsCompleted = 0
    var stepsTotal = 0
    /// Fraction of the volume's used bytes scanned so far; nil shows an
    /// indeterminate spinner.
    let progressFraction: Double?
    /// Raw scan counters; this view owns their formatting.
    let scannedBytes: Int64
    let itemsScanned: Int
    let scanStartDate: Date?
    let scanDuration: TimeInterval

    private var scanStatus: String {
        "Scanning: \(ByteFormatter.formatFileSize(scannedBytes)) (\(itemsScanned.formatted()) items)"
    }

    private var filesPerSecond: String {
        guard let scanStartDate, itemsScanned > 0 else { return "" }
        let elapsed = Date().timeIntervalSince(scanStartDate)
        guard elapsed > 0 else { return "" }
        return "\(Int(Double(itemsScanned) / elapsed).formatted()) files/sec"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                status
                    .font(.footnote)
                    .lineLimit(1)
                    // Reserve room while scanning so the text doesn't
                    // jitter the bar's layout as the numbers change width.
                    .frame(minWidth: isScanning ? 190 : nil, alignment: .trailing)
                    .padding(.trailing, 14)
            }
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    /// Each scanning state shortens in steps (`ViewThatFits`) rather than
    /// truncating mid-number when the list column is narrow.
    @ViewBuilder
    private var status: some View {
        if isScanning && phase == .checkingChanges {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking what changed since the last scan…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if isScanning && phase == .applyingChanges {
            HStack(spacing: 6) {
                ProgressView(value: Double(stepsCompleted), total: Double(max(stepsTotal, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 80)
                ViewThatFits(in: .horizontal) {
                    Text("Updating changed folders (\(stepsCompleted.formatted()) of \(stepsTotal.formatted()))")
                    Text("\(stepsCompleted.formatted()) of \(stepsTotal.formatted())")
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        } else if isScanning {
            HStack(spacing: 6) {
                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 80)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(itemsScanned > 0 ? scanStatus : "Scanning…")
                            .foregroundStyle(.secondary)
                        if !filesPerSecond.isEmpty {
                            Text("· \(filesPerSecond)")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(itemsScanned > 0 ? scanStatus : "Scanning…")
                        .foregroundStyle(.secondary)
                    Text(itemsScanned > 0 ? ByteFormatter.formatFileSize(scannedBytes) : "Scanning…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if scanDuration > 0 {
            Text(DurationFormatter.scanDuration(scanDuration))
                .foregroundStyle(.tertiary)
        }
    }
}
