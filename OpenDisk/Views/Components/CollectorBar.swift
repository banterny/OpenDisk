import SwiftUI
import AppKit
import Quartz

/// DaisyDisk-style deletion tray in the Liquid Glass functional layer. A
/// compact footer (total + Delete) sits in the layout below the chart;
/// hovering reveals the collected-file list, which floats *upward* over the
/// chart — anchored just above the footer so it never covers the controls or
/// resizes the graph.
extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The chart pane, in which both the Collector's own frames ("keep
    /// zones") and drop locations are measured — see
    /// `Collector.resolveDragOut(droppedAt:)`.
    static var collectorDrop: Self { .named("collectorDrop") }
}

struct CollectorBar: View {
    let collector: Collector
    /// True while a drag is hovering the drop target — drives the highlight.
    var isTargeted: Bool = false
    /// Called after a deletion with the freed byte count, so the host can
    /// rescan and bring the updated usage back to the top.
    var onDeleted: (Int64) -> Void

    /// Deletion moves items to the Trash unless the user has opted into
    /// permanent removal in Settings. Recoverable by default: a mis-drag into
    /// the tray should not be an unrecoverable event.
    /// See SECURITY-REVIEW.md, finding H1.
    @AppStorage("delete_permanently") private var deletePermanently = false

    @State private var phase: Phase = .idle
    @State private var footerHovered = false
    @State private var listHovered = false
    @State private var footerHeight: CGFloat = 0
    @State private var showConfirm = false
    @State private var previewItem: PreviewItem?
    @State private var lastResult: Collector.Result?
    @State private var listVisible = false
    @State private var collapseTask: Task<Void, Never>?

    private enum Phase: Equatable { case idle, deleting, done }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    /// The footer is a rounder capsule than the floating panels.
    /// (Ported from upstream f8365ae.)
    private var footerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    /// Empty and idle: the footer shrinks to its hint rather than spanning
    /// the pane. The drop target is the whole pane either way (see
    /// `InAppFileDropTarget` in `DiskAnalysisView`), so this changes
    /// nothing about where a drop lands. (Ported from upstream f8365ae.)
    private var isCompact: Bool {
        phase == .idle && collector.isEmpty && !collecting && !rejecting
    }

    /// Whether the pointer (or an active drag) currently wants the list open.
    /// Drives `listVisible` through a short close delay so crossing the small
    /// gap between the footer and the floating list doesn't collapse it.
    private var wantsList: Bool {
        phase == .idle && !collector.isEmpty && collector.draggingOut == nil
            && (footerHovered || listHovered || isTargeted)
    }

    /// A drag is over the tray *and* it is an incoming one. While one of the
    /// Collector's own items is being dragged out, the tray is a place to
    /// put it back, not a place that is collecting — so it doesn't light up.
    private var collecting: Bool {
        isTargeted && collector.draggingOut == nil
    }

    /// A macOS-protected item is being dragged: the tray refuses it and says so
    /// immediately (the moment it's picked up — not only once it's over the
    /// tray), so the user never even gets to drop it.
    private var rejecting: Bool {
        phase == .idle && collector.draggedProtectedReason != nil
    }

    /// Content height for the floating list: ~one row per item (plus the
    /// panel's own padding), capped so it never overruns the window — only
    /// as tall as it needs to be, then scrolls.
    private var listHeight: CGFloat {
        min(600, CGFloat(collector.count) * 30 + 16)
    }

