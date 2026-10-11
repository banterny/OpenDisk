import Foundation

/// Naming for the synthetic "Purgeable Space" cleanup lens shown in the
/// list and chart.
enum HiddenSpaceInfo {
    /// Display name of the synthetic top-level folder.
    static let folderName = "Purgeable Space"
    /// Row identity for the synthetic folder. The "::" prefix marks paths
    /// that do not exist on disk; Finder actions skip them, and
    /// `DiskAnalyzer` resolves navigation into them specially.
    static var sentinelPath: String { "::" + folderName }
}

/// Naming for the synthetic "Free Space" wedge on the chart: the unused
/// part of the volume, drawn beside the scanned folders so the ring reads as
/// the whole disk rather than only what is on it. (Upstream issue #11;
/// ported from upstream ccc37cd and 80e91c7.)
///
/// Like every "::" path it names nothing on disk. The chart treats it as a
/// `.synthetic` segment, which is what keeps it from being dragged, opened,
/// or offered a file menu.
enum FreeSpaceInfo {
    static let name = "Free Space"
    static var sentinelPath: String { "::" + name }
    /// Settings toggle. On by default; worth turning off on a large,
    /// mostly empty drive, where the wedge would squeeze every scanned
    /// folder into a sliver.
    static let defaultsKey = "chart_show_free_space"
}

/// Curated cache locations that are safe to clear: caches that macOS or
/// the owning tool rebuilds (or re-downloads) on demand. Shown inside the
/// synthetic "Purgeable Space" folder with their scanned sizes.
///
/// Deliberately conservative — no application-support data, no browser
/// profiles, nothing whose loss changes user-visible state beyond a slower
/// next launch.
enum CleanableCacheCatalog {

    struct Location {
        let name: String
        let path: String
    }

    /// Candidate locations; callers keep only the ones present in the
    /// scanned tree with nonzero size. Entries are disjoint on disk so no
    /// bytes are listed twice within this view.
    static var locations: [Location] {
        // The *real* home — in the sandboxed build NSHomeDirectory() is the
        // app container, where none of these caches live.
        let home = UserHome.path
        return [
            // Package / build tool caches (rebuilt or re-downloaded on demand).
            Location(name: "Homebrew Cache", path: home + "/Library/Caches/Homebrew"),
            Location(name: "npm Cache", path: home + "/.npm/_cacache"),
            Location(name: "Yarn Cache", path: home + "/Library/Caches/Yarn"),
            Location(name: "pnpm Store", path: home + "/Library/pnpm/store"),
            Location(name: "pip Cache", path: home + "/Library/Caches/pip"),
            Location(name: "Cargo Registry Cache", path: home + "/.cargo/registry/cache"),
            Location(name: "Go Build Cache", path: home + "/Library/Caches/go-build"),
            Location(name: "Go Module Cache", path: home + "/go/pkg/mod/cache"),
            Location(name: "Gradle Cache", path: home + "/.gradle/caches"),
            Location(name: "CocoaPods Cache", path: home + "/Library/Caches/CocoaPods"),
            Location(name: "Composer Cache", path: home + "/.composer/cache"),
            // Developer tooling.
            Location(name: "Xcode DerivedData", path: home + "/Library/Developer/Xcode/DerivedData"),
            Location(name: "Xcode iOS DeviceSupport", path: home + "/Library/Developer/Xcode/iOS DeviceSupport"),
            // NOT listed: ~/Library/Developer/Xcode/Archives. Archives hold the
            // dSYMs for every build you have shipped; without them you cannot
            // symbolicate crash reports from released versions, and they cannot
            // be regenerated. That is user data, not a cache, and it breaks this
            // catalogue's stated rule above. See SECURITY-REVIEW.md, finding H2.
            Location(name: "Playwright Browsers", path: home + "/.cache/ms-playwright"),
            Location(name: "Puppeteer Browsers", path: home + "/.cache/puppeteer"),
            // App / ML / browser caches.
            Location(name: "Chrome Cache", path: home + "/Library/Caches/Google/Chrome"),
            Location(name: "Safari Cache", path: home + "/Library/Caches/com.apple.Safari"),
            Location(name: "Hugging Face Cache", path: home + "/.cache/huggingface"),
            Location(name: "PyTorch Hub Cache", path: home + "/.cache/torch"),
            // General.
            Location(name: "User Logs", path: home + "/Library/Logs"),
            Location(name: "Trash", path: home + "/.Trash"),
            Location(name: "System Caches", path: "/Library/Caches"),
        ]
    }
}
