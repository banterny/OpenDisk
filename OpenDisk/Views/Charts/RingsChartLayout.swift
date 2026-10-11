import CoreGraphics
import Foundation

/// Pure geometry for the rings chart (baobab-style sunburst): concentric
/// rings, one per depth level, each item an annular sector whose sweep is
/// proportional to its share of the whole.
///
/// Angles are in radians, measured with `atan2(dy, dx)` semantics in a
/// y-down coordinate space: 0 points east and angles grow toward the
/// visually clockwise direction. Drawing and hit-testing share this
/// convention.
enum RingsChartLayout {

    /// Sectors sweeping less than this are not drawn (≈1.7°).
    static let itemMinAngle = 0.03
    /// Stroke marking items whose children were cut off by the depth limit.
    static let continuedEdgeWidth: CGFloat = 3
    static let continuedEdgeGap: CGFloat = 4
    static let borderWidth: CGFloat = 1
    static let padding: CGFloat = 10

    struct Segment: Equatable {
        let path: String
        let name: String
        let size: Int64
        let kind: ChartItem.Kind
        let depth: Int
        let fractionOfRoot: Double
        let hasHiddenChildren: Bool
        /// Radians; see the coordinate convention above.
        let startAngle: Double
        let sweep: Double
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        /// 0..200 input to `ChartPalette.fill`.
        let colorPosition: Double
    }

    struct Layout: Equatable {
        let center: CGPoint
        let ringThickness: CGFloat
        /// The free space drawn as a wedge, or nil when there is none — kept
        /// on the layout so the center label can quote it without the view
        /// threading the figure through separately.
        let freeBytes: Int64?
        /// Root first, then outer rings in traversal order; the free-space
        /// wedge, when present, is last.
        let segments: [Segment]

        /// The segment under `point`, or nil over empty space.
        func segment(at point: CGPoint) -> Segment? {
            let dx = point.x - center.x
            let dy = point.y - center.y
            let radius = (dx * dx + dy * dy).squareRoot()
            guard let root = segments.first else { return nil }
            if radius <= root.outerRadius { return root }
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            return segments.first { segment in
                segment.depth > 0
                    && radius > segment.innerRadius && radius <= segment.outerRadius
                    && angle >= segment.startAngle
                    && angle < segment.startAngle + segment.sweep
            }
        }
    }

    static func layout(root: ChartItem, in size: CGSize, freeBytes: Int64? = nil) -> Layout {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(min(size.width, size.height) / 2 - padding, 1)
        let thickness = maxRadius / CGFloat(ChartItem.maxDepth + 1)

        // With free space shown, the full circle stands for used + free and
        // the scanned tree is squeezed into its share; the remainder becomes
        // one synthetic wedge on the innermost ring. Without it the tree
        // takes the whole circle, exactly as before.
        // (Ported from upstream ccc37cd.)
        let free = max(freeBytes ?? 0, 0)
        let total = Double(root.size) + Double(free)
        let usedSweep = free > 0 && total > 0
            ? 2 * .pi * Double(root.size) / total
            : 2 * .pi

        var segments: [Segment] = []
        appendSegments(
            of: root, startAngle: 0, sweep: usedSweep,
            thickness: thickness, into: &segments
        )
        if free > 0 {
            segments.append(Segment(
                path: FreeSpaceInfo.sentinelPath, name: FreeSpaceInfo.name,
                size: free, kind: .synthetic, depth: 1,
                fractionOfRoot: Double(free) / total,
                hasHiddenChildren: false,
                startAngle: usedSweep, sweep: 2 * .pi - usedSweep,
                innerRadius: thickness, outerRadius: thickness * 2,
                colorPosition: 0
            ))
        }
        return Layout(
            center: center, ringThickness: thickness,
            freeBytes: free > 0 ? free : nil, segments: segments
        )
    }

    private static func appendSegments(
        of item: ChartItem,
        startAngle: Double,
        sweep: Double,
        thickness: CGFloat,
        into segments: inout [Segment]
    ) {
        guard item.depth == 0 || sweep >= itemMinAngle else { return }

        let innerRadius = CGFloat(item.depth) * thickness
        segments.append(Segment(
            path: item.path, name: item.name, size: item.size,
            kind: item.kind, depth: item.depth,
            fractionOfRoot: item.fractionOfRoot,
            hasHiddenChildren: item.hasHiddenChildren,
            startAngle: startAngle, sweep: sweep,
            innerRadius: innerRadius, outerRadius: innerRadius + thickness,
            colorPosition: (startAngle + sweep / 2) / (2 * .pi) * 200
        ))

        for child in item.children {
            appendSegments(
                of: child,
                startAngle: startAngle + sweep * child.relStart / 100,
                sweep: sweep * child.relSize / 100,
                thickness: thickness,
                into: &segments
            )
        }
    }
}
