import XCTest
@testable import Gatekeeper

final class ContinuousHoldTests: XCTestCase {
    func testTenUninterruptedSecondsCompletesExactlyOnce() {
        var hold = ContinuousHold()
        hold.begin(at: 100)
        hold.begin(at: 105) // Repeated down events cannot restart or accelerate the hold.
        XCTAssertFalse(hold.complete(at: 109.99))
        XCTAssertTrue(hold.complete(at: 110))
        XCTAssertFalse(hold.complete(at: 111))
    }
    func testReleaseOrFocusLossResetsRatherThanAccumulatingTime() {
        var hold = ContinuousHold()
        hold.begin(at: 100)
        XCTAssertEqual(hold.progress(at: 109), 0.9, accuracy: 0.001)
        hold.reset()
        XCTAssertFalse(hold.complete(at: 120))
        hold.begin(at: 120)
        XCTAssertFalse(hold.complete(at: 121))
        XCTAssertTrue(hold.complete(at: 130))
    }
}
