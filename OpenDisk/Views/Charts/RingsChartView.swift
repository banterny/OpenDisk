import SwiftUI

/// Baobab-style rings chart (sunburst): the viewed directory as a center
/// disk, each depth level a concentric ring, sector sweep proportional to
/// size. Redraws live as scan snapshots stream in.
///
/// Split into two stacked canvases so pointer movement stays cheap: the
/// static layer (every sector, border and curved label) repaints only
/// when a new snapshot or resize produces a new layout, and a thin hover
/// overlay repaints the single highlighted segment plus the tip. The
/// layout itself is cached in state — hover events never rebuild it.
struct RingsChartView: View {
    let root: ChartItem
    /// Free space on the volume to draw as a wedge, or nil for none.
    var freeBytes: Int64? = nil
    /// Called with a directory segment's path when it is clicked.
    let onSelectDirectory: (String) -> Void
    /// Called when the center (the viewed directory itself) is clicked.
    let onSelectCenter: () -> Void

    @Environment(Collector.self) private var collector

    @State private var layout: RingsChartLayout.Layout?
    @State private var hoveredPath: String?
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            // The chart is round, so it lives in the largest whole-point
            // square that fits, centred. Laying out in that square (not the
            // pane's full rectangle) means resizing the pane along its
            // longer side changes nothing and costs no relayout — only a
            // change of `side` rebuilds the layout. (Ported from upstream
            // 628985d.)
            let side = min(geometry.size.width, geometry.size.height).rounded(.down)
            let square = CGSize(width: side, height: side)
            ZStack {
                if let layout {
                    StaticChartLayer(layout: layout)
                        .equatable()
                    Canvas { context, size in
                        drawHoverOverlay(layout: layout, in: &context, bounds: size)
                    }
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    hoveredPath = layout?.segment(at: location)?.path
                case .ended:
                    hoveredPath = nil
                }
            }
            // simultaneousGesture (not onTapGesture) so a click doesn't
            // exclusively capture the gesture and starve the drag — the
            // same fix the folder rows use.
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard let segment = layout?.segment(at: value.location) else { return }
                    if segment.depth == 0 {
                        onSelectCenter()
                    } else if segment.kind == .directory {
                        onSelectDirectory(segment.path)
                    }
                }
            )
            // Drag a ring into the Collector — reuses the folder rows' exact
            // drag source, drop pipeline and protected-path blockers. The
            // segment is looked up at the gesture's start point rather than
            // from hover state, which can lag a fast press-and-drag.
            .fileDrag { location in
                draggableSegment(at: location).map { [collectedFile(for: $0)] } ?? []
            } onBegin: { files in
                collector.flagDraggedProtected(protectedReason(for: files))
            } onEnd: { _ in
                collector.flagDraggedProtected(nil)
            }
            // Right-click a ring for the same actions as a list row.
            .contextMenu {
                if let segment = draggableSegment {
                    FileActionsMenu(file: collectedFile(for: segment), collector: collector)
                }
            }
            // VoiceOver: the canvases are invisible to accessibility, so the
            // chart describes itself and exposes the innermost ring's
            // segments (depth 1 only — deeper rings would add hundreds of
            // elements) as navigable children. Drawing/hover is untouched.
            .accessibilityLabel(chartAccessibilityLabel)
            .accessibilityChildren {
                accessibilitySegmentList
            }
            .onChange(of: root, initial: true) {
                layout = RingsChartLayout.layout(root: root, in: square, freeBytes: freeBytes)
            }
            .onChange(of: freeBytes) {
                layout = RingsChartLayout.layout(root: root, in: square, freeBytes: freeBytes)
            }
            .onChange(of: side) {
                layout = RingsChartLayout.layout(root: root, in: square, freeBytes: freeBytes)
            }
            // Fill the pane so the square is centred in it.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    // MARK: - Accessibility

    /// Summarizes the chart for VoiceOver, e.g. "Disk usage chart for
    /// Documents, 12 items, total size 4.2 GB".
    private var chartAccessibilityLabel: String {
        "Disk usage chart for \(root.name), \(root.children.count) "
            + "item\(root.children.count == 1 ? "" : "s"), "
            + "total size \(ByteFormatter.formatFileSize(root.size))"
    }

    /// The innermost ring's segments (the root's direct slices), exposed as
    /// individual accessibility elements. Directories activate the same
    /// navigation a click performs.
    private var accessibilitySegmentList: some View {
        let segments = (layout?.segments ?? []).filter { $0.depth == 1 }
        return VStack {
            ForEach(segments, id: \.path) { segment in
                let percent = String(format: "%.1f", segment.fractionOfRoot * 100)
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(segment.name)
                    .accessibilityValue(
                        "\(ByteFormatter.formatFileSize(segment.size)), \(percent) percent"
                    )
                    .accessibilityAddTraits(segment.kind == .directory ? .isButton : [])
                    .accessibilityAction {
                        guard segment.kind == .directory else { return }
                        onSelectDirectory(segment.path)
                    }
            }
        }
    }

    // MARK: - Ring drag (into the Collector)

    /// The ring under the pointer that can be collected: a real file/folder
    /// (not the center disk, not a synthetic slice).
    private var draggableSegment: RingsChartLayout.Segment? {
        guard let hoveredPath,
              let segment = layout?.segments.first(where: { $0.path == hoveredPath })
        else { return nil }
        return isDraggable(segment) ? segment : nil
    }

    private func draggableSegment(at location: CGPoint) -> RingsChartLayout.Segment? {
        guard let segment = layout?.segment(at: location), isDraggable(segment) else { return nil }
        return segment
    }

    /// A real file/folder ring — not the center disk, not a synthetic
    /// slice. A drag that starts anywhere else carries nothing, so a stray
    /// drag from the center or a gap is a harmless no-op.
    private func isDraggable(_ segment: RingsChartLayout.Segment) -> Bool {
        segment.depth >= 1 && (segment.kind == .directory || segment.kind == .file)
    }

    private func collectedFile(for segment: RingsChartLayout.Segment) -> CollectedFile {
        CollectedFile(
            path: segment.path, name: segment.name,
            size: segment.size, isDirectory: segment.kind == .directory
        )
    }

    /// Why a dragged ring can't be collected (macOS-protected), phrased to
    /// follow its name — drives the Collector's pre-drop "can't delete" state,
    /// identical to a protected folder row.
    private func protectedReason(for files: [CollectedFile]) -> String? {
        for file in files {
            if let reason = ProtectedPaths.reason(for: file.path) {
                return "“\(file.name)” \(reason)"
            }
        }
        return nil
    }

    // MARK: - Hover overlay

    /// Repaints just the hovered segment in its highlight color (with its
    /// label, which the fill would otherwise cover) and the hover tip.
    private func drawHoverOverlay(
        layout: RingsChartLayout.Layout,
        in context: inout GraphicsContext,
        bounds: CGSize
    ) {
        guard let hoveredPath,
              let segment = layout.segments.first(where: { $0.path == hoveredPath }) else {
            return
        }
        ChartDrawing.draw(
            segment, layout: layout, highlighted: true, in: &context
        )
        ChartTipRenderer.draw(
            name: segment.name, size: segment.size,
            fractionOfRoot: segment.fractionOfRoot,
            near: hoverLocation, in: &context, bounds: bounds
        )
    }
}

