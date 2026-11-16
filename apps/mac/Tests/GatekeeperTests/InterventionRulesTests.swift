import XCTest
import AppKit
import GatekeeperCore
@testable import Gatekeeper

final class InterventionRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func image(_ value: UInt8 = 100, id: UInt32 = 1) -> ScreenFingerprint {
        ScreenFingerprint(displayID: id, sourceWidth: 1600, sourceHeight: 900, pixels: Array(repeating: value, count: 1000))
    }
    private func verdict(_ statuses: [String]) -> Verdict {
        let overall = statuses.contains("off_task") ? "off_task" : statuses.contains("unsure") ? "unsure" : statuses.contains("on_task") ? "on_task" : "unsure"
        return Verdict(status: overall, reason: "Synthetic assessment", nextStep: "Continue",
                       screens: statuses.enumerated().map { ScreenVerdict(screenIndex: $0.offset + 1, status: $0.element, reason: "Screen evidence") })
    }

    func testOnlyOffTaskScreenIsTargetedAndImageOrderMapsToPhysicalDisplayID() {
        let screens = [image(id: 9), image(id: 3), image(id: 7)]
        let candidates = InterventionRules().candidates(verdict: verdict(["on_task", "off_task", "neutral"]),
            assessed: screens, current: Array(screens.reversed()), assessedAt: now, now: now, contextUnchanged: true)
        XCTAssertEqual(candidates.map(\.id), [3])
        XCTAssertEqual(candidates.first?.screenIndex, 2)
    }

    func testOnTaskNeutralAndUncertainScreensAreNeverBlurred() {
        let screens = [image(id: 1), image(id: 2), image(id: 3)]
        XCTAssertTrue(InterventionRules().candidates(verdict: verdict(["on_task", "unsure", "neutral"]),
            assessed: screens, current: screens, assessedAt: now, now: now, contextUnchanged: true).isEmpty)
    }

    func testOldResultChangedAppOrChangedPageCannotCauseBlur() {
        let rules = InterventionRules(), off = verdict(["off_task"])
        XCTAssertTrue(rules.candidates(verdict: off, assessed: [image()], current: [image()], assessedAt: now,
                                      now: now.addingTimeInterval(21), contextUnchanged: true).isEmpty)
        XCTAssertTrue(rules.candidates(verdict: off, assessed: [image()], current: [image()], assessedAt: now,
                                      now: now, contextUnchanged: false).isEmpty)
        XCTAssertTrue(rules.candidates(verdict: off, assessed: [image()], current: [image(200)], followup: [image(200)],
                                      assessedAt: now, now: now, contextUnchanged: true).isEmpty)
    }

    func testMissingDisplayCannotReceiveAnOverlay() {
        XCTAssertTrue(InterventionRules().candidates(verdict: verdict(["off_task"]), assessed: [image(id: 1)],
            current: [image(id: 2)], assessedAt: now, now: now, contextUnchanged: true).isEmpty)
    }

    func testApprovalIsScopedToTheViewAndExpires() {
        var rules = InterventionRules()
        rules.approve(image(), at: now)
        XCTAssertTrue(rules.candidates(verdict: verdict(["off_task"]), assessed: [image()], current: [image()],
            assessedAt: now, now: now, contextUnchanged: true).isEmpty)
        XCTAssertFalse(rules.isApproved(image(200), at: now))
        XCTAssertTrue(rules.expireApprovals(at: now.addingTimeInterval(120)))
        XCTAssertFalse(rules.isApproved(image(), at: now.addingTimeInterval(120)))
        XCTAssertFalse(rules.expireApprovals(at: now.addingTimeInterval(121)))
    }

    func testApprovalOnOneScreenDoesNotExemptAnother() {
        var rules = InterventionRules()
        rules.approve(image(id: 1), at: now)
        let screens = [image(id: 1), image(id: 2)]
        let candidates = rules.candidates(verdict: verdict(["off_task", "off_task"]), assessed: screens,
            current: screens, assessedAt: now, now: now, contextUnchanged: true)
        XCTAssertEqual(candidates.map(\.id), [2])
        rules.reset()
        XCTAssertEqual(rules.candidates(verdict: verdict(["off_task", "off_task"]), assessed: screens,
            current: screens, assessedAt: now, now: now, contextUnchanged: true).count, 2)
    }

    func testVideoMotionCanChangeWhileStablePageChromeRemainsTheSame() {
        let evidence = image()
        var a = evidence.pixels, b = evidence.pixels
        for index in 300..<1000 { a[index] = 200; b[index] = 50 }
        let current = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: a)
        let next = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: b)
        XCTAssertTrue(SceneFreshness.matches(evidence, current: current, followup: next))
        a[0..<100] = ArraySlice(repeating: 220, count: 100)
        b[0..<100] = ArraySlice(repeating: 220, count: 100)
        let navigatedA = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: a)
        let navigatedB = ScreenFingerprint(displayID: 1, sourceWidth: 1600, sourceHeight: 900, pixels: b)
        XCTAssertFalse(SceneFreshness.matches(evidence, current: navigatedA, followup: navigatedB))
    }

    func testMissingDuplicateOrContradictoryScreenVerdictsAreRejected() {
        XCTAssertThrowsError(try Verdict(status: "off_task", reason: "", nextStep: "").validated(screenCount: 1))
        let duplicated = [ScreenVerdict(screenIndex: 1, status: "off_task", reason: ""), ScreenVerdict(screenIndex: 1, status: "on_task", reason: "")]
        XCTAssertThrowsError(try Verdict(status: "off_task", reason: "", nextStep: "", screens: duplicated).validated(screenCount: 2))
        XCTAssertThrowsError(try Verdict(status: "on_task", reason: "", nextStep: "", screens: verdict(["off_task"]).screens).validated(screenCount: 1))
    }
}

@MainActor final class OverlayPanelTests: XCTestCase {
    func testPanelsTargetOnePhysicalMonitorAndAreRemoved() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw XCTSkip("No desktop display available")
        }
        let controller = FocusOverlayController(presentsWindows: false)
        let fingerprint = ScreenFingerprint(displayID: id, sourceWidth: 1600, sourceHeight: 900, pixels: [100])
        controller.update([InterventionCandidate(fingerprint: fingerprint, screenIndex: 1, reason: "Synthetic")], goal: "Test")
        XCTAssertEqual(controller.activeDisplayIDs, [id])
        controller.update([], goal: "Test")
        XCTAssertTrue(controller.activeDisplayIDs.isEmpty)
        XCTAssertEqual(controller.visiblePanelCount, 0)
    }

    func testBlurIsClickThroughAndCardDoesNotActivateTheAppOrOfferClose() {
        _ = NSApplication.shared
        let blur = FocusPanel(frame: NSRect(x: 0, y: 0, width: 800, height: 600), interactive: false)
        let card = FocusPanel(frame: NSRect(x: 0, y: 0, width: 500, height: 300), interactive: true)
        defer { blur.close(); card.close() }
        XCTAssertTrue(blur.ignoresMouseEvents)
        XCTAssertFalse(card.ignoresMouseEvents)
        XCTAssertTrue(card.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(card.styleMask.contains(.closable))
        XCTAssertTrue(blur.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertGreaterThan(card.level.rawValue, blur.level.rawValue)
    }
}
