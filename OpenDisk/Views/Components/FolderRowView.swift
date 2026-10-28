import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Column geometry shared by the list header and every row, so the two
/// line up at any text size. Widths are at the default size; `ListScale`
/// scales them. (Ported from upstream 3a6951d, with 71d09de's
/// name-column-fills-the-width layout.)
enum FileColumns {
    static let spacing: CGFloat = 10
    static let icon: CGFloat = 20
    static let size: CGFloat = 76
    static let bar: CGFloat = 48
    static let kind: CGFloat = 150
    static let kindMin: CGFloat = 56

    /// The Kind column sized to its widest label in this folder (within
    /// bounds), so a folder of "Folder"s does not waste 150 points.
    @MainActor
    static func kindWidth(for items: [FolderItem], scale: ListScale) -> CGFloat {
        var labels = Set<String>()
        for item in items { labels.insert(FileKind.description(for: item)) }
        let rowFont = NSFont.systemFont(ofSize: scale.fontSize)
        let headerFont = NSFont.systemFont(ofSize: scale.headerFontSize, weight: .medium)
        var widest = ("Kind" as NSString).size(withAttributes: [.font: headerFont]).width
        for label in labels {
            widest = max(widest, (label as NSString).size(withAttributes: [.font: rowFont]).width)
        }
        return min(scale.scaled(kind), max(scale.scaled(kindMin), widest.rounded(.up) + 4))
    }
    static let inset: CGFloat = 8
    static let rowHeight: CGFloat = 28
    /// Below this list width the Kind column is dropped.
    static let detailMinWidth: CGFloat = 460
}

/// The list's text size (View ▸ Make Text Bigger / Smaller, ⌘+ ⌘− ⌘0),
/// stored as a step into `fontSizes` so a bad stored value can only clamp.
/// (Ported from upstream 3a6951d.)
struct ListScale: Equatable {
    static let fontSizes: [CGFloat] = [11, 12, 13, 15, 17, 20]
    static let defaultLevel = 2
    static let defaultsKey = "list_text_size_level"

    let level: Int

    init(level: Int) {
        self.level = min(max(level, 0), Self.fontSizes.count - 1)
    }

    var fontSize: CGFloat { Self.fontSizes[level] }
    var headerFontSize: CGFloat { max(10, fontSize - 2) }
    var icon: CGFloat { scaled(FileColumns.icon) }
    var rowHeight: CGFloat { scaled(FileColumns.rowHeight) }

    /// A default-size measurement at this text size.
    func scaled(_ base: CGFloat) -> CGFloat {
        (base * fontSize / Self.fontSizes[Self.defaultLevel]).rounded()
    }
}

extension EnvironmentValues {
    @Entry var listScale = ListScale(level: ListScale.defaultLevel)
}

/// The Kind column's text, as Finder words it ("PDF document", "Folder",
/// "Application"). Worked out from the name's extension alone — no file is
/// opened or stat'ed — and cached per extension, since a list re-renders
/// at streaming rate during a scan. (Ported from upstream 3a6951d.)
@MainActor
enum FileKind {
    private static var cache: [String: String] = [:]

    static func description(for item: FolderItem) -> String {
        if item.path == HiddenSpaceInfo.sentinelPath { return "Purgeable" }
        if item.path.hasPrefix("::") { return item.isDirectory ? "Folder" : "—" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        let key = (item.isDirectory ? "d:" : "f:") + ext
        if let cached = cache[key] { return cached }
        let resolved = resolve(ext: ext, isDirectory: item.isDirectory)
        cache[key] = resolved
        return resolved
    }

    private static func resolve(ext: String, isDirectory: Bool) -> String {
        guard !ext.isEmpty else { return isDirectory ? "Folder" : "Document" }
        let type = isDirectory
            ? UTType(filenameExtension: ext, conformingTo: .directory)
            : UTType(filenameExtension: ext)
        guard let type, !type.isDynamic, let description = type.localizedDescription else {
            return isDirectory ? "Folder" : "Document"
        }
        // A folder named "photos.2024" is still a folder; only a package
        // (an app, a library bundle) takes its type's name.
        if isDirectory && !type.conforms(to: .package) { return "Folder" }
        return description.prefix(1).uppercased() + description.dropFirst()
    }
}

/// One row in the results list, laid out like a Finder list view: icon,
/// name, size, a proportional bar, and Kind when there is room. Uses the
/// real Finder icon for the file/folder (via NSWorkspace) so the list reads
/// as native, and is draggable into the Collector for deletion.
///
/// Clicks follow Finder: one click selects (⌘ and ⇧ extend, handled by the
/// list), a double click opens a folder or Quick Looks a file. Before the
/// redesign a single click on a folder opened it. (Ported from upstream
/// 3a6951d.)
struct FolderRowView: View {
    let item: FolderItem
    /// Position in the list, for the alternating row tint.
    var index: Int = 0
    /// Containing-folder string shown after the name (search results,
    /// where hits come from anywhere in the tree). Nil in directory
    /// listings, where location is implied by the breadcrumb.
    var locationDetail: String? = nil
    /// Whether this row is part of the current multi-selection.
    var isSelected: Bool = false
    /// Whether the list is wide enough for the Kind column.
    var showsDetailColumns: Bool = true
    /// The Kind column's width for this listing (see
    /// `FileColumns.kindWidth`); nil uses the default.
    var kindWidth: CGFloat? = nil
    /// Every currently selected item as a collector payload. A drag (or a
    /// context-menu collect) from a selected row carries all of them.
    var selectionFiles: [CollectedFile] = []
    /// This item's size as a fraction of the largest sibling, driving the
    /// proportional bar. Nil (e.g. in search results) hides the bar.
    var sizeFraction: Double? = nil
    /// Adds a "Quick Look" context-menu item for folders (files get it as
    /// their "open" action). Nil hides the item. (Ported from upstream
    /// 999fae2.)
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onSelect: () -> Void
    let onOpen: () -> Void

