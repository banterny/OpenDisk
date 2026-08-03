import Foundation

/// Guards against collecting macOS-critical locations for deletion — the disk
/// root, system folders, whole user accounts, `~/Library`, and mounted-volume
/// roots. Deleting any of these would break the system or wipe an account, so
/// the Collector refuses them (mirroring DaisyDisk's protection).
///
/// Every check runs against *canonical* paths (see `canonicalForms`). String
/// comparison alone is not enough on macOS: the same directory is reachable
/// under several names, and a guard that only knows one of them is not a
/// guard. See SECURITY-REVIEW.md, findings C2 and H3.
enum ProtectedPaths {
    /// Absolute directories that must never be deleted.
    private static let systemRoots: Set<String> = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
        "/home", "/net", "/.vol",
    ]

    /// Mount point of the boot volume group's Data volume. Every file on the
    /// startup disk is reachable both at its normal path and beneath this
    /// prefix, because macOS firmlinks the two namespaces together.
    private static let dataVolumePrefix = "/System/Volumes/Data"

    /// A human-readable reason if `path` is protected, otherwise `nil`.
    /// The message is phrased to follow the item's name, e.g.
    /// `"System" ` + `"is a macOS system folder…"`.
    ///
    /// Every canonical form of the path is checked and any one matching is
    /// enough — erring towards refusing, which is the correct direction for a
    /// guard in front of permanent deletion.
    static func reason(for path: String) -> String? {
        for candidate in canonicalForms(of: path) {
            if let reason = directReason(for: candidate) { return reason }
        }
        return nil
    }

    static func isProtected(_ path: String) -> Bool { reason(for: path) != nil }

    // MARK: - The rules

    private static func directReason(for p: String) -> String? {
        if p == "/" { return "is the disk root and can't be deleted" }
        if systemRoots.contains(p) { return "is a macOS system folder and can't be deleted" }

        // The *real* home — in the sandboxed build NSHomeDirectory() is the
        // app container, which would leave the actual ~/Library unprotected.
        let home = canonical(UserHome.path)
        if p == home { return "is your home folder and can't be deleted" }
        if p == home + "/Library" { return "is your Library and can't be deleted" }

        // A home root directly under /Users (e.g. /Users/alice, /Users/Shared).
        switch parent(of: p) {
        case "/Users":          return "is a user account folder and can't be deleted"
        case "/Volumes":        return "is a mounted volume and can't be deleted"
        case "/System/Volumes": return "is a macOS system volume and can't be deleted"
        default: break
        }

        // Anything *inside* one of the volume group's helper volumes —
        // Preboot, VM, Update, Recovery, iSCPreboot, xarts, Hardware.
        // ScanEngine.scanBootVolumeGroup deliberately scans and displays their
        // contents, and deleting e.g. /System/Volumes/Preboot/<UUID> leaves the
        // Mac unbootable. Protecting only the volume roots (their parent is
        // /System/Volumes, which the switch above catches) left every byte
        // beneath them collectible.
        //
        // A path still wearing the /System/Volumes/Data prefix at this point
        // did not resolve to its firmlinked twin — it no longer exists — so
        // treat it as system-owned rather than guessing.
        if p == dataVolumePrefix || p.hasPrefix("/System/Volumes/") {
            return "is on a macOS system volume and can't be deleted"
        }

        // Any ancestor of a protected location is at least as dangerous.
        for root in systemRoots where root.hasPrefix(p + "/") {
            return "contains macOS system files and can't be deleted"
        }
        if home.hasPrefix(p + "/") { return "contains your home folder and can't be deleted" }

        return nil
    }

    // MARK: - Canonicalisation

    /// The forms of `path` that must all be checked: the literal normalised
    /// path, its symlink/firmlink-resolved form, and — for a path that does
    /// not exist and so cannot be resolved — the same path with an explicit
    /// `/System/Volumes/Data` prefix stripped.
    ///
    /// Why more than one form is needed:
    ///  • `resolvingSymlinksInPath` returns the input unchanged for a path
    ///    that isn't on disk, so it cannot be relied on alone.
    ///  • It resolves a symlink *itself* to its target, so a symlink named
    ///    like a protected path would otherwise slip past the literal check.
    ///  • Firmlinks (`/System/Volumes/Data/Users/x` ≡ `/Users/x`, same inode)
    ///    are collapsed by resolution but are invisible to `standardizingPath`.
    private static func canonicalForms(of path: String) -> Set<String> {
        var forms: Set<String> = [normalized(path), canonical(path)]
        for form in forms where form.hasPrefix(dataVolumePrefix + "/") {
            forms.insert(normalized(String(form.dropFirst(dataVolumePrefix.count))))
        }
        return forms
    }

    /// Fully resolved: symlinks and firmlinks collapsed, `..` removed,
    /// trailing slashes stripped.
    private static func canonical(_ path: String) -> String {
        normalized((normalized(path) as NSString).resolvingSymlinksInPath)
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