    var body: some View {
        footerBar
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .collectorDrop)
            } action: { collector.keepZones["footer"] = $0 }
            .onHover { footerHovered = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            // Floating layers are anchored to the footer's bottom, then pushed
            // up by the footer's own height so they sit fully above it (over
            // the graph) without covering the Delete button.
            .overlay(alignment: .bottom) {
                if listVisible {
                    listPanel
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .collectorDrop)
                        } action: { collector.keepZones["list"] = $0 }
                        .onDisappear { collector.keepZones["list"] = nil }
                        .onHover { listHovered = $0 }
                        .offset(y: -(footerHeight + 8))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = collector.blockedNotice {
                    noticeBanner(notice)
                        .offset(y: -(footerHeight + 8))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // Dragging an item out starts under the pointer, so the hover
            // regions would otherwise stay "entered" for the whole drag and
            // pin the list open over the very area the user is dragging to.
            .onChange(of: collector.draggingOut == nil) { _, idle in
                if !idle { listHovered = false; footerHovered = false }
            }
            // Open immediately, close after a short delay: moving the pointer
            // from the footer up to the list (or back) crosses an 8pt gap that
            // belongs to neither hover region. Without the delay the list would
            // flash shut mid-transit; a re-entry cancels the pending close.
            .onChange(of: wantsList) { _, want in
                collapseTask?.cancel()
                if want {
                    listVisible = true
                } else {
                    collapseTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        if !Task.isCancelled { listVisible = false }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .animation(.spring(duration: 0.3), value: listVisible)
            .animation(.easeInOut(duration: 0.15), value: collecting)
            .animation(.spring(duration: 0.3), value: collector.count)
            .animation(.spring(duration: 0.3), value: phase)
            .animation(.spring(duration: 0.3), value: collector.blockedNotice)
            .animation(.easeInOut(duration: 0.15), value: rejecting)
            .animation(.snappy(duration: 0.25), value: collector.deletionProgress)
            .sheet(item: $previewItem) { item in
                QuickLookSheet(url: item.url)
            }
            // Native double-confirmation instead of a countdown.
            .confirmationDialog(
                deletePermanently
                    ? "Permanently delete \(collector.count) item\(collector.count == 1 ? "" : "s")?"
                    : "Move \(collector.count) item\(collector.count == 1 ? "" : "s") to the Trash?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button(
                    deletePermanently
                        ? "Delete \(collector.formattedTotal)"
                        : "Move \(collector.formattedTotal) to Trash",
                    role: .destructive
                ) {
                    Task { await performDeletion() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deletePermanently
                    ? "This permanently deletes the collected items and can’t be undone."
                    : "The items move to the Trash, so you can put them back. The space isn’t reclaimed until you empty the Trash.")
            }
    }

    // MARK: - Footer (always in layout)

    private var footerBar: some View {
        GlassEffectContainer {
            footerContent
                .frame(maxWidth: isCompact ? nil : .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(
                    rejecting ? .regular.tint(.red)
                        : (collecting ? .regular.tint(.accentColor) : .regular),
                    in: footerShape
                )
                .overlay {
                    footerShape.strokeBorder(
                        rejecting ? Color.red : (collecting ? Color.accentColor : .clear),
                        lineWidth: 1.5
                    )
                }
        }
    }

    @ViewBuilder
    private var footerContent: some View {
        if rejecting {
            rejectionView
        } else {
            switch phase {
            case .idle:
                if collector.isEmpty { hintView } else { footerRow }
            case .deleting:  deletingView
            case .done:      doneView
            }
        }
    }

    /// Replaces the footer while a protected item is being dragged: a clear,
    /// immediate "you can't collect this" with the specific reason.
    private var rejectionView: some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign")
            Text(collector.draggedProtectedReason ?? "This item can’t be deleted")
                .lineLimit(3)
        }
        .font(.callout)
        .fontWeight(.semibold)
        // Primary on the red-tinted glass: red text on red read poorly.
        // (Ported from upstream ba6672d; three lines from ab868c6.)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var footerRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(collector.formattedTotal)
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(collector.count) item\(collector.count == 1 ? "" : "s") collected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .fileDrag({ _ in collector.items }, exportsFileURLs: false) { files in
                collector.beginDragOut(files)
            } onEnd: { operation in
                collector.endDragOut(operation: operation)
            }
            Spacer()
            // Liquid Glass prominent button (upstream f8365ae; its pre-macOS
            // 26 capsule fallback is not taken). The label still names what
            // will happen — upstream's always reads "Delete" — and it only
            // opens the confirmation below. (H1)
            Button {
                showConfirm = true
            } label: {
                Text(deletePermanently ? "Delete" : "Move to Trash")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(collector.isEmpty)
        }
    }

    /// Shown when nothing is collected yet: the persistent drop-target hint,
    /// which lights up while a drag is hovering. Shorter wording now that
    /// the footer is compact; the tooltip keeps the full sentence.
    /// (Ported from upstream f8365ae and ba6672d.)
    private var hintView: some View {
        HStack(spacing: 8) {
            Image(systemName: collecting ? "arrow.down.circle.fill" : "arrow.down.circle.dotted")
            Text(collecting ? "Release to collect" : "Drop files to collect")
        }
        .font(.callout)
        .fontWeight(collecting ? .semibold : .medium)
        .foregroundStyle(.primary)
        .frame(maxWidth: collecting ? .infinity : nil)
        .help("Drag files or folders here to stage them for deletion")
        .padding(.vertical, 2)
    }

    private var deletingView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deletingTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let progress = collector.deletionProgress {
                        HStack(spacing: 0) {
                            Text(deletePermanently ? "Freed " : "Moved ").foregroundStyle(.secondary)
                            Text(ByteFormatter.formatFileSize(progress.freedBytes))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(" · \(progress.completed) of \(progress.total)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                Spacer()
            }
            if let progress = collector.deletionProgress, progress.total > 0 {
                ProgressView(
                    value: Double(min(progress.completed, progress.total)),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
                .controlSize(.small)
            }
        }
    }

    /// Names the item currently being removed, e.g. "Deleting npm Cache…".
    private var deletingTitle: String {
        let verb = deletePermanently ? "Deleting" : "Moving"
        if let name = collector.deletionProgress?.currentName, !name.isEmpty {
            return "\(verb) \(name)…"
        }
        return deletePermanently ? "Deleting…" : "Moving to Trash…"
    }

    private var doneView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let result = lastResult {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // Trashed bytes are not reclaimed until the Trash is
                    // emptied, so only permanent deletion may claim "Freed".
                    Text(result.mode == .permanent ? "Freed " : "Moved to Trash: ")
                        .foregroundStyle(.secondary)
                    Text(ByteFormatter.formatFileSize(result.freedBytes)).fontWeight(.semibold)
                }
                if !result.failures.isEmpty {
                    Text(" · \(result.failures.count) couldn't be removed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Floating layers (overlay, over the chart)

    private var listPanel: some View {
        GlassEffectContainer {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(collector.items) { file in
                        CollectedRow(
                            file: file,
                            collector: collector,
                            onRemove: { collector.remove(file) },
                            onPreview: { previewItem = PreviewItem(url: file.url) }
                        )
                    }
                }
                .padding(6)
            }
            // Explicit content-based height: the list is an overlay on the
            // short footer, so a plain maxHeight gets squeezed to the footer's
            // height. Force a height that grows with the item count (only as
            // tall as needed) up to a generous cap, then scroll.
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
            .glassEffect(.regular, in: shape)
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text(text).lineLimit(2)
        }
        .font(.callout)
        // Primary on orange-tinted glass, as with the red rejection.
        // (Ported from upstream ba6672d.)
        .fontWeight(.medium)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange), in: shape)
    }

    // MARK: - Actions

    private func performDeletion() async {
        phase = .deleting
        let result = await collector.deleteAll(using: deletePermanently ? .permanent : .trash)
        lastResult = result
        phase = .done
        // Only a permanent delete reclaims space; a trash move does not, so
        // the host is told nothing was freed and won't report a false gain.
        onDeleted(result.mode == .permanent ? result.freedBytes : 0)
        try? await Task.sleep(for: .seconds(2))
        if phase == .done { phase = .idle }
    }
}

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A single collected file inside the tray: native icon, name, size, and the
/// Preview / Show in Finder / Open in Terminal / Remove context menu.
private struct CollectedRow: View {
    let file: CollectedFile
    let collector: Collector
    let onRemove: () -> Void
    let onPreview: () -> Void

