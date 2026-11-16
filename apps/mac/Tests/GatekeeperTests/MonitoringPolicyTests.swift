import XCTest
import CoreGraphics
import GatekeeperCore

final class MonitoringPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func screen(_ value: UInt8 = 100, id: UInt32 = 1, width: Int = 1600) -> ScreenFingerprint {
        ScreenFingerprint(displayID: id, sourceWidth: width, sourceHeight: 900, pixels: Array(repeating: value, count: 160 * 90))
    }

    func testTinyChangesIgnoredAndGradualChangesComparedAgainstOriginalBaseline() {
        let baseline = screen()
        var cursor = baseline.pixels
        cursor[100] = 255
        let withCursor = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: cursor)
        XCTAssertFalse(ScreenComparison.changed([withCursor], since: [baseline]))
        XCTAssertFalse(ScreenComparison.changed([screen(110)], since: [baseline]))
        XCTAssertTrue(ScreenComparison.changed([screen(120)], since: [baseline]))
    }

    func testEveryDisplayAndTopologyAreComparedWithoutDependingOnArrayOrder() {
        let baseline = [screen(id: 1), screen(id: 2)]
        XCTAssertFalse(ScreenComparison.changed(Array(baseline.reversed()), since: baseline))
        XCTAssertTrue(ScreenComparison.changed([screen(id: 1)], since: baseline))
        XCTAssertTrue(ScreenComparison.changed([screen(id: 1), screen(200, id: 2)], since: baseline))
        XCTAssertTrue(ScreenComparison.changed([screen(id: 1, width: 900), screen(id: 2)], since: baseline))
    }

    func testRealImagesProduceStableSmallGrayscaleFingerprints() throws {
        func image(gray: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 800, height: 450, bitsPerComponent: 8, bytesPerRow: 800,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: gray, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 800, height: 450))
            return context.makeImage()!
        }
        let a = try ScreenFingerprint.make(displayID: 1, image: image(gray: 0.2))
        let b = try ScreenFingerprint.make(displayID: 1, image: image(gray: 0.2))
        let c = try ScreenFingerprint.make(displayID: 1, image: image(gray: 0.8))
        XCTAssertEqual(a.pixels.count, 160 * 90)
        XCTAssertFalse(ScreenComparison.changed([b], since: [a]))
        XCTAssertTrue(ScreenComparison.changed([c], since: [a]))
    }

    func testAppSwitchGetsPriorityButStillHasAThreeSecondFloor() {
        var policy = MonitoringPolicy(minimumGap: 30)
        policy.beganRequest(at: now); policy.succeeded(with: [screen()])
        XCTAssertNil(policy.trigger(for: [screen(200)], at: now.addingTimeInterval(5)))
        policy.queue(.appSwitch, at: now.addingTimeInterval(1))
        XCTAssertNil(policy.trigger(for: [screen()], at: now.addingTimeInterval(2.9)))
        XCTAssertEqual(policy.trigger(for: [screen()], at: now.addingTimeInterval(3)), .appSwitch)
    }

    func testRapidAppSwitchesWaitForSettlingAndCoalesce() {
        var policy = MonitoringPolicy(minimumGap: 15)
        policy.beganRequest(at: now); policy.succeeded(with: [screen()])
        policy.queue(.appSwitch, at: now.addingTimeInterval(20))
        policy.queue(.appSwitch, at: now.addingTimeInterval(21))
        XCTAssertNil(policy.trigger(for: [screen()], at: now.addingTimeInterval(21.2)))
        XCTAssertEqual(policy.trigger(for: [screen()], at: now.addingTimeInterval(21.4)), .appSwitch)
        policy.beganRequest(at: now.addingTimeInterval(21.4))
        XCTAssertNil(policy.trigger(for: [screen(200)], at: now.addingTimeInterval(22)))
    }

    func testTabNavigationGetsPriorityOverBackgroundGap() {
        var policy = MonitoringPolicy(minimumGap: 60)
        policy.beganRequest(at: now); policy.succeeded(with: [screen()])
        policy.queue(.navigation, at: now.addingTimeInterval(4))
        XCTAssertNil(policy.trigger(for: [screen()], at: now.addingTimeInterval(4.2)))
        XCTAssertEqual(policy.trigger(for: [screen()], at: now.addingTimeInterval(4.4)), .navigation)
    }

    func testVisualChangeCannotDowngradeAnAlreadyQueuedPriorityCheck() {
        var policy = MonitoringPolicy(minimumGap: 60)
        policy.beganRequest(at: now); policy.succeeded(with: [screen()])
        policy.queue(.appSwitch, at: now.addingTimeInterval(1))
        policy.queue(.visualChange, at: now.addingTimeInterval(2))
        XCTAssertEqual(policy.trigger(for: [screen()], at: now.addingTimeInterval(3)), .appSwitch)
    }

    func testSettledViewChangeGetsPriorityAndMovingVideoDoesNot() {
        let old = screen()
        XCTAssertTrue(ScreenComparison.substantialSettledChange(previous: [old], current: [screen(220)], followup: [screen(220)]))
        var a = old.pixels, b = old.pixels
        for i in 3000..<a.count { a[i] = 240; b[i] = 20 }
        let frameA = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: a)
        let frameB = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: b)
        XCTAssertFalse(ScreenComparison.substantialSettledChange(previous: [old], current: [frameA], followup: [frameB]))
        var policy = MonitoringPolicy(minimumGap: 60)
        policy.beganRequest(at: now); policy.succeeded(with: [old])
        policy.queue(.viewChange, at: now.addingTimeInterval(1))
        XCTAssertNil(policy.trigger(for: [screen(220)], at: now.addingTimeInterval(2)))
        XCTAssertEqual(policy.trigger(for: [screen(220)], at: now.addingTimeInterval(3)), .viewChange)
    }

    func testSpaceChangeSettlesAndBypassesBackgroundGap() {
        var policy = MonitoringPolicy(minimumGap: 60)
        policy.beganRequest(at: now); policy.succeeded(with: [screen()])
        policy.queue(.spaceChange, at: now.addingTimeInterval(4))
        XCTAssertNil(policy.trigger(for: [screen()], at: now.addingTimeInterval(4.2)))
        XCTAssertEqual(policy.trigger(for: [screen()], at: now.addingTimeInterval(4.4)), .spaceChange)
    }

    func testFailedChecksBackOffAndKeepLastSuccessfulBaseline() {
        var policy = MonitoringPolicy(minimumGap: 15)
        policy.beganRequest(at: now); policy.succeeded(with: [screen()])
        policy.beganRequest(at: now.addingTimeInterval(20))
        policy.failed(at: now.addingTimeInterval(22))
        XCTAssertEqual(policy.baseline, [screen()])
        XCTAssertNil(policy.trigger(for: [screen(200)], at: now.addingTimeInterval(51)))
        XCTAssertEqual(policy.trigger(for: [screen(200)], at: now.addingTimeInterval(52)), .retry)
    }

    func testEventDuringAnalysisIsPreservedForTheNextCheck() {
        var policy = MonitoringPolicy(minimumGap: 15)
        policy.beganRequest(at: now)
        policy.queue(.appSwitch, at: now.addingTimeInterval(4))
        policy.succeeded(with: [screen()])
        XCTAssertEqual(policy.trigger(for: [screen()], at: now.addingTimeInterval(15)), .appSwitch)
    }
}
