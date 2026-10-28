import Foundation
import Testing
@testable import OpenDisk

@Suite("LaunchLocation")
struct LaunchLocationTests {

    private static func device(_ path: String) -> DeviceInfo {
        DeviceInfo(name: path, icon: "internaldrive", path: path, totalBytes: 100, availableBytes: 50)
    }

    private static let computer = device("/")
    private static let external = device("/Volumes/Backup")
    private static let folder = DeviceInfo(
        name: "Projects", icon: "folder", path: "/Users/someone/Projects", totalBytes: 0, availableBytes: 0
    )

    @Test("scanning at launch is off unless the user turns it on")
    func offByDefault() throws {
        let suite = "LaunchLocationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(LaunchLocation.defaultValue == false)
        #expect(LaunchLocation.isEnabled(in: defaults) == false)

        defaults.set(true, forKey: LaunchLocation.defaultsKey)
        #expect(LaunchLocation.isEnabled(in: defaults))
    }

    @Test("reopens the last internal location, else the startup disk")
    func choosesLastInternalLocation() {
        let locations = [Self.computer, Self.external, Self.folder]
        #expect(LaunchLocation.choose(
            from: locations, last: Self.folder.path, canOpen: { _ in true }
        ) == Self.folder.path)
        #expect(LaunchLocation.choose(
            from: locations, last: "", canOpen: { _ in true }
        ) == "/")
        // A last location that has gone away falls back too.
        #expect(LaunchLocation.choose(
            from: locations, last: "/Users/someone/Gone", canOpen: { _ in true }
        ) == "/")
    }

    @Test("never starts on an external volume")
    func skipsExternalVolumes() {
        let locations = [Self.computer, Self.external]
        #expect(LaunchLocation.choose(
            from: locations, last: Self.external.path, canOpen: { _ in true }
        ) == "/")
        #expect(LaunchLocation.choose(
            from: [Self.external], last: Self.external.path, canOpen: { _ in true }
        ) == nil)
    }

    @Test("never picks a location it would have to ask for access to")
    func respectsAccess() {
        let locations = [Self.computer, Self.folder]
        #expect(LaunchLocation.choose(
            from: locations, last: Self.folder.path, canOpen: { $0.path == "/" }
        ) == "/")
        #expect(LaunchLocation.choose(
            from: locations, last: Self.folder.path, canOpen: { _ in false }
        ) == nil)
    }
}
