import Foundation

/// One node of the rings chart's model: a depth-limited, noise-filtered
/// slice of a scan's `FileTree`.
///
/// Geometry-independent: `relStart`/`relSize` are percentages within the
/// parent, which the rings chart maps to angles. The design (depth limit,
/// thresholds, proportional layout) follows GNOME baobab's chart; the
/// implementation is original Swift.
struct ChartItem: Equatable, Identifiable, Sendable {

    /// What a chart node represents; palette and interaction dispatch on
    /// this (synthetic slices draw gray and are not navigable).
    enum Kind: Equatable, Sendable {
        case file
        case directory
        /// Not a real filesystem item — e.g. the "Purgeable Space" lens's
        /// root slice.
        case synthetic
    }

    /// Paths are stable across successive live snapshots, so hover state
    /// and SwiftUI diffing can track an item while its size streams in.
    var id: String { path }

    let name: String
    let path: String
    let size: Int64
    /// 0 is the chart root (the center disk / whole canvas).
    let depth: Int
    /// Offset within the parent, 0..100 (percent).
    let relStart: Double
    /// Share of the parent, 0..100 (percent).
    let relSize: Double
    /// Share of the whole chart, 0..1.
    let fractionOfRoot: Double
    let kind: Kind
    /// True when children exist but `maxDepth` cut them off; the rings
    /// chart marks such items with an outer "continues" edge.
    let hasHiddenChildren: Bool
    let children: [ChartItem]

    /// Levels shown below the root, matching baobab's MAX_DEPTH.
    static let maxDepth = 5
    /// Items below this share of the whole chart are dropped at build
    /// time — slightly finer than either view's own drawing threshold
    /// (the rings chart hides sweeps under 0.03 rad ≈ 0.48% of the circle).
    static let minVisibleFraction = 0.0015

    /// Builds the chart tree for the directory `node` of `tree`.
    static func build(
        from tree: FileTree,
        at node: FileTree.NodeID,
        name: String,
        path: String
    ) -> ChartItem {
        buildItem(
            tree: tree, node: node, name: name, path: path,
            depth: 0, relStart: 0, relSize: 100, fractionOfRoot: 1
        )
    }

    private static func buildItem(
        tree: FileTree,
        node: FileTree.NodeID,
        name: String,
        path: String,
        depth: Int,
        relStart: Double,
        relSize: Double,
        fractionOfRoot: Double
    ) -> ChartItem {
        let isDirectory = tree.isDirectory(node)
        let totalSize = tree.size(of: node)
        let parentSize = max(totalSize, 1)
        let childIDs = isDirectory ? tree.children(of: node) : []
        let hasChildren = !childIDs.isEmpty
        var children: [ChartItem] = []
        var cursor = 0.0

        if hasChildren && depth < maxDepth {
            let prefix = path.directoryPrefix
            // Drop children too small to draw *before* sorting: a folder
            // of 100,000 small files used to sort all of them on every
            // snapshot, only for the loop below to stop at the first
            // invisible one. The byte threshold is the `minVisibleFraction`
            // test below solved for size, rounded down, so it only ever
            // lets through extra children, which that test still rejects;
            // the chart is unchanged. `fractionOfRoot` is never zero here
            // (1 at the root, and a child is only built once it passed
            // that test), so the division is finite and at most
            // `parentSize`. (Ported from upstream c1ddf4d.)
            let smallestVisible = max(
                Int64((minVisibleFraction / fractionOfRoot * Double(parentSize)).rounded(.down)), 1
            )
            let visibleIDs = tree.sortedForDisplay(
                childIDs.filter { tree.size(of: $0) >= smallestVisible }
            )
            for child in visibleIDs {
                let childSize = tree.size(of: child)
                guard childSize > 0 else { break }
                let share = Double(childSize) / Double(parentSize) * 100
                let childFraction = fractionOfRoot * share / 100
                // Ordered by size, so everything after the first
                // too-small child is also too small.
                guard childFraction >= minVisibleFraction else { break }
                let childName = tree.name(of: child)
                children.append(buildItem(
                    tree: tree, node: child, name: childName,
                    path: prefix + childName,
                    depth: depth + 1, relStart: cursor, relSize: share,
                    fractionOfRoot: childFraction
                ))
                cursor += share
            }
        }

        return ChartItem(
            name: name, path: path, size: totalSize,
            depth: depth, relStart: relStart, relSize: relSize,
            fractionOfRoot: fractionOfRoot,
            kind: isDirectory ? .directory : .file,
            hasHiddenChildren: hasChildren && depth >= maxDepth,
            children: children
        )
    }
}
