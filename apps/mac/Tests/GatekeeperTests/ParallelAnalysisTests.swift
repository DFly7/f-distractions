import AppKit
import XCTest
import GatekeeperCore
@testable import Gatekeeper

@MainActor final class ParallelAnalysisTests: XCTestCase {
    private var directory: URL!
    private var primary: ParallelConnection!
    private var secondary: ParallelConnection!
    private var model: AppModel!
    private var pixels: [UInt32: UInt8] = [1: 100]
    private var contexts: [UInt32: ScreenWindowContext] = [1: .init(windowID: 10, processID: 77, navigationToken: 1)]

    override func setUp() async throws {
        Diagnostics.enabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        primary = ParallelConnection(); secondary = ParallelConnection()
        model = AppModel(client: primary, sessionStore: SessionStore(file: directory.appendingPathComponent("sessions.json")), secondaryClient: secondary)
        model.goal = "Write documentation"; model.taskContext = "Document the project"; model.sessionMinutes = 10
        model.runsSessionLoop = false; model.permissionAvailable = { true }
        model.currentTime = { Date(timeIntervalSince1970: 1000) }
        model.prioritySettleDelay = {}; model.freshnessDelay = {}; model.cacheCheckDelay = {}
        model.pollWindowContexts = { [unowned self] in self.contexts }
        model.captureScreens = { [unowned self] in
            try self.pixels.keys.sorted().map { id in
                let file = self.directory.appendingPathComponent("\(UUID().uuidString).jpg")
                let pixel = self.pixels[id]!
                try Data("display=\(id) pixel=\(pixel)".utf8).write(to: file)
                return CapturedScreen(id: id, label: "Screen \(id)", image: NSImage(size: NSSize(width: 16, height: 9)), file: file,
                    fingerprint: ScreenFingerprint(displayID: id, sourceWidth: 1600, sourceHeight: 900,
                        pixels: Array(repeating: pixel, count: 160 * 90)), context: self.contexts[id])
            }
        }
        await model.connect(); await model.warmSecondaryTask?.value
    }

    override func tearDown() async throws {
        model.shutdown()
        await model.checkTask?.value; await model.secondaryCheckTask?.value; await model.warmSecondaryTask?.value
        try? FileManager.default.removeItem(at: directory)
    }

    private func startHeld() async {
        let started = expectation(description: "Primary inference started")
        primary.onRequest = { started.fulfill() }
        model.startSession(); await fulfillment(of: [started], timeout: 2)
        primary.onRequest = nil
    }

    private func changeAndWaitForOverlap(displayID: UInt32 = 1) async {
        let started = expectation(description: "Overlap started while original is held")
        secondary.onRequest = { started.fulfill() }
        pixels[displayID] = 200
        contexts[displayID] = .init(windowID: displayID * 10, processID: 77, navigationToken: 2)
        model.contextChanged(.navigation)
        await fulfillment(of: [started], timeout: 2)
        secondary.onRequest = nil
    }

    private func result(_ statuses: [String]) -> Verdict {
        let status = statuses.contains("off_task") ? "off_task" : "on_task"
        return Verdict(status: status, reason: status, nextStep: "Continue", screens: statuses.enumerated().map {
            ScreenVerdict(screenIndex: $0.offset + 1, status: $0.element, reason: $0.element)
        })
    }

