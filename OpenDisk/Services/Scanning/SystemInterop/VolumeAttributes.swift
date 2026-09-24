import Darwin
import Foundation

/// Queries volume-level facts the scan engine needs: where a path's
/// volume is mounted, and how many bytes are in use.
enum VolumeAttributes {

    /// The mount point of the volume containing `path`, or nil on failure.
    static func mountPoint(ofVolumeContaining path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_mntonname) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// True when `path` is itself the mount point of a volume.
    static func isVolumeRoot(_ path: String) -> Bool {
        mountPoint(ofVolumeContaining: path) == path
    }

    /// The device ID (`st_dev`) of `path`, or nil if it cannot be stat'ed.
    static func deviceID(ofPath path: String) -> dev_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
