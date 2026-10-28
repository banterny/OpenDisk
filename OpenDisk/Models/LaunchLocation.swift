import Foundation

/// The opt-in "Scan a disk when OpenDisk opens" setting (Settings ▸
/// Launch) and the rule for which location it opens.
///
/// Upstream d7faff5 does this unconditionally: every launch selects a
/// location and starts a scan, usually of the whole startup disk. The fork
/// makes it a setting, **off by default**, so that with it off a launch
/// reads nothing until the user picks a location — as before the redesign.
/// With it off, nothing new is stored either: the last location is only
/// remembered while the setting is on.
enum LaunchLocation {
    static let defaultsKey = "scan_at_launch"
    /// The location last opened, while the setting is on.
    static let lastLocationKey = "last_location"
    /// One source for the default, shared by the Settings toggle's
    /// `@AppStorage` and `isEnabled(in:)`.
    static let defaultValue = false

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? defaultValue
    }

    /// The path to open at launch, or nil for none: the last location if it
    /// is still listed and not on an external volume, otherwise the startup
    /// disk. `canOpen` rules out anything that would need an access prompt
    /// first (the sandboxed build's ungranted disks) — a launch never opens
    /// a panel on its own. (Upstream d7faff5's rule.)
    static func choose(
        from locations: [DeviceInfo],
        last: String,
        canOpen: (DeviceInfo) -> Bool
    ) -> String? {
        if let previous = locations.first(where: { $0.path == last }),
           isInternal(previous.path), canOpen(previous) {
            return previous.path
        }
        if let computer = locations.first(where: { $0.path == "/" }), canOpen(computer) {
            return computer.path
        }
        return nil
    }

    /// External volumes are left alone at launch: one may be slow, busy, or
    /// simply not the disk the user came to look at.
    private static func isInternal(_ path: String) -> Bool {
        path != "/Volumes" && !path.hasPrefix("/Volumes/")
    }
}
