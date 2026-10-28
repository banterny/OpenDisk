import AppKit
import Foundation
import OSLog

/// Full Disk Access helpers: probe, prompt, and a jump to System Settings.
///
/// Derived from the open-source `FullDiskAccess` helper by Mahdi Bchatnia
/// (github.com/inket/FullDiskAccess, MIT), trimmed to the API this app
/// uses and to its deployment target.
enum FullDiskAccess {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenDisk",
        category: "FullDiskAccess"
    )

    /// Whether Full Disk Access is currently granted.
    ///
    /// Probes several TCC-protected locations that require FDA to read (and
    /// reading them also registers the app in the FDA list of System Settings).
    /// *Every* probe that exists must be readable; a path that isn't present
    /// on this Mac is skipped rather than counted as a denial. (A
    /// world-readable path like `/Library/Application Support` must NOT be
    /// used — it succeeds without FDA.)
    ///
    /// This used to stop at the first probe that existed. That trusts a
    /// single location, and a location can become readable by a narrower
    /// grant than FDA — another app's container, for one, sits behind the
    /// separate "access data from other apps" permission — which reported FDA
    /// as granted when it was not, so the prompt never appeared and scans
    /// silently skipped everything still protected. Requiring agreement
    /// across all of them, plus one system-domain file outside the home
    /// folder, fails closed instead. (Ported from upstream 228e962, "fix full
    /// disk access for macos27". Upstream does not record which probe
    /// misbehaved; the explanation above is the likeliest reading, not a
    /// confirmed one.)
    static var isGranted: Bool {
        let home = NSHomeDirectory()
        let directories = [
            home + "/Library/Containers/com.apple.stocks",
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
        ]
        let files = [
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]

        var probed = 0
        var readable = 0
        for path in directories where FileManager.default.fileExists(atPath: path) {
            probed += 1
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                readable += 1
            } else {
                log.debug("Full Disk Access probe failed (cannot list \(path))")
            }
        }
        for path in files where FileManager.default.fileExists(atPath: path) {
            probed += 1
            if let handle = FileHandle(forReadingAtPath: path) {
                readable += 1
                try? handle.close()
            } else {
                log.debug("Full Disk Access probe failed (cannot open \(path))")
            }
        }
        return probed > 0 && readable == probed
    }

    /// Whether this process is only hosting the unit-test bundle.
    ///
    /// The test host is the app itself, and the startup alert's modal loop
    /// blocks the main actor: with the alert up, every main-actor test waits
    /// until someone clicks "Later". Xcode sets `XCTestConfigurationFilePath`
    /// in the host's environment for every test run (pinned by
    /// `FullDiskAccessTests`).
    ///
    /// An environment variable is something whoever launches the app
    /// controls (compare M5), so this gates nothing that matters: setting
    /// it only hides a reminder. Scans still check `isGranted` and still
    /// show the "Full Disk Access Required" screen.
    nonisolated static func isHostingTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// Relaunches the app — Full Disk Access only reaches a *freshly launched*
    /// process, so after the user turns it on we offer to quit and reopen.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Opens System Settings on Privacy & Security > Full Disk Access.
    static func openSystemSettings() {
        // Probing is what adds the app to the Full Disk Access list, so do
        // it before the pane opens — otherwise a user arriving from the
        // Settings window finds no OpenDisk row to switch on.
        _ = isGranted
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Shows a one-time alert offering to open System Settings when Full
    /// Disk Access is missing. Honors the user's "do not ask again" choice.
    /// Main-actor isolated: it builds and runs an `NSAlert` and reads `NSApp`.
    @MainActor
    static func promptIfNotGranted(title: String, message: String) {
        guard !promptSuppressed, !isGranted else { return }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.icon = NSApp.applicationIconImage
        alert.showsSuppressionButton = true
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            promptSuppressed = true
        }
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    /// Undoes a "do not ask again" choice.
    static func resetPromptSuppression() {
        promptSuppressed = false
    }

    private static var promptSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: "fda_suppressed") }
        set { UserDefaults.standard.set(newValue, forKey: "fda_suppressed") }
    }
}
