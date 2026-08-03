import Foundation
import UniformTypeIdentifiers
import Testing
@testable import OpenDisk

/// Contract tests for the pure guard that decides which paths may never be
/// permanently deleted. These test the documented intent — the *real* current
/// user's home is protected — rather than any particular home-lookup API
/// (in a non-sandboxed test runner `NSHomeDirectory()` and `getpwuid` agree).
@Suite("ProtectedPaths")
struct ProtectedPathsTests {

    /// The real current user's home, standardized the same way the guard
    /// normalizes its input.
    private var home: String {
        var h = (NSHomeDirectory() as NSString).standardizingPath
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        return h
    }

    // MARK: - Disk root and system folders

    @Test("the disk root is protected")
    func diskRoot() {
        #expect(ProtectedPaths.reason(for: "/") == "is the disk root and can't be deleted")
        // Extra slashes standardize down to the root.
        #expect(ProtectedPaths.reason(for: "///") == "is the disk root and can't be deleted")
    }

    @Test("macOS system folders are protected", arguments: [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
    ])
    func systemFolders(path: String) {
        #expect(ProtectedPaths.reason(for: path) == "is a macOS system folder and can't be deleted")
        #expect(ProtectedPaths.isProtected(path))
    }

    // MARK: - /Users and its direct children

    @Test("direct children of /Users are user account folders", arguments: [
        "/Users/alice", "/Users/somebody-else", "/Users/Shared",
    ])
    func userAccountRoots(path: String) {
        #expect(ProtectedPaths.reason(for: path) == "is a user account folder and can't be deleted")
    }

    @Test("deep paths inside another user's account are not protected")
    func otherUsersDeepPaths() {
        #expect(ProtectedPaths.reason(for: "/Users/alice/Downloads") == nil)
        #expect(ProtectedPaths.reason(for: "/Users/Shared/Movies/big.mov") == nil)
    }

    // MARK: - The current user's home

    @Test("the real user home is protected")
    func homeProtected() {
        #expect(ProtectedPaths.reason(for: home) == "is your home folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: home + "/") == "is your home folder and can't be deleted")
    }

    @Test("the user's ~/Library is protected")
    func homeLibraryProtected() {
        #expect(ProtectedPaths.reason(for: home + "/Library") == "is your Library and can't be deleted")
        #expect(ProtectedPaths.reason(for: home + "/Library/") == "is your Library and can't be deleted")
    }

    @Test("tilde inputs expand to the home folder")
    func tildeExpansion() {
        #expect(ProtectedPaths.reason(for: "~") == "is your home folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: "~/Library") == "is your Library and can't be deleted")
    }

    @Test("every ancestor of the home folder is protected")
    func homeAncestorsProtected() {
        var ancestor = (home as NSString).deletingLastPathComponent
        while ancestor.count > 1 {
            #expect(ProtectedPaths.isProtected(ancestor), "\(ancestor) should be protected")
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        #expect(ProtectedPaths.isProtected("/"))
    }

    @Test("ordinary folders inside the home are not protected")
    func homeChildrenNotProtected() {
        #expect(ProtectedPaths.reason(for: home + "/Downloads") == nil)
        #expect(ProtectedPaths.reason(for: home + "/Downloads/foo") == nil)
        #expect(ProtectedPaths.reason(for: home + "/Documents/report.pdf") == nil)
        // Only ~/Library itself is guarded, not everything inside it.
        #expect(ProtectedPaths.reason(for: home + "/Library/Caches") == nil)
    }

    // MARK: - Volumes

    @Test("mounted volume roots are protected")
    func volumeRoots() {
        #expect(ProtectedPaths.reason(for: "/Volumes/External") == "is a mounted volume and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/Volumes/External SSD") == "is a mounted volume and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/System/Volumes/Data") == "is a macOS system volume and can't be deleted")
    }

    @Test("contents of an external volume are not protected")
    func volumeContentsNotProtected() {
        #expect(ProtectedPaths.reason(for: "/Volumes/External/Movies") == nil)
        #expect(ProtectedPaths.reason(for: "/Volumes/External SSD/backups/2025.dmg") == nil)
    }

    // MARK: - Normalization of messy inputs

    @Test("trailing slashes do not bypass protection", arguments: [
        "/System/", "/System///", "/usr/", "/Users/alice/",
    ])
    func trailingSlashes(path: String) {
        #expect(ProtectedPaths.isProtected(path))
    }

    @Test("non-standardized paths are standardized before matching")
    func standardization() {
        // ".." and "." components collapse to the protected target.
        #expect(ProtectedPaths.reason(for: "/System/../System") == "is a macOS system folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/usr/./local/..") == "is a macOS system folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/Users//Shared") == "is a user account folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: home + "/Downloads/..") == "is your home folder and can't be deleted")
        // The "/private" prefix standardizes away (e.g. /private/tmp -> /tmp).
        #expect(ProtectedPaths.reason(for: "/private/tmp") == "is a macOS system folder and can't be deleted")
    }

    @Test("deep unrelated paths are not protected")
    func deepPathsNotProtected() {
        #expect(ProtectedPaths.reason(for: "/usr/local/bin/tool") == nil)
        #expect(ProtectedPaths.reason(for: "/Applications/SomeApp.app") == nil)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectedPathsTests-\(UUID().uuidString)").path
        #expect(ProtectedPaths.reason(for: tmp) == nil)
    }

    // MARK: - Canonicalisation bypasses (SECURITY-REVIEW.md C2 / H3)

    /// Every file on the startup disk is reachable twice: at its normal path
    /// and beneath the Data volume's firmlink. Both name the same inode, so a
    /// guard that only knows the first name is not a guard.
    @Test("the Data-volume firmlink cannot be used to reach protected paths")
    func firmlinkBypass() {
        let data = "/System/Volumes/Data"
        // Precondition: the firmlink really is an alias for the same directory
        // on this machine, otherwise the test proves nothing.
        func identity(_ path: String) -> String? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return "\(info.st_dev):\(info.st_ino)"
        }
        try? #require(identity(home) != nil)
        #expect(identity(data + home) == identity(home))

        #expect(ProtectedPaths.reason(for: data + home) != nil)
        #expect(ProtectedPaths.reason(for: data + home + "/Library") != nil)
        #expect(ProtectedPaths.reason(for: data + "/Users") != nil)
        #expect(ProtectedPaths.reason(for: data + "/Applications") != nil)
        #expect(ProtectedPaths.reason(for: data + "/Library") != nil)
        #expect(ProtectedPaths.reason(for: data) != nil)
    }