    func testSecondRequestStartsWithoutWaitingAndOldReplyCannotOverwriteOrUnblurNewResult() async {
        await startHeld(); await changeAndWaitForOverlap()
        XCTAssertEqual(primary.requests.count, 1); XCTAssertEqual(secondary.requests.count, 1)
        secondary.complete(result(["off_task"])); await model.secondaryCheckTask?.value
        XCTAssertEqual(model.interventions.map(\.id), [1])
        XCTAssertEqual(model.verdict?.status, "off_task")
        XCTAssertTrue(model.checking); XCTAssertTrue(model.analysisInFlight)
        primary.complete(result(["on_task"])); await model.checkTask?.value
        XCTAssertEqual(model.verdict?.status, "off_task")
        XCTAssertEqual(model.interventions.map(\.id), [1])
        XCTAssertFalse(model.checking); XCTAssertFalse(model.analysisInFlight)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.allSatisfy { !$0.hasSuffix("jpg") } ?? false)
    }

    func testTwoBusySlotsKeepOnlyNewestViewAndReuseFirstFreedSlot() async {
        await startHeld(); await changeAndWaitForOverlap()
        for value: UInt8 in [210, 220, 230] {
            pixels[1] = value; contexts[1] = .init(windowID: 10, processID: 77, navigationToken: Int(value))
            model.contextChanged(.navigation)
        }
        XCTAssertEqual(primary.requests.count + secondary.requests.count, 2)
        let replacement = expectation(description: "Freed primary starts newest pending view")
        primary.onRequest = { replacement.fulfill() }
        primary.complete(result(["on_task"]))
        await fulfillment(of: [replacement], timeout: 2)
        primary.onRequest = nil
        XCTAssertEqual(primary.requests.count, 2)
        XCTAssertEqual(primary.requests.last, ["display=1 pixel=230"])
        primary.complete(result(["on_task"])); await model.checkTask?.value
        secondary.complete(result(["off_task"])); await model.secondaryCheckTask?.value
        XCTAssertEqual(model.verdict?.status, "on_task")
        XCTAssertTrue(model.interventions.isEmpty)
    }

    func testChangedMonitorOnlyIsUploadedAndResultMapsBackToPhysicalScreen() async {
        pixels[2] = 100; contexts[2] = .init(windowID: 20, processID: 77, navigationToken: 1)
        await startHeld(); await changeAndWaitForOverlap(displayID: 2)
        XCTAssertEqual(primary.requests[0].count, 2)
        XCTAssertEqual(secondary.requests[0], ["display=2 pixel=200"])
        secondary.complete(result(["off_task"])); await model.secondaryCheckTask?.value
        XCTAssertEqual(model.interventions.map(\.id), [2])
        XCTAssertEqual(model.interventions.first?.screenIndex, 2)
        XCTAssertNil(model.completedVerdict(forPhysicalIndex: 1))
        XCTAssertEqual(model.completedVerdict(forPhysicalIndex: 2)?.status, "off_task")
        primary.complete(result(["on_task", "on_task"])); await model.checkTask?.value
        XCTAssertEqual(model.screenshots.map(\.id), [1, 2])
        XCTAssertEqual(model.verdict?.screens.map(\.status), ["on_task", "off_task"])
        XCTAssertEqual(model.policy.baseline?.first(where: { $0.displayID == 2 })?.pixels.first, 200)
        XCTAssertEqual(model.displayCount, 2)
    }

    func testPauseStopsBothRequestsDropsLateRepliesAndDeletesAllImages() async {
        await startHeld(); await changeAndWaitForOverlap()
        model.pauseSession()
        await model.checkTask?.value; await model.secondaryCheckTask?.value
        XCTAssertEqual(model.session?.state, .paused)
        XCTAssertNil(model.verdict); XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertFalse(model.checking)
        XCTAssertGreaterThan(primary.stops, 0); XCTAssertGreaterThan(secondary.stops, 0)
        XCTAssertFalse(try! FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix("jpg") })
    }

    func testContinuousScrollingInSameViewCannotKeepWithholdingOffTaskBlur() async {
        await startHeld()
        model.recordPointerActivity(displayID: 1, scrolling: true)
        pixels[1] = 200
        await model.probeForViewChange()
        XCTAssertNil(model.policy.pendingTrigger)
        XCTAssertEqual(secondary.requests.count, 0)
        // A metadata event elsewhere must not make scrolling on this screen veto blur.
        model.contextChanged(.appSwitch)
        await model.priorityInterruptTask?.value; await model.secondaryCheckTask?.value
        XCTAssertEqual(secondary.requests.count, 0)
        primary.complete(result(["off_task"])); await model.checkTask?.value
        XCTAssertEqual(model.interventions.map(\.id), [1])
    }

    func testClickThenScrollOnNewContentDoesNotReuseOldVerdict() async {
        await startHeld()
        model.recordPointerActivity(displayID: 1, scrolling: false)
        pixels[1] = 200
        model.recordPointerActivity(displayID: 1, scrolling: true)
        let started = expectation(description: "New clicked view checked despite subsequent scrolling")
        secondary.onRequest = { started.fulfill() }
        await model.probeForViewChange()
        await fulfillment(of: [started], timeout: 2)
        secondary.onRequest = nil
        primary.complete(result(["off_task"])); await model.checkTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
        secondary.complete(result(["on_task"])); await model.secondaryCheckTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertEqual(model.verdict?.status, "on_task")
    }

    func testScrollHintExpiresInsteadOfAllowingFutureUnknownViews() async {
        await startHeld()
        model.recordPointerActivity(displayID: 1, scrolling: true)
        pixels[1] = 200
        await model.probeForViewChange()
        XCTAssertEqual(secondary.requests.count, 0)
        model.currentTime = { Date(timeIntervalSince1970: 1002) }
        let started = expectation(description: "Expired scroll hint cannot suppress new content")
        secondary.onRequest = { started.fulfill() }
        await model.probeForViewChange()
        await fulfillment(of: [started], timeout: 2)
        secondary.onRequest = nil
        primary.complete(result(["off_task"])); await model.checkTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
        secondary.complete(result(["on_task"])); await model.secondaryCheckTask?.value
        XCTAssertTrue(model.interventions.isEmpty)
    }

    func testExpiryStopsBothRequests() async {
        await startHeld(); await changeAndWaitForOverlap()
        model.currentTime = { Date(timeIntervalSince1970: 2000) }
        model.tickSession()
        await model.checkTask?.value; await model.secondaryCheckTask?.value
        XCTAssertEqual(model.session?.state, .completed)
        XCTAssertNil(model.verdict); XCTAssertTrue(model.interventions.isEmpty)
        XCTAssertFalse(model.checking)
    }

    func testTitleChurnDoesNotUploadDuplicateUnchangedScreens() async {
        await startHeld()
        contexts[1] = .init(windowID: 10, processID: 77, navigationToken: 2)
        model.contextChanged(.navigation); await model.priorityInterruptTask?.value
        await model.secondaryCheckTask?.value
        XCTAssertEqual(secondary.requests.count, 0)
        primary.complete(result(["off_task"])); await model.checkTask?.value
        XCTAssertEqual(model.interventions.map(\.id), [1])
    }
}

@MainActor private final class ParallelConnection: GatekeeperConnection {
    var onLoginCompleted: ((Bool, String?) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var accountEmail: String? { nil }
    var onRequest: (() -> Void)?
    var requests: [[String]] = []
    var stops = 0
    private var held: CheckedContinuation<Verdict, Error>?
    func connect() async throws {}
    func account() async throws -> String? { "Test subscription" }
    func models() async throws -> [CodexModel] { [.init(id: "test", name: "Test", isDefault: true)] }
    func signIn() async throws -> URL { URL(string: "https://example.invalid")! }
    func cancelSignIn() async {}
    func analyse(goal: String, images: [URL], model: String) async throws -> Verdict {
        XCTAssertNil(held, "Each connection must have only one active request")
        requests.append(try images.map { try String(contentsOf: $0, encoding: .utf8) })
        return try await withCheckedThrowingContinuation { continuation in
            held = continuation; onRequest?()
        }
    }
    func complete(_ result: Verdict) { let waiter = held; held = nil; waiter?.resume(returning: result) }
    func stop(reason: String) {
        stops += 1
        let waiter = held; held = nil
        waiter?.resume(returning: Verdict(status: "on_task", reason: "Late reply", nextStep: "Continue"))
    }
}