    @Environment(Collector.self) private var collector
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.listScale) private var scale
    /// The row's real Finder icon once resolved off-main; until then the
    /// row draws a type icon so scrolling never blocks on IconServices.
    @State private var resolvedIcon: NSImage?

    /// Synthetic rows ("::"-prefixed, e.g. Purgeable Space) have no on-disk
    /// location, so they can't be dragged, collected, or revealed.
    private var isSynthetic: Bool { item.path.hasPrefix("::") }
    private var fileURL: URL { URL(fileURLWithPath: item.path) }
    /// Selected in the key window: the accent highlight with white text.
    /// In a background window a selection turns grey, as in Finder.
    private var isEmphasized: Bool { isSelected && controlActiveState != .inactive }

    var body: some View {
        // The "Purgeable Space" row is draggable — dropping it collects its
        // real, deletable cache folders (expanded on drop, sizes match).
        // Any other synthetic row (there are none now) stays non-draggable.
        if isSynthetic && item.path != HiddenSpaceInfo.sentinelPath {
            row
        } else {
            // Not a Button: a Button's press gesture swallows the drag on
            // macOS, so the row would never become draggable.
            //
            // Protected items (Users, system folders, …) can still be *picked
            // up*, but the moment the drag begins we tell the Collector why it
            // can't be collected — so it says "no" immediately, before the
            // user even reaches the drop zone — and clear it when the drag ends.
            row.fileDrag { _ in
                dragFiles
            } onBegin: { _ in
                collector.flagDraggedProtected(draggedProtectedReason)
            } onEnd: { _ in
                collector.flagDraggedProtected(nil)
            }
        }
    }

    /// What a drag from this row carries: the whole selection when the row
    /// is part of it, otherwise just the row itself (Finder's rule).
    private var dragFiles: [CollectedFile] {
        isSelected && selectionFiles.count > 1 ? selectionFiles : [CollectedFile(item)]
    }

    private var draggedProtectedReason: String? {
        for file in dragFiles {
            if let reason = ProtectedPaths.reason(for: file.path) {
                return "“\(file.name)” \(reason)"
            }
        }
        return nil
    }