    /// The helper volumes of the boot volume group are scanned and displayed
    /// by ScanEngine.scanBootVolumeGroup, so their contents reach the
    /// Collector. Deleting inside Preboot leaves the Mac unbootable.
    @Test("contents of system volumes are protected, not just their roots")
    func systemVolumeContents() {
        #expect(ProtectedPaths.reason(for: "/System/Volumes/Preboot") != nil)
        #expect(ProtectedPaths.reason(for: "/System/Volumes/Preboot/ABC-123") != nil)
        #expect(ProtectedPaths.reason(for: "/System/Volumes/VM/sleepimage") != nil)
        #expect(ProtectedPaths.reason(for: "/System/Volumes/Update/mnt1") != nil)
    }

    /// A symlink pointing at a protected location resolves to it. Refusing
    /// the link as well is the safe direction: at worst the user cannot
    /// collect a symlink, which frees no space anyway.
    @Test("a symlink to a protected location is refused")
    func symlinkToProtected() throws {
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("protected-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: home)
        )
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(ProtectedPaths.reason(for: link.path) != nil)
    }

    /// Canonicalisation must not start refusing ordinary files.
    /// A scan rooted at the Data volume (Finder and Disk Utility both offer
    /// "Macintosh HD — Data", and the sandboxed build's open panel will hand
    /// back exactly that) produces rows whose paths keep the prefix. Those are
    /// ordinary user files and must stay deletable.
    @Test("Data-prefixed ordinary files are still deletable")
    func dataPrefixedOrdinaryFilesAllowed() {
        let data = "/System/Volumes/Data"
        #expect(ProtectedPaths.reason(for: data + home + "/Downloads") == nil)
        #expect(ProtectedPaths.reason(for: data + home + "/Downloads/thing.zip") == nil)
        #expect(ProtectedPaths.reason(for: data + home + "/Library/Caches/Homebrew") == nil)
        #expect(ProtectedPaths.reason(for: data + "/Library/Caches") == nil)
    }

    @Test("canonicalisation does not over-block ordinary paths")
    func noOverBlocking() {
        #expect(ProtectedPaths.reason(for: home + "/Downloads/thing.zip") == nil)
        #expect(ProtectedPaths.reason(for: home + "/Library/Caches/Homebrew") == nil)
        #expect(ProtectedPaths.reason(for: "/Library/Caches") == nil)
        #expect(ProtectedPaths.reason(for: "/Volumes/External/Backups") == nil)
    }
}

/// The test runner is not sandboxed, so the detection must say so — including
/// when the misleading environment variable is absent, which is the case here.
/// See SECURITY-REVIEW.md, finding M5.
@Suite("ScanAccess")
struct ScanAccessTests {

    @Test("sandbox detection reports false in a non-sandboxed process")
    func notSandboxedInTestRunner() {
        #expect(ScanAccess.isSandboxed == false)
        // And the signal it now leads with is not the environment variable.
        #expect(NSHomeDirectory() == UserHome.path)
    }
}

/// The Collector's drag payload must use the app-private exported type, not
/// `public.json`. `UTType(exportedAs:)` traps if the declaration is missing
/// from Info.plist, so merely resolving it here proves the declaration ships.
/// See SECURITY-REVIEW.md, finding H4.
@Suite("Collector drag type")
struct CollectedFileTransferTypeTests {

    @Test("the drag payload uses a private type that conforms to JSON")
    func privateDragType() {
        let type = UTType.openDiskCollectedFiles
        #expect(type.identifier == "ideals.OpenDisk.collected-files")
        #expect(type != .json)
        #expect(type.conforms(to: .json))
        // The whole point: a plain .json file must not satisfy this type.
        #expect(!UTType.json.conforms(to: type))
    }
}
