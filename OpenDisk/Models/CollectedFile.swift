import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file or folder the user has dragged into the Collector for deletion.
/// A small value type so it can ride a drag (see `FileDrag.swift`)
/// and be handed to a background actor for the actual removal.
struct CollectedFile: Codable, Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    /// Aggregate on-disk size (for a directory, the whole subtree) as the
    /// scan measured it — reused so the Collector total is instant.
    let size: Int64
    let isDirectory: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var formattedSize: String { ByteFormatter.formatFileSize(size) }

    init(path: String, name: String, size: Int64, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }

    /// Build from a displayed row, preserving the size the scan already knows.
    init(_ item: FolderItem) {
        self.init(path: item.path, name: item.name, size: item.size, isDirectory: item.isDirectory)
    }
}

extension UTType {
    /// The Collector's private drag payload type, exported in
    /// `OpenDisk-Info.plist` and conforming to `public.json`.
    ///
    /// It must not be `public.json` itself: that is a system-wide type every
    /// `.json` file on the machine advertises, and this type marks a drag as
    /// one the Collector may act on. See SECURITY-REVIEW.md, finding H4.
    ///
    /// Since the drag rewrite ported from upstream e9a1158/43e4967 the type
    /// is carried only by in-app drags that have no real file behind them
    /// (the hidden-space row, and items dragged back out of the Collector),
    /// and the drop target no longer decodes it at all — it takes the files
    /// from `FileDragSource.activeFiles`, in-process state no other app can
    /// write. The type is kept private regardless, so the payload stays
    /// meaningless to everything else. See `FileDrag.swift`.
    static let openDiskCollectedFiles = UTType(
        exportedAs: "ideals.OpenDisk.collected-files", conformingTo: .json
    )
}