    private var primaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
    }

    private var secondaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    private var tertiaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary)
    }

    private var row: some View {
        HStack(spacing: FileColumns.spacing) {
            icon
                .frame(width: scale.icon, height: scale.icon)

            // The name column takes whatever width is left (71d09de), and
            // a search hit's location gives way to the name first.
            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(primaryStyle)
                if let locationDetail {
                    Text(locationDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(tertiaryStyle)
                        .layoutPriority(-1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right-aligned size, Finder-style; "--" while a folder is still
            // being tallied (instead of a loading-bar skeleton).
            Group {
                if item.sizeIsKnown {
                    Text(item.formattedSize)
                        .monospacedDigit()
                        .foregroundStyle(secondaryStyle)
                } else {
                    Text("--")
                        .foregroundStyle(tertiaryStyle)
                }
            }
            .lineLimit(1)
            .frame(width: scale.scaled(FileColumns.size), alignment: .trailing)

            sizeBar
                .frame(width: scale.scaled(FileColumns.bar))

            if showsDetailColumns {
                Text(FileKind.description(for: item))
                    .lineLimit(1)
                    .foregroundStyle(secondaryStyle)
                    .frame(width: kindWidth ?? scale.scaled(FileColumns.kind), alignment: .leading)
                    .help(FileKind.description(for: item))
            }
        }
        .font(.system(size: scale.fontSize))
        .padding(.horizontal, FileColumns.inset)
        .frame(height: scale.rowHeight)
        // No per-row .onHover: it fires (and animates) on every row that
        // slides under the cursor while scrolling, which makes fast
        // scrolling of a big list stutter. (The redesign also dropped the
        // hover tint the fork kept here; Finder's list has none.)
        .background { rowBackground }
        .padding(.horizontal, FileColumns.inset)
        .contentShape(Rectangle())
        // Resolve the real Finder icon off the main thread; the row shows
        // a type icon meanwhile. A synchronous per-row IconServices call
        // here was what made fast scrolling through fresh (search) results
        // stutter.
        .task(id: item.path) {
            // Usually a no-op: the list prewarms icons in display order,
            // so by the time a row scrolls in its icon is already cached
            // and the body drew it directly — no state churn mid-scroll.
            guard !isSynthetic, FileIcon.cached(for: item.path) == nil else { return }
            await FileIcon.warm(item.path)
            resolvedIcon = FileIcon.cached(for: item.path)
        }
        // The double click is recognised first; the single-click select is
        // simultaneous (not onTapGesture) so neither starves the drag.
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu { menuContent }
        // VoiceOver: the row is deliberately not a Button (a Button's press
        // gesture would swallow the drag), so it reads as static text
        // without this — combine it into one element that acts like a button.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
    }

    /// Finder's list colours: the system selection colour (grey when the
    /// window is in the background), else every other row tinted.
    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if isSelected {
            shape.fill(Color(nsColor: isEmphasized
                ? .selectedContentBackgroundColor
                : .unemphasizedSelectedContentBackgroundColor))
        } else if index.isMultiple(of: 2) == false {
            shape.fill(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]))
        }
    }

    /// Proportional bar (relative to the largest sibling): a quick read of
    /// how big each item is, only for sized entries. Unsized rows keep the
    /// column's width so the columns stay aligned.
    @ViewBuilder
    private var sizeBar: some View {
        if let sizeFraction, sizeFraction > 0, item.sizeIsKnown {
            Capsule(style: .continuous)
                .fill(isEmphasized ? AnyShapeStyle(Color.white.opacity(0.3)) : AnyShapeStyle(.quaternary))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                            .frame(width: max(3, proxy.size.width * min(1, sizeFraction)))
                    }
                }
        } else {
            Color.clear.frame(height: 4)
        }
    }

    /// Real Finder icon for on-disk items; a symbol for synthetic rows.
    /// Sized by the caller to the list's text size.
    @ViewBuilder
    private var icon: some View {
        if isSynthetic {
            if item.isDirectory {
                // Synthetic folders (Purgeable Space) read as a normal folder.
                Image(nsImage: FileIcon.folder)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
            }
        } else {
            // Cache, then the freshly resolved icon, then a no-I/O type
            // icon — never a blocking per-path lookup during scrolling.
            Image(nsImage: resolvedIcon
                ?? FileIcon.cached(for: item.path)
                ?? FileIcon.typeIcon(
                    forPathExtension: (item.name as NSString).pathExtension,
                    isDirectory: item.isDirectory
                ))
                .resizable()
                .interpolation(.high)
        }
    }

    /// What the menu's first item (and a double click) does: a folder
    /// opens in the list, a file opens in Quick Look — except in search
    /// results, where either opens its folder in the list. Upstream labels
    /// a file "Quick Look" there too; the label here says what happens.
    private var opensInQuickLook: Bool { !item.isDirectory && locationDetail == nil }

    private var openLabel: (title: String, symbol: String) {
        opensInQuickLook ? ("Quick Look", "eye") : ("Open", "folder")
    }

    /// Nothing here deletes: "Add to Collector" queues for the Collector's
    /// own confirmation, through the same `ProtectedPaths` refusal as a
    /// drop. The rest open, preview, reveal or copy text.
    @ViewBuilder
    private var menuContent: some View {
        if !isSynthetic {
            Button {
                onOpen()
            } label: {
                Label(openLabel.title, systemImage: openLabel.symbol)
            }

            Divider()

            Button {
                collector.add(CollectedFile(item))
            } label: {
                Label("Add to Collector", systemImage: "trash")
            }
            // macOS-critical locations can't be deleted.
            .disabled(ProtectedPaths.isProtected(item.path))

            if isSelected && selectionFiles.count > 1 {
                Button {
                    collector.add(selectionFiles.filter {
                        ProtectedPaths.reason(for: $0.path) == nil
                    })
                } label: {
                    Label(
                        "Add \(selectionFiles.count) Selected to Collector",
                        systemImage: "trash"
                    )
                }
            }

            Divider()

            // Listed here unless it is already the first item.
            if !opensInQuickLook, let onQuickLook {
                Button {
                    onQuickLook(item)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }
}
