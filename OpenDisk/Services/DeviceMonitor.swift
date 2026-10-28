import AppKit
import Observation

/// Enumerates the devices offered in the sidebar: the boot volume group
/// plus mounted external volumes.
@MainActor
@Observable
final class DeviceMonitor {

    private(set) var devices: [DeviceInfo] = []
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

    init() {
        Task { await refresh() }
        observeVolumeChanges()
    }

    /// Re-reads the list whenever a volume is mounted, unmounted or
    /// renamed, so a drive plugged in after launch appears without a
    /// restart. These are ordinary in-process notifications from
    /// NSWorkspace; they need no permission and observe nothing beyond
    /// volume events. (Ported from upstream a5bd938.)
    ///
    /// Also whenever OpenDisk itself comes to the front, so the sidebar's
    /// free-space figures catch up with whatever was done in other apps.
    /// Upstream fb76404 instead re-reads every 3 seconds and on *any*
    /// app's activation (`NSWorkspace.didActivateApplicationNotification`,
    /// which tells this app what else the user switches to). Neither is
    /// taken: this app's own activation is enough for the purpose.
    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        volumeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refresh() }
                }
            }
        }
        volumeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        })
    }

    /// Rebuilds the device list from the currently mounted volumes.
    ///
    /// Only an actual change is published: an unchanged list re-rendering
    /// the sidebar on every refresh would reset hover and redraw for
    /// nothing. (Ported from upstream fb76404.)
    func refresh() async {
        let current = await Task.detached(priority: .utility) {
            Self.currentDevices()
        }.value
        if current != devices { devices = current }
    }

    // MARK: - Enumeration (off the main actor)

    private nonisolated static func currentDevices() -> [DeviceInfo] {
        var devices: [DeviceInfo] = []

        if let capacity = volumeCapacity(ofPath: "/") {
            devices.append(DeviceInfo(
                name: "Computer",
                icon: "desktopcomputer",
                path: "/",
                totalBytes: capacity.total,
                availableBytes: capacity.available
            ))
        }

        let bootDevice = VolumeAttributes.deviceID(ofPath: "/")
        // `mountedVolumeURLs` with `.skipHiddenVolumes` already excludes the
        // system-managed APFS volumes in the boot container (Recovery,
        // Preboot, VM, Update), which report the whole container's capacity
        // and are not separately scannable devices.
        let keys: [URLResourceKey] = [
            .volumeIsBrowsableKey, .volumeNameKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        let volumeURLs = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []).sorted { $0.path < $1.path }
        for url in volumeURLs {
            let path = url.path
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Belt-and-suspenders: only user-browsable volumes, never the
            // boot volume (matched by device ID rather than by name).
            guard values?.volumeIsBrowsable == true,
                  VolumeAttributes.deviceID(ofPath: path) != bootDevice,
                  FileManager.default.isReadableFile(atPath: path),
                  let capacity = volumeCapacity(ofPath: path) else {
                continue
            }
            devices.append(DeviceInfo(
                name: values?.volumeName ?? url.lastPathComponent,
                icon: "externaldrive",
                path: path,
                totalBytes: capacity.total,
                availableBytes: capacity.available
            ))
        }

        return devices
    }

    /// Live capacity of the volume containing `path`, or nil when the
    /// system cannot report it. Cheap (one `statfs`), safe off the main
    /// actor. (Widened from private for the analysis status bar;
    /// upstream d628684.)
    nonisolated static func volumeCapacity(ofPath path: String) -> VolumeCapacity? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]), let total = values.volumeTotalCapacity {
            return VolumeCapacity(
                total: Int64(total),
                free: Int64(values.volumeAvailableCapacity ?? 0),
                availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage
            )
        }

        // Fallback for volumes where resource values fail.
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let total = attributes[.systemSize] as? Int64,
           let free = attributes[.systemFreeSize] as? Int64 {
            return VolumeCapacity(total: total, free: free)
        }
        return nil
    }
}