/// The chart body. `Equatable` on the layout so SwiftUI skips repainting
/// it while only hover state changes (segment arrays are small — the
/// chart model is depth- and fraction-limited).
private struct StaticChartLayer: View, Equatable {
    let layout: RingsChartLayout.Layout

    var body: some View {
        Canvas { context, _ in
            for segment in layout.segments {
                ChartDrawing.draw(
                    segment, layout: layout, highlighted: false, in: &context
                )
            }
        }
    }
}

/// Segment rendering shared by the static layer and the hover overlay.
private enum ChartDrawing {

    static func draw(
        _ segment: RingsChartLayout.Segment,
        layout: RingsChartLayout.Layout,
        highlighted: Bool,
        in context: inout GraphicsContext
    ) {
        let border = GraphicsContext.Shading.color(.black.opacity(0.35))
        let isFreeSpace = segment.path == FreeSpaceInfo.sentinelPath
        let fill = segment.depth == 0
            ? ChartPalette.centerColor(highlighted: highlighted)
            : isFreeSpace
            ? (highlighted ? ChartPalette.freeSpaceHighlighted : ChartPalette.freeSpace).color
            : ChartPalette.fill(
                position: segment.colorPosition,
                depth: segment.depth,
                highlighted: highlighted
            ).color

        if segment.depth == 0 {
            let disk = Path(ellipseIn: CGRect(
                x: layout.center.x - segment.outerRadius,
                y: layout.center.y - segment.outerRadius,
                width: segment.outerRadius * 2,
                height: segment.outerRadius * 2
            ))
            context.fill(disk, with: .color(fill))
            context.stroke(disk, with: border, lineWidth: RingsChartLayout.borderWidth)
            drawCenterLabel(for: segment, layout: layout, in: &context)
            return
        }

        let sector = sectorPath(for: segment, center: layout.center)
        context.fill(sector, with: .color(fill))
        context.stroke(sector, with: border, lineWidth: RingsChartLayout.borderWidth)
        drawSectorLabel(for: segment, layout: layout, in: &context)

        if segment.hasHiddenChildren {
            // Baobab marks depth-limited directories with a short edge
            // just outside the sector: "there is more in here".
            var edge = Path()
            edge.addArc(
                center: layout.center,
                radius: segment.outerRadius + RingsChartLayout.continuedEdgeGap,
                startAngle: .radians(segment.startAngle),
                endAngle: .radians(segment.startAngle + segment.sweep),
                clockwise: false
            )
            context.stroke(
                edge, with: .color(fill),
                lineWidth: RingsChartLayout.continuedEdgeWidth
            )
        }
    }

