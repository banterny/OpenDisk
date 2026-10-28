import SwiftUI

/// Scan results list. Shown from the first moments of a scan: rows appear
/// and re-sort live as sizes stream in. The status footer is provided by
/// the containing view (shared with the chart modes).
///
/// `header` (the column titles, and the path bar above them) is pinned to
/// the top as a scroll-edge bar, so rows scroll under it as in Finder.
/// (Ported from upstream 3a6951d; upstream's pre-macOS 26 fallback, a
/// pinned section header, is not taken — the fork targets macOS 26.)
struct ScanResultsView<Header: View>: View {
    let items: [FolderItem]
    /// Bumped by the analyzer whenever `items` is replaced — a cheap
    /// animation trigger that avoids diffing the whole row array.
    let displayVersion: Int
    /// Paths of the multi-selected rows, and the same selection as
    /// collector payloads for group drags.
    var selectedPaths: Set<String> = []
    /// The row keyboard navigation is on (the selection anchor).
    var focusedPath: String? = nil
    var showsDetailColumns: Bool = true
    var kindWidth: CGFloat? = nil
    var selectionFiles: [CollectedFile] = []
    /// Passed through to each row's "Quick Look" context-menu item.
    /// (Ported from upstream 999fae2.)
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onSelect: (FolderItem) -> Void
    let onOpen: (FolderItem) -> Void
    @ViewBuilder let header: Header

    var body: some View {
        // The reader exists for keyboard navigation: moving the focus with
        // the arrow keys scrolls the newly focused row into view. Synthetic
        // rows can't be selected, so the focused one is highlighted here
        // instead. (Ported from upstream f7551cf.)
        ScrollViewReader { proxy in
            scrollContent
                // The list is rebuilt per folder (`.id(currentPath)` in the
                // caller), so going back up lands on the folder just left,
                // as Finder does. (Ported from upstream 59d87ab.)
                .onAppear {
                    guard let focusedPath, items.contains(where: { $0.path == focusedPath }) else { return }
                    proxy.scrollTo(focusedPath)
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

    /// A ScrollView + LazyVStack rather than a List: SwiftUI's List
    /// intercepts row drag gestures on macOS, which prevents dragging a
    /// row into the Collector. This keeps rows fully draggable.
    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                rows
            }
            .padding(.bottom, 4)
        }
        .safeAreaBar(edge: .top) {
            header
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }

    private var rows: some View {
        // Largest visible item, so each row's proportional bar reads
        // relative to it. Computed once per evaluation, not per row — as a
        // property referenced inside the ForEach closure it would be
        // recomputed O(items) for every materialized row, at streaming-
        // snapshot rate during a live scan.
        let maxSize = items.map(\.size).max() ?? 0
        return ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            FolderRowView(
                item: item,
                index: index,
                isSelected: selectedPaths.contains(item.path)
                    || (item.path.hasPrefix("::") && focusedPath == item.path),
                showsDetailColumns: showsDetailColumns,
                kindWidth: kindWidth,
                selectionFiles: selectionFiles,
                sizeFraction: maxSize > 0 ? Double(item.size) / Double(maxSize) : nil,
                onQuickLook: onQuickLook,
                onSelect: { onSelect(item) },
                onOpen: { onOpen(item) }
            )
            .id(item.path)
        }
    }
}
