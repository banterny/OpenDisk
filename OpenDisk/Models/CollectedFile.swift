import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A file or folder the user has dragged into the Collector for deletion.
/// A small value type so it can ride SwiftUI drag-and-drop as `Transferable`
/// and be handed to a background actor for the actual removal.
struct CollectedFile: Codable, Transferable, Identifiable, Hashable, Sendable {
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

    static var transferRepresentation: some TransferRepresentation {
        // App-private type, NOT bare `public.json` — see CollectedFileGroup.
        // Also expose a fileURL proxy so an item can be dragged out to Finder.
        CodableRepresentation(contentType: .openDiskCollectedFiles)
        ProxyRepresentation(exporting: \.url)
    }
}

extension UTType {
    /// The Collector's private drag payload type, exported in
    /// `OpenDisk-Info.plist` and conforming to `public.json`.
    ///
    /// It must not be `public.json` itself. The Collector's drop target
    /// decodes whatever payload it receives into a list of paths to delete,
    /// and `public.json` is a system-wide type that every `.json` file on the
    /// machine advertises — so any dragged file, from Finder or another app,
    /// could decode straight into deletion candidates with an attacker-chosen
    /// `path`. See SECURITY-REVIEW.md, finding H4.
    static let openDiskCollectedFiles = UTType(
        exportedAs: "ideals.OpenDisk.collected-files", conformingTo: .json
    )
}

/// One drag's worth of files: a multi-selection dragged together rides as
/// a single payload (SwiftUI's `.draggable` carries one Transferable per
/// row, so a group type is how several files travel in one gesture).
struct CollectedFileGroup: Codable, Transferable, Sendable {
    let files: [CollectedFile]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .openDiskCollectedFiles)
    }
}
