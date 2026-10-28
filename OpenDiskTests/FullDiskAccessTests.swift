import Foundation
import Testing
@testable import OpenDisk

/// The test host is the app itself, and it used to show the startup "Full
/// Disk Access Required" alert whenever the debug build lacked Full Disk
/// Access. That alert's modal loop blocks the main actor, so every
/// main-actor test sat waiting until someone clicked "Later". The app now
/// recognises that it is only hosting the test bundle and skips the alert.
@Suite("Full Disk Access startup alert")
struct FullDiskAccessTests {

    @Test("a process that hosts the test bundle is recognised")
    func hostingTestsDetected() {
        #expect(FullDiskAccess.isHostingTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"]
        ))
    }

    @Test("an ordinary launch is not mistaken for a test host")
    func ordinaryLaunchNotDetected() {
        #expect(!FullDiskAccess.isHostingTests(
            environment: ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"]
        ))
    }

    @Test("this very test run is recognised, so the alert cannot block it")
    func currentRunDetected() {
        // Pins the detection to what xcodebuild actually sets, not to what
        // the helper assumes it sets.
        #expect(FullDiskAccess.isHostingTests())
    }
}
