import XCTest
import AppKit
@testable import Gatekeeper

@MainActor final class ScreenCaptureContextTests: XCTestCase {
    private func window(id: UInt32, pid: Int32, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowName as String: "Synthetic window",
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600).dictionaryRepresentation]
    }
    func testOwnMainWindowIsTheVisibleContextInsteadOfHiddenApp() {
        let current = ScreenCapture.windowContext(on: CGRect(x: 0, y: 0, width: 800, height: 600),
            windows: [window(id: 10, pid: ProcessInfo.processInfo.processIdentifier), window(id: 20, pid: 1234)])
        XCTAssertEqual(current?.windowID, 10)
    }
    func testOnlyOverlayIDsAreExcludedIncludingFadingPanels() {
        let current = ScreenCapture.windowContext(on: CGRect(x: 0, y: 0, width: 800, height: 600),
            windows: [window(id: 1, pid: ProcessInfo.processInfo.processIdentifier, layer: 4),
                      window(id: 2, pid: ProcessInfo.processInfo.processIdentifier, layer: 3),
                      window(id: 10, pid: ProcessInfo.processInfo.processIdentifier, layer: 5),
                      window(id: 20, pid: 1234)], excluding: [1, 2])
        XCTAssertEqual(current?.windowID, 10)
    }
}
