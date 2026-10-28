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
        // The content sets a minimum size only; the user sizes the window
        // freely above it. (`.contentSize` suited the old compact disk
        // picker, which the window shrank to fit. Upstream 3a6951d.)
        .windowResizability(.contentMinSize)
        .commands {
            ToolbarCommands()
            TextSizeCommands()
        }

        Settings {
            SettingsView()
        }
    }

    private func checkFullDiskAccessAtStartup() {
        // The sandboxed App Store build never uses Full Disk Access — it scans
        // folders/volumes the user grants — so there's nothing to prompt for.
        guard !ScanAccess.isSandboxed else { return }
        // Hosting the test bundle: the alert's modal loop would stall every
        // main-actor test until someone dismissed it.
        guard !FullDiskAccess.isHostingTests() else { return }
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

/// View ▸ Make Text Bigger / Make Text Smaller / Actual Size for the file
/// list, as in Finder. The level is clamped by `ListScale`, so a stale or
/// hand-edited preference can only pick a size from the list.
/// (Ported from upstream 3a6951d.)
private struct TextSizeCommands: Commands {
    @AppStorage(ListScale.defaultsKey) private var level = ListScale.defaultLevel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Make Text Bigger") { level = ListScale(level: level + 1).level }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(level >= ListScale.fontSizes.count - 1)
            Button("Make Text Smaller") { level = ListScale(level: level - 1).level }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(level <= 0)
            Button("Actual Size") { level = ListScale.defaultLevel }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(level == ListScale.defaultLevel)
        }
    }
}
