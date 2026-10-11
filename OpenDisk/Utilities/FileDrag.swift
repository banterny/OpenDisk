import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drag source and drop target for rows, chart rings and Collector items.
//
// This replaces SwiftUI's `.draggable`/`.dropDestination` pair. Those could
// only carry a `Transferable`, and a multi-row selection had to travel as one
// encoded group — so a drag to another app arrived as a single JSON blob
// rather than as files, and items could not be dragged back out of the
// Collector at all (upstream issue #7). An AppKit dragging session writes one
// pasteboard item per file, exactly as Finder does.
// (Ported from upstream e9a1158 and 43e4967.)
//
// Two things here are deliberately NOT as upstream has them:
//
// 1. The private pasteboard type is this fork's existing
//    `ideals.OpenDisk.collected-files` (CLAUDE.md invariant 5), not upstream's
//    new `ideals.OpenDisk.collected-file`.
// 2. A drag out of the app may only *copy* — see `operationMask(for:)`.

extension NSPasteboard.PasteboardType {
    static let openDiskCollectedFiles = NSPasteboard.PasteboardType(
        UTType.openDiskCollectedFiles.identifier
    )
}

/// One dragged file on the pasteboard.
///
/// A real file is written as its file URL and *nothing else* — byte for byte
/// what Finder writes — so every other app treats it as an ordinary file
/// drag. An item with no file behind it (a synthetic "::" row), or one
/// dragged out of the Collector (`exportsFileURL: false`), is written only as
/// the app-private type, which no other app understands: it can be dropped
/// back into this window and nowhere else.
final class FileDragItem: NSObject, NSPasteboardWriting {
    let file: CollectedFile
    let exportsFileURL: Bool

    init(_ file: CollectedFile, exportsFileURL: Bool = true) {
        self.file = file
        self.exportsFileURL = exportsFileURL
    }

    private var fileURL: NSURL? {
        exportsFileURL && !file.path.hasPrefix("::") ? file.url as NSURL : nil
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        fileURL?.writableTypes(for: pasteboard) ?? [.openDiskCollectedFiles]
    }

    func writingOptions(
        forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        fileURL?.writingOptions(forType: type, pasteboard: pasteboard) ?? []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        // The encoded form exists so the item has *some* content under the
        // private type; nothing in this app decodes it back (see
        // `InAppFileDropDelegate`).
        guard let fileURL else { return try? JSONEncoder().encode(file) }
        return fileURL.pasteboardPropertyList(forType: type)
    }
}

/// The app's single AppKit dragging source.
///
/// It also holds `activeFiles` — the files of the drag currently in flight —
/// which is what the drop target reads instead of the pasteboard.
@MainActor
final class FileDragSource: NSObject, NSDraggingSource {
    static let shared = FileDragSource()

    /// Drag images are rendered per item; past a dozen the stack is just a
    /// blur and each one costs an `ImageRenderer` pass at drag start.
    private static let maxPreviewImages = 12
    private var onEnd: ((NSDragOperation) -> Void)?
    /// Non-nil exactly while a drag that began in this app is in flight.
    private(set) var activeFiles: [CollectedFile]?

    /// Starts a dragging session for `files` from the mouse event being
    /// handled right now. Returns false (and starts nothing) when there is no
    /// such event — a session cannot be begun after the fact.
    @discardableResult
    func begin(
        _ files: [CollectedFile],
        exportsFileURLs: Bool = true,
        onEnd: @escaping (NSDragOperation) -> Void
    ) -> Bool {
        guard !files.isEmpty,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let view = event.window?.contentView
        else { return false }

        let cursor = view.convert(event.locationInWindow, from: nil)
        let items = files.enumerated().map { index, file in
            let item = NSDraggingItem(
                pasteboardWriter: FileDragItem(file, exportsFileURL: exportsFileURLs)
            )
            let image = index < Self.maxPreviewImages ? Self.previewImage(for: file) : nil
            let size = image?.size ?? NSSize(width: 32, height: 32)
            // Fan the images out slightly so a multi-item drag reads as a stack.
            let offset = CGFloat(min(index, Self.maxPreviewImages)) * 3
            let origin = NSPoint(
                x: cursor.x - 14 + offset,
                y: cursor.y - size.height / 2 + (view.isFlipped ? offset : -offset)
            )
            item.setDraggingFrame(NSRect(origin: origin, size: size), contents: image)
            return item
        }

        // A previous session that never reported its end must not leave its
        // callback (or its files) attached to this one.
        finish()
        self.onEnd = onEnd
        activeFiles = files
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        // Collector drag-outs that land nowhere are *removed*, so sliding the
        // image back to where it started would say the opposite.
        session.animatesToStartingPositionsOnCancelOrFail = exportsFileURLs
        return true
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    /// What a drop target is allowed to do with a drag from this app.
    ///
    /// Outside the app: **copy only.** Upstream (43e4967) also offers `.move`
    /// and `.generic` there, which lets Finder *move* the dragged file — and
    /// dropping on the Dock's Trash is a move. That would be a way to
    /// relocate or bin a file from this app's window with no confirmation and
    /// no `ProtectedPaths` check, which is the one thing this fork's deletion
    /// path exists to prevent (SECURITY-REVIEW.md, H1/C2). `.generic` is
    /// excluded for the same reason: Finder reads it as "do your default",
    /// and its default on the same volume is a move. With copy alone, Finder
    /// copies and the Trash refuses the drop.
    ///
    /// Inside the app the operation is only a signal to our own drop target
    /// (which proposes `.copy`); nothing is copied or moved.
    nonisolated static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        finish(operation)
    }