    private static func sectorPath(
        for segment: RingsChartLayout.Segment, center: CGPoint
    ) -> Path {
        var path = Path()
        let a0 = segment.startAngle
        let a1 = segment.startAngle + segment.sweep
        path.move(to: CGPoint(
            x: center.x + cos(a0) * segment.innerRadius,
            y: center.y + sin(a0) * segment.innerRadius
        ))
        path.addArc(
            center: center, radius: segment.outerRadius,
            startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false
        )
        path.addLine(to: CGPoint(
            x: center.x + cos(a1) * segment.innerRadius,
            y: center.y + sin(a1) * segment.innerRadius
        ))
        path.addArc(
            center: center, radius: segment.innerRadius,
            startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true
        )
        path.closeSubpath()
        return path
    }

    /// Names the larger sectors with text curved along the ring, glyph by
    /// glyph at the sector's mid-radius — so a label uses the space the
    /// arc actually offers instead of spilling straight across ring
    /// boundaries. Drawn only when the whole name fits along the arc and
    /// within the ring's thickness.
    private static func drawSectorLabel(
        for segment: RingsChartLayout.Segment,
        layout: RingsChartLayout.Layout,
        in context: inout GraphicsContext
    ) {
        let midRadius = (segment.innerRadius + segment.outerRadius) / 2
        let thickness = segment.outerRadius - segment.innerRadius
        let arcLength = CGFloat(segment.sweep) * midRadius
        guard thickness >= 12, arcLength >= 30 else { return }

        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40)
        var glyphs: [GraphicsContext.ResolvedText] = []
        glyphs.reserveCapacity(segment.name.count)
        for character in segment.name {
            glyphs.append(context.resolve(
                Text(String(character))
                    .font(.caption2)
                    .foregroundColor(.black.opacity(0.75))
            ))
        }

        let glyphWidths: [CGFloat] = glyphs.map { $0.measure(in: unbounded).width }
        let totalWidth: CGFloat = glyphWidths.reduce(0, +)
        let lineHeight: CGFloat = glyphs.first?.measure(in: unbounded).height ?? 12
        guard totalWidth <= arcLength * 0.85, lineHeight <= thickness * 0.85 else { return }

        // In the lower half of the circle, glyphs run along decreasing
        // angle with flipped rotation so the text never reads upside down
        // (arch on top, bowl on the bottom).
        let bisector = segment.startAngle + segment.sweep / 2
        let readsReversed = sin(bisector) > 0
        let totalAngle = Double(totalWidth / midRadius)
        var cursor = readsReversed ? bisector + totalAngle / 2 : bisector - totalAngle / 2

        for (index, glyph) in glyphs.enumerated() {
            let glyphAngle = Double(glyphWidths[index] / midRadius)
            let angle = readsReversed ? cursor - glyphAngle / 2 : cursor + glyphAngle / 2
            var glyphContext = context
            glyphContext.translateBy(
                x: layout.center.x + cos(angle) * midRadius,
                y: layout.center.y + sin(angle) * midRadius
            )
            glyphContext.rotate(by: .radians(readsReversed ? angle - .pi / 2 : angle + .pi / 2))
            glyphContext.draw(glyph, at: .zero)
            cursor += readsReversed ? -glyphAngle : glyphAngle
        }
    }

    private static func drawCenterLabel(
        for segment: RingsChartLayout.Segment,
        layout: RingsChartLayout.Layout,
        in context: inout GraphicsContext
    ) {
        // Primary/secondary rather than fixed black, to sit on the center
        // disk's appearance-dependent fill. (Ported from upstream 628985d.)
        var lines: [GraphicsContext.ResolvedText] = [
            context.resolve(
                Text(segment.name).font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.primary)
            ),
            context.resolve(
                Text(ByteFormatter.formatFileSize(segment.size)).font(.caption2)
                    .foregroundStyle(.secondary)
            ),
        ]
        if let free = layout.freeBytes {
            lines.append(context.resolve(
                Text("\(ByteFormatter.formatFileSize(free)) free").font(.caption2)
                    .foregroundStyle(.secondary)
            ))
        }

        // Up to three lines now (name, size, free), so fit by height as
        // well as width, shedding lines until what is left sits inside the
        // disk: the name first if it is too wide, then from the bottom up.
        let maxWidth = segment.outerRadius * 1.5
        let maxHeight = segment.outerRadius * 1.6
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40)
        var sizes = lines.map { $0.measure(in: unbounded) }
        if sizes[0].width > maxWidth {
            lines.removeFirst()
            sizes.removeFirst()
        }
        while lines.count > 1, sizes.last!.width > maxWidth
            || sizes.reduce(0, { $0 + $1.height }) + CGFloat(sizes.count - 1) * 2 > maxHeight
        {
            lines.removeLast()
            sizes.removeLast()
        }
        guard sizes[0].width <= maxWidth else { return }

        let totalHeight = sizes.reduce(0) { $0 + $1.height } + CGFloat(sizes.count - 1) * 2
        var y = layout.center.y - totalHeight / 2
        for (line, size) in zip(lines, sizes) {
            context.draw(line, at: CGPoint(x: layout.center.x, y: y + size.height / 2))
            y += size.height + 2
        }
    }
}
