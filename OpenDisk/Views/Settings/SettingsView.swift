import SwiftUI

struct SettingsView: View {
    @State private var isFullDiskAccessGranted = false
    @State private var isCheckingAccess = false
    @AppStorage("fda_show_prompt_at_startup") private var showPromptAtStartup = true
    @AppStorage(FreeSpaceInfo.defaultsKey) private var showFreeSpace = true
    @AppStorage("delete_permanently") private var deletePermanently = false
    @AppStorage(LaunchLocation.defaultsKey) private var scanAtLaunch = LaunchLocation.defaultValue
    @State private var keyBindings = KeyBindingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $deletePermanently) {
                    VStack(alignment: .leading) {
                        Text("Delete permanently instead of moving to the Trash")

                        Text(deletePermanently
                            ? "Collected items are unlinked immediately. Space is reclaimed at once, but nothing can be recovered."
                            : "Collected items move to the Trash, so you can put them back. Space is reclaimed when you empty the Trash.")
                            .font(.caption)
                            .foregroundStyle(deletePermanently ? .orange : .secondary)
                    }
                }
            } header: {
                Label("Deletion", systemImage: "trash")
            }

            // Off by default; see `LaunchLocation`. (Ported from upstream
            // d7faff5, which always does this.)
            Section {
                Toggle(isOn: $scanAtLaunch) {
                    VStack(alignment: .leading) {
                        Text("Scan a disk when OpenDisk opens")

                        Text("Opens the last disk or folder you scanned on this Mac (never an external drive), or else the startup disk, and scans it straight away. Takes effect the next time OpenDisk opens.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Launch", systemImage: "power")
            }

            Section {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(isFullDiskAccessGranted ? .green : .orange)
                            .frame(width: 10, height: 10)

                        Text(isFullDiskAccessGranted ? "Granted" : "Not Granted")
                            .foregroundStyle(isFullDiskAccessGranted ? .green : .orange)

                        Spacer()

                        Button("Check Again") {
                            checkFullDiskAccessStatus()
                        }
                        .disabled(isCheckingAccess)
                    }
                }

                Text("Full Disk Access allows OpenDisk to analyze all files and folders on your system for accurate disk usage information.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isFullDiskAccessGranted {
                    Button {
                        FullDiskAccess.openSystemSettings()
                    } label: {
                        Label("Open Privacy & Security Settings", systemImage: "arrow.up.forward.square")
                    }

                    Text("After granting access, click 'Check Again' to verify.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Full Disk Access", systemImage: "lock.shield")
            }

            Section {
                Toggle(isOn: $showPromptAtStartup) {
                    VStack(alignment: .leading) {
                        Text("Check Full Disk Access at startup")

                        Text("Shows a prompt if Full Disk Access is not granted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !isFullDiskAccessGranted {
                    Button("Reset Prompt Suppression") {
                        FullDiskAccess.resetPromptSuppression()
                    }
                }
            } header: {
                Label("Startup Behavior", systemImage: "power")
            }

            // (Ported from upstream 80e91c7.)
            Section {
                Toggle(isOn: $showFreeSpace) {
                    VStack(alignment: .leading) {
                        Text("Show free space on the chart")

                        Text("Adds a gray wedge for unused space when viewing the whole disk. Turn off on large, mostly empty drives so scanned folders fill the chart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Chart", systemImage: "chart.pie")
            }

            Section {
                ForEach(KeyAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action, store: keyBindings)
                    } label: {
                        Text(action.title)
                        Text(action.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Click a shortcut, then press the keys you want. Shortcuts apply while the file list is focused and never while typing in search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore All Defaults") { keyBindings.resetAll() }
                }
            } header: {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }

            Section {
                Text("""
                Why does OpenDisk need Full Disk Access?

                • Analyze system files and protected folders
                • Calculate accurate disk usage across all directories
                • Access application containers and caches
                • Provide complete disk analysis results
                """)
                .font(.callout)
            } header: {
                Label("About Permissions", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear(perform: checkFullDiskAccessStatus)
    }

    /// The probe does filesystem work; run it off the main thread.
    private func checkFullDiskAccessStatus() {
        isCheckingAccess = true
        Task {
            let granted = await Task.detached(priority: .userInitiated) {
                FullDiskAccess.isGranted
            }.value
            withAnimation(.easeInOut(duration: 0.3)) {
                isFullDiskAccessGranted = granted
                isCheckingAccess = false
            }
        }
    }
}

#Preview {
    SettingsView()
        .frame(width: 600, height: 500)
}
