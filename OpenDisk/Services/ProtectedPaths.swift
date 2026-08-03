import Foundation
import Synchronization

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
        let resolved = canonical(path)

        // "Is this on one of the volume group's helper volumes?" is the one
        // rule that must be asked of the *resolved* path only, never of the
        // literal one. Every ordinary file on the startup disk is reachable at
        // /System/Volumes/Data/... — that is the whole point of the firmlink —
        // and a scan rooted at the Data volume (which is exactly what the
        // sandboxed build's open panel returns when the user picks
        // "Macintosh HD — Data") produces rows that all wear that prefix.
        // Asking this of the literal path refused every deletion in that scan.
        //
        // A real file's Data-volume path resolves away to its normal name, so
        // anything still under /System/Volumes/ after resolution genuinely
        // lives on Preboot, VM, Update, Recovery, xarts or iSCPreboot.
        if resolved == dataVolumePrefix {
            return "is a macOS system volume and can't be deleted"
        }
        if resolved.hasPrefix("/System/Volumes/"),
           !resolved.hasPrefix(dataVolumePrefix + "/") {
            return "is on a macOS system volume and can't be deleted"
        }

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

        // (The "inside a helper system volume" rule lives in `reason(for:)`:
        // it must see the resolved path only. See the comment there.)

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
    ///
    /// Memoised, because resolution touches the filesystem (`realpath`) and
    /// this is no longer only an enforcement-time call. `FileActionsMenu` and
    /// `FolderRowView` ask `isProtected` while building each row's context
    /// menu, so an unmemoised version would cost one `realpath` per visible
    /// row per render pass — in the app whose whole pitch is scan speed.
    private static func canonical(_ path: String) -> String {
        let key = normalized(path)
        if let hit = cache.withLock({ $0.entries[key] }) { return hit }
        let resolved = normalized((key as NSString).resolvingSymlinksInPath)
        cache.withLock { state in
            // Paths churn as the user navigates; a full flush at the cap keeps
            // this a fixed-cost cache with no eviction bookkeeping.
            if state.entries.count >= maxCachedPaths { state.entries.removeAll(keepingCapacity: true) }
            state.entries[key] = resolved
        }
        return resolved
    }

    private static let maxCachedPaths = 4_096
    private struct ResolutionCache { var entries: [String: String] = [:] }
    private static let cache = Mutex(ResolutionCache())

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
