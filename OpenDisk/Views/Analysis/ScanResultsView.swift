import SwiftUI

/// Scan results list. Shown from the first moments of a scan: rows appear
/// and re-sort live as sizes stream in. The status footer is provided by
/// the containing view (shared with the chart modes).
struct ScanResultsView: View {
    let items: [FolderItem]
    /// Bumped by the analyzer whenever `items` is replaced — a cheap
    /// animation trigger that avoids diffing the whole row array.
    let displayVersion: Int
    /// Paths of the multi-selected rows, and the same selection as
    /// collector payloads for group drags.
    var selectedPaths: Set<String> = []
    /// The row keyboard navigation is on (the selection anchor).
    var focusedPath: String? = nil
    var selectionFiles: [CollectedFile] = []
    /// Passed through to each row's "Quick Look" context-menu item.
    /// (Ported from upstream 999fae2.)
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onFolderTap: (FolderItem) -> Void

    var body: some View {
        // Largest visible item, so each row's proportional bar reads
        // relative to it. Hoisted to one computation per body evaluation —
        // as a property referenced inside the ForEach closure it would be
        // recomputed O(items) for every materialized row, at streaming-
        // snapshot rate during a live scan.
        let maxSize = items.map(\.size).max() ?? 0
        // A ScrollView + LazyVStack rather than a List: SwiftUI's List
        // intercepts row drag gestures on macOS, which prevents dragging a
        // row into the Collector. This keeps rows fully draggable.
        //
        // The reader exists for keyboard navigation: moving the focus with
        // the arrow keys scrolls the newly focused row into view. Synthetic
        // rows can't be selected, so the focused one is highlighted here
        // instead. (Ported from upstream f7551cf.)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        FolderRowView(
                            item: item,
                            isSelected: selectedPaths.contains(item.path)
                                || (item.path.hasPrefix("::") && focusedPath == item.path),
                            selectionFiles: selectionFiles,
                            sizeFraction: maxSize > 0 ? Double(item.size) / Double(maxSize) : nil,
                            onQuickLook: onQuickLook
                        ) {
                            onFolderTap(item)
                        }
                        .id(item.path)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: focusedPath) { _, path in
                guard let path, items.contains(where: { $0.path == path }) else { return }
                proxy.scrollTo(path)
            }
        }
        // Snappy, not the heavy 0.35s ease — folder navigation should feel
        // immediate, like Finder, while still animating live-scan re-sorts.
        .animation(.snappy(duration: 0.18), value: displayVersion)
        // Icons resolve in display order before their rows scroll into
        // view, so scrolling blits cached bitmaps instead of racing
        // per-row loads. Keyed on displayVersion — the analyzer bumps it
        // exactly when the rows are replaced, so this re-fires precisely
        // then, without allocating and comparing every path string on
        // every body evaluation.
        .task(id: displayVersion) {
            await FileIcon.prewarm(items.map(\.path))
        }
    }
}
