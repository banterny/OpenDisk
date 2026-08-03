import SwiftUI

@main
struct OpenDiskApp: App {
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true
    @State private var hasCheckedFullDiskAccess = false

    // No in-app updater by design. Upstream shipped Sparkle pointed at
    // opendisk.app with upstream's signing key, which meant a reviewed build
    // would quietly replace itself with an unreviewed one. This fork updates
    // by `git pull` and a rebuild, so the running binary is always the source
    // you have read. See SECURITY-REVIEW.md, finding C1.

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear(perform: checkFullDiskAccessAtStartup)
        }
        .windowToolbarStyle(.unified)
        // The window tracks each screen's content size: compact around the
        // disk picker, expanding when the analysis screen is pushed.
        .windowResizability(.contentSize)
        .commands {
            ToolbarCommands()
        }

        Settings {
            SettingsView()
        }
    }

    private func checkFullDiskAccessAtStartup() {
        // The sandboxed App Store build never uses Full Disk Access — it scans
        // folders/volumes the user grants — so there's nothing to prompt for.
        guard !ScanAccess.isSandboxed else { return }
        guard !hasCheckedFullDiskAccess else { return }
        hasCheckedFullDiskAccess = true

        // Slightly delayed so the window is on screen before the alert.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard showPromptAtStartup else { return }
            FullDiskAccess.promptIfNotGranted(
                title: "Full Disk Access Required",
                message: "OpenDisk needs Full Disk Access to analyze all files and folders on your system. You can grant this permission in System Settings > Privacy & Security > Full Disk Access."
            )
        }
    }
}