    /// The row's real Finder icon once resolved off-main; until then the
    /// row draws a type icon so the tray never blocks on IconServices.
    @State private var resolvedIcon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from Collector")

            // Cache, then the freshly resolved icon, then a no-I/O type
            // icon — never a blocking per-path IconServices lookup in body.
            Image(nsImage: resolvedIcon
                ?? FileIcon.cached(for: file.path)
                ?? FileIcon.typeIcon(
                    forPathExtension: (file.name as NSString).pathExtension,
                    isDirectory: file.isDirectory
                ))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            Text(file.name).lineLimit(1)

            Spacer()

            Text(file.formattedSize)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .fileDrag({ _ in [file] }, exportsFileURLs: false) { files in
            collector.beginDragOut(files)
        } onEnd: { operation in
            collector.endDragOut(operation: operation)
        }
        .hoverHighlight(cornerRadius: 6)
        // Resolve the real Finder icon off the main thread; the row shows
        // a type icon meanwhile (same pattern as the folder rows).
        .task(id: file.path) {
            guard FileIcon.cached(for: file.path) == nil else { return }
            await FileIcon.warm(file.path)
            resolvedIcon = FileIcon.cached(for: file.path)
        }
        .contextMenu {
            Button(action: onPreview) {
                Label("Preview", systemImage: "eye")
            }
            .keyboardShortcut(.space, modifiers: [])

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                openInTerminal()
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }

            Divider()

            Button(role: .destructive, action: onRemove) {
                Label("Remove “\(file.name)” from Collector", systemImage: "xmark.circle")
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func openInTerminal() {
        let directory = file.isDirectory
            ? file.path
            : (file.path as NSString).deletingLastPathComponent
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

/// Native Quick Look preview shown in a sheet, wrapping AppKit's
/// `QLPreviewView` (SwiftUI's `quickLookPreview` modifier is iOS-only).
private struct QuickLookSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            QuickLookView(url: url)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 680, height: 520)
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.autostarts = true
            preview.previewItem = url as NSURL
            preview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                preview.topAnchor.constraint(equalTo: container.topAnchor),
                preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            context.coordinator.preview = preview
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.preview?.previewItem = url as NSURL
    }

    final class Coordinator {
        var preview: QLPreviewView?
    }
}