    private func finish(_ operation: NSDragOperation = []) {
        let pending = onEnd
        onEnd = nil
        activeFiles = nil
        pending?(operation)
    }

    private static func previewImage(for file: CollectedFile) -> NSImage? {
        let renderer = ImageRenderer(content: FileDragLabel(file: file))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

/// The drag image for one item: icon, name, size — the same look the old
/// SwiftUI drag preview had.
private struct FileDragLabel: View {
    let file: CollectedFile

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: file.path.hasPrefix("::") ? FileIcon.folder : FileIcon.icon(for: file.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.name).lineLimit(1)
            Text(file.formattedSize)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.body)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }
}

private struct FileDragModifier: ViewModifier {
    let files: (CGPoint) -> [CollectedFile]
    let exportsFileURLs: Bool
    let onBegin: ([CollectedFile]) -> Void
    let onEnd: (NSDragOperation) -> Void

    @State private var isDragging = false

    func body(content: Content) -> some View {
        // simultaneousGesture so the view's own tap/selection gestures keep
        // working. The SwiftUI gesture only *detects* the drag: on its first
        // change it hands over to an AppKit dragging session, which then owns
        // the mouse until release — so `onChanged` effectively fires once.
        content.simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard !isDragging else { return }
                    isDragging = true
                    // Resolved at the *start* location: by now the pointer
                    // has moved, possibly off the thing that was grabbed.
                    let payload = files(value.startLocation)
                    guard !payload.isEmpty else { return }
                    onBegin(payload)
                    let dragging = $isDragging
                    let started = FileDragSource.shared.begin(
                        payload, exportsFileURLs: exportsFileURLs
                    ) { operation in
                        dragging.wrappedValue = false
                        onEnd(operation)
                    }
                    // No session means no end callback is coming: undo
                    // whatever `onBegin` set up right away.
                    if !started { onEnd([]) }
                }
                .onEnded { _ in isDragging = false }
        )
    }
}

extension View {
    /// Makes the view a drag source for files.
    ///
    /// - Parameters:
    ///   - files: what to drag, given where in the view the drag started.
    ///     Returning an empty array makes the drag a no-op.
    ///   - exportsFileURLs: false for drags that must stay inside this
    ///     window (items leaving the Collector).
    func fileDrag(
        _ files: @escaping (CGPoint) -> [CollectedFile],
        exportsFileURLs: Bool = true,
        onBegin: @escaping ([CollectedFile]) -> Void = { _ in },
        onEnd: @escaping (NSDragOperation) -> Void = { _ in }
    ) -> some View {
        modifier(FileDragModifier(
            files: files, exportsFileURLs: exportsFileURLs, onBegin: onBegin, onEnd: onEnd
        ))
    }
}

/// The Collector's drop target.
///
/// It accepts a drop only while `FileDragSource.shared.activeFiles` is set —
/// that is, only for a drag that began inside this process — and it takes the
/// files from that property. **The pasteboard is never read.**
///
/// That is what closes SECURITY-REVIEW.md finding H4 for good. The dropped
/// files become deletion candidates, so the old design had to trust whatever
/// payload arrived and relied on a private type to keep foreign payloads out;
/// a type identifier is only a string, and any app can put any string on a
/// pasteboard. Here a file dragged in from Finder, or a payload crafted by
/// another app, fails `validateDrop` whatever types it advertises, because
/// no other process can set this app's in-memory state.
struct InAppFileDropDelegate: DropDelegate {
    let onTargetChange: (Bool) -> Void
    let perform: ([CollectedFile], CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        FileDragSource.shared.activeFiles != nil
    }

    func dropEntered(info: DropInfo) {
        onTargetChange(true)
    }

    func dropExited(info: DropInfo) {
        onTargetChange(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        onTargetChange(false)
        guard let files = FileDragSource.shared.activeFiles else { return false }
        return perform(files, info.location)
    }
}
