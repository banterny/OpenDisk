import AppKit
import SwiftUI

/// Root window: a Finder-style sidebar of scannable locations beside the
/// analysis of whichever one is selected. It replaced the separate
/// disk-picker screen (and the Unmount button that led back to it):
/// switching location is now one click in the sidebar.
/// (Ported from upstream 3a6951d.)
///
/// It adapts to the distribution build:
///   • Website (non-sandboxed): mounted volumes, plus folders added with
///     "Scan Folder…", remembered as plain paths in UserDefaults.
///   • App Store (sandboxed): the same volumes, opened through a
///     security-scoped grant the first time, plus any other folders the
///     user has granted (kept as bookmarks by `ScanAccess`).
///
/// Nothing here deletes anything. "Remove from Sidebar" forgets a saved
/// path or bookmark; the folder itself is untouched.
struct ContentView: View {
    @State private var deviceMonitor = DeviceMonitor()
    @State private var scanAccess = ScanAccess()
    /// Folders added with "Scan Folder…" in the website build,
    /// newline-separated.
    @AppStorage("sidebar_folders") private var storedFolders = ""
    /// The sidebar row the user picked (a path).
    @State private var selection: String?
    /// The location being analysed. Lags `selection` while a sandboxed
    /// build waits on the grant panel, and snaps back if it is cancelled.
    @State private var active: DeviceInfo?
    @State private var isChoosingFolder = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LocationsSidebar(
                devices: deviceMonitor.devices,
                folders: folderLocations,
                selection: $selection,
                onAddFolder: addFolder,
                onRemoveFolder: removeFolder
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            if let active {
                DiskAnalysisView(
                    rootPath: active.path,
                    rootName: active.name,
                    totalUsedSpace: active.usedBytes,
                    // A finished scan hands the window over to its results;
                    // the sidebar is one toolbar click away. (Ported from
                    // upstream d2958b7.)
                    onScanFinished: {
                        withAnimation { columnVisibility = .detailOnly }
                    }
                )
                // A fresh analysis view (and scan) per location, rather
                // than one view re-pointed at a new root.
                .id(active.path)
            } else {
                placeholder
            }
        }
        .frame(
            minWidth: 980, idealWidth: 1280, maxWidth: .infinity,
            minHeight: 600, idealHeight: 800, maxHeight: .infinity
        )
        // Website build only: the sandboxed build asks through
        // `ScanAccess.requestGrant`, which stores a bookmark. (Ported from
        // upstream dc6e1c8, which replaced a hand-run NSOpenPanel.)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { addFolder(at: url) }
        }
        .fileDialogConfirmationLabel("Scan")
        .fileDialogMessage("Choose a folder to analyze")
        // Deferred a tick: opening may run the grant panel's modal loop,
        // which must not happen inside a view update.
        .onChange(of: selection) { _, path in
            Task { @MainActor in open(path) }
        }
        // Reachable by the sidebar (grants, padlocks) and the analysis view
        // (security-scoped access held for the length of a scan).
        .environment(scanAccess)
    }

    /// Shown until a location is picked. Launch selects nothing, so this is
    /// the first thing a user sees; it says what to do and offers the folder
    /// chooser. (3a6951d's version; upstream later cut it to a bare "No
    /// Location Selected" once launch auto-selected a disk, which the fork
    /// does only on request — see Settings.)
    private var placeholder: some View {
        ContentUnavailableView {
            Label(
                ScanAccess.isSandboxed ? "Choose What to Scan" : "Select a Disk",
                systemImage: "internaldrive"
            )
        } description: {
            Text(ScanAccess.isSandboxed
                ? "Choose a disk in the sidebar, or any folder. OpenDisk asks for access once and remembers it."
                : "Choose a disk or folder in the sidebar to see what’s taking up space.")
        } actions: {
            Button(ScanAccess.isSandboxed ? "Choose a Folder…" : "Scan Folder…", action: addFolder)
        }
        .navigationTitle("OpenDisk")
    }

    private var savedFolderPaths: [String] {
        storedFolders.split(separator: "\n").map(String.init)
    }

    /// The sidebar's Folders section: anything added that is not itself
    /// one of the listed disks. A saved folder that no longer exists (a
    /// disconnected drive, a deleted folder) is hidden rather than shown
    /// as a dead row; it reappears when the path does.
    private var folderLocations: [DeviceInfo] {
        let devicePaths = Set(deviceMonitor.devices.map(\.path))
        if ScanAccess.isSandboxed {
            return scanAccess.grants
                .filter { !devicePaths.contains($0.path) }
                .map { folder(path: $0.path, name: $0.name) }
        }
        return savedFolderPaths
            .filter { !devicePaths.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .map { folder(path: $0, name: nil) }
    }

    /// A folder as a location. Zero capacity hides the sidebar gauge and
    /// the analysis view's progress fraction (a folder's share of its
    /// volume is not known in advance).
    private func folder(path: String, name: String?) -> DeviceInfo {
        let last = (path as NSString).lastPathComponent
        return DeviceInfo(
            name: name ?? (last.isEmpty ? path : last),
            icon: "folder",
            path: path,
            totalBytes: 0,
            availableBytes: 0
        )
    }

    /// Makes `path` the analysed location. A sandboxed build opening a disk
    /// it has no grant for asks first; whatever the user actually grants is
    /// what gets scanned, and a cancelled panel puts the selection back.
    private func open(_ path: String?) {
        guard let path else {
            active = nil
            return
        }
        guard path != active?.path else { return }

        if let device = deviceMonitor.devices.first(where: { $0.path == path }) {
            guard ScanAccess.isSandboxed, !scanAccess.isGranted(device.path) else {
                active = device
                return
            }
            guard let opened = requestAccess(to: device) else {
                selection = active?.path
                return
            }
            active = opened
            if opened.path != path { selection = opened.path }
            return
        }

        if let folder = folderLocations.first(where: { $0.path == path }) {
            active = folder
        }
    }

    /// The grant panel for a disk shortcut, opened next to it and naming
    /// it. The boot volume ("/") isn't a selectable item at its own level
    /// and the panel's sidebar shows its real name (not "Computer"), so it
    /// gets the generic "pick your startup disk" guidance instead.
    /// External volumes are selectable from their parent (/Volumes).
    private func requestAccess(to device: DeviceInfo) -> DeviceInfo? {
        let isBootVolume = device.path == "/"
        let start = isBootVolume
            ? URL(fileURLWithPath: "/")
            : URL(fileURLWithPath: device.path).deletingLastPathComponent()
        guard let grant = scanAccess.requestGrant(
            startingAt: start,
            suggestedName: isBootVolume ? nil : device.name
        ) else { return nil }
        let matched = grant.path == device.path
        return DeviceInfo(
            name: grant.name, icon: device.icon, path: grant.path,
            totalBytes: matched ? device.totalBytes : 0,
            availableBytes: matched ? device.availableBytes : 0
        )
    }

    private func addFolder() {
        if ScanAccess.isSandboxed {
            guard let grant = scanAccess.requestGrant() else { return }
            selection = grant.path
            return
        }

        isChoosingFolder = true
    }

    /// Website build: remembers the chosen folder (unless it is a disk
    /// already listed) and opens it. No bookmark is needed; the app can
    /// read the path directly.
    private func addFolder(at url: URL) {
        let path = url.path
        if !deviceMonitor.devices.contains(where: { $0.path == path }),
           !savedFolderPaths.contains(path) {
            storedFolders = (savedFolderPaths + [path]).joined(separator: "\n")
        }
        selection = path
    }

    /// Forgets a folder: its saved path, or in the sandboxed build its
    /// bookmark (which also ends any security-scoped access to it; the
    /// analysis view's own `endAccess` on disappearing is then a no-op).
    /// Nothing on disk is touched.
    private func removeFolder(_ folder: DeviceInfo) {
        let wasSelected = selection == folder.path
        if ScanAccess.isSandboxed {
            if let grant = scanAccess.grants.first(where: { $0.path == folder.path }) {
                scanAccess.removeGrant(grant)
            }
        } else {
            storedFolders = savedFolderPaths.filter { $0 != folder.path }.joined(separator: "\n")
        }
        if wasSelected { selection = nil }
    }
}

#Preview {
    ContentView()
}
